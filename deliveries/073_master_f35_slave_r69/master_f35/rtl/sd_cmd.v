`timescale 1ns / 1ps
// ============================================================================
// sd_cmd — SD 命令发送与响应接收
//
// 发送按 adv(每个 SD 上升沿前一次), 接收按 smp(每个 SD 上升沿采样一次)。
// 发送的 48 位均以 mark 标记, 第 48 个 smp_mark(结束位被卡采样的沿)之后
// 才开始找响应起始位, 与时钟模式和采样流水深度无关。
// 响应类型:
//   R_NONE  无响应(CMD0)
//   R_48    R1/R6/R7, 校验 CRC7、传输位、命令号、结束位
//   R_48B   R1b, 另等 DAT0 忙释放
//   R_136   R2, 校验保留位 111111 与 CID/CSD 自身 CRC7
//   R_48NC  R3, 不校验 CRC(字段为保留全 1), 命令号字段应为 111111
// CRC 校验把接收到的 CRC 位一并移入, 余数为 0 即正确。
// resp: 48 位响应为 resp[31:0]=载荷[39:8]; R2 为 resp[127:0](含 CRC 与结束位)。
// 每次结束后再给 8 个时钟(NRC/NCC ≥ 8)才报 done。
// ============================================================================
module sd_cmd #(
    parameter integer NCR_MAX  = 80,
    parameter integer BUSY_MAX = 16777215
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         adv,
    input  wire         smp,
    output wire         mark,
    input  wire         smp_mark,

    input  wire         start,
    input  wire [5:0]   idx,
    input  wire [31:0]  arg,
    input  wire [2:0]   rtype,
    output wire         busy,
    output reg          done,
    output reg  [3:0]   err,        // [0]超时 [1]CRC [2]格式/命令号 [3]忙超时
    output reg  [127:0] resp,

    output reg          cmd_o,
    output reg          cmd_oe,
    input  wire         cmd_i,
    input  wire         dat0_i
);
    localparam [2:0] R_NONE = 3'd0, R_48 = 3'd1, R_48B = 3'd2, R_136 = 3'd3, R_48NC = 3'd4;
    localparam [2:0] S_IDLE = 3'd0, S_SELF = 3'd1, S_WAIT = 3'd2, S_RX = 3'd3,
                     S_BUSY = 3'd4, S_GAP = 3'd5;

    reg  [2:0]  st;
    reg  [2:0]  rt;
    reg  [5:0]  cidx;
    reg         tx_on;
    reg  [5:0]  txcnt;
    reg  [39:0] txsr;
    reg  [7:0]  bcnt;           // smp 计数 / 接收位序号
    reg  [23:0] wcnt;           // 等待计数
    reg  [5:0]  ridx;

    assign busy = (st != S_IDLE) || tx_on;
    assign mark = tx_on;

    // CRC7: 发送期移入命令前 40 位; 接收期移入校验范围及 CRC 位
    reg        crc_clr, crc_en, crc_bit;
    wire [6:0] crc;
    sd_crc7 u_crc (.clk(clk), .clr(crc_clr), .en(crc_en), .bit_in(crc_bit), .crc(crc));

    wire        is136   = (rt == R_136);
    wire [7:0]  rlen_m1 = is136 ? 8'd135 : 8'd47;
    wire        rx_crc_win = is136 ? (bcnt >= 8'd8 && bcnt <= 8'd134) : (bcnt <= 8'd46);

    always @(*) begin
        crc_clr = 1'b0; crc_en = 1'b0; crc_bit = 1'b0;
        if (start && !busy) crc_clr = 1'b1;
        else if (tx_on && adv && txcnt < 6'd40) begin crc_en = 1'b1; crc_bit = txsr[39]; end
        else if (st == S_WAIT && smp && !cmd_i) crc_clr = 1'b1;
        else if (st == S_RX && smp && rx_crc_win) begin crc_en = 1'b1; crc_bit = cmd_i; end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; rt <= R_NONE; cidx <= 6'd0; tx_on <= 1'b0; txcnt <= 6'd0; txsr <= 40'd0;
            bcnt <= 8'd0; wcnt <= 24'd0; ridx <= 6'd0;
            done <= 1'b0; err <= 4'd0; resp <= 128'd0;
            cmd_o <= 1'b1; cmd_oe <= 1'b1;
        end else begin
            done <= 1'b0;

            // ---------------- 发送(adv 驱动) ----------------
            if (start && !busy) begin
                tx_on <= 1'b1; txcnt <= 6'd0;
                txsr  <= {2'b01, idx, arg};
                rt    <= rtype; cidx <= idx;
                st    <= S_SELF; bcnt <= 8'd0; err <= 4'd0;
            end else if (tx_on && adv) begin
                cmd_oe <= 1'b1;
                if (txcnt < 6'd40) begin
                    cmd_o <= txsr[39];
                    txsr  <= {txsr[38:0], 1'b0};
                end else if (txcnt < 6'd47) begin
                    cmd_o <= crc[6 - (txcnt - 6'd40)];
                end else begin
                    cmd_o <= 1'b1;                      // 结束位
                end
                txcnt <= txcnt + 6'd1;
                if (txcnt == 6'd47) tx_on <= 1'b0;
            end else if (!tx_on && adv && st != S_IDLE && rt != R_NONE && st != S_GAP) begin
                cmd_oe <= 1'b0;                         // 结束位之后释放 CMD 给卡
            end

            // ---------------- 接收(smp 驱动) ----------------
            if (smp) begin
                case (st)
                S_SELF: if (smp_mark) begin
                    bcnt <= bcnt + 8'd1;
                    if (bcnt == 8'd47) begin
                        bcnt <= 8'd0; wcnt <= 24'd0;
                        st   <= (rt == R_NONE) ? S_GAP : S_WAIT;
                    end
                end
                S_WAIT: begin
                    if (!cmd_i) begin
                        st <= S_RX; bcnt <= 8'd1; resp <= 128'd0;
                    end else if (wcnt == NCR_MAX) begin
                        err[0] <= 1'b1; st <= S_GAP; bcnt <= 8'd0;
                    end else wcnt <= wcnt + 24'd1;
                end
                S_RX: begin
                    bcnt <= bcnt + 8'd1;
                    if (bcnt == 8'd1 && cmd_i) err[2] <= 1'b1;                 // 传输位应为 0
                    if (bcnt >= 8'd2 && bcnt <= 8'd7) ridx <= {ridx[4:0], cmd_i};
                    if (is136 ? (bcnt >= 8'd8) : (bcnt >= 8'd8 && bcnt <= 8'd39))
                        resp <= {resp[126:0], cmd_i};
                    if (bcnt == rlen_m1) begin
                        if (!cmd_i) err[2] <= 1'b1;                           // 结束位
                        if ((rt == R_48 || rt == R_48B) && crc != 7'd0) err[1] <= 1'b1;
                        if (is136 && crc != 7'd0) err[1] <= 1'b1;
                        if ((rt == R_48 || rt == R_48B) && ridx != cidx) err[2] <= 1'b1;
                        if ((rt == R_48NC || is136) && ridx != 6'h3F) err[2] <= 1'b1;
                        bcnt <= 8'd0; wcnt <= 24'd0;
                        st   <= (rt == R_48B) ? S_BUSY : S_GAP;
                    end
                end
                S_BUSY: begin
                    // 忙信号最晚在结束位后 2 个时钟出现
                    wcnt <= wcnt + 24'd1;
                    if (wcnt >= 24'd2 && dat0_i) begin st <= S_GAP; bcnt <= 8'd0; end
                    else if (wcnt == BUSY_MAX) begin err[3] <= 1'b1; st <= S_GAP; bcnt <= 8'd0; end
                end
                S_GAP: begin
                    bcnt <= bcnt + 8'd1;
                    if (bcnt == 8'd7) begin
                        st <= S_IDLE; done <= 1'b1; cmd_oe <= 1'b1; cmd_o <= 1'b1;
                    end
                end
                default: ;
                endcase
            end
        end
    end
endmodule
