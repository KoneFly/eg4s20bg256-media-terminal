`timescale 1ns / 1ps
// sd_host：原生四线SD读卡主机，完成卡识别、高速模式协商与多块读取。
module sd_host #(
    parameter integer ACMD41_TRIES = 4095,
    parameter [22:0]  RD_TIMEOUT   = 23'd5000000     // 100ms @50MHz(按 SD 时钟计)
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [2:0]  cfg,            // {smp_late, force_ds, clk_inv}, 复位期间静态
    input  wire        reinit,         // 同步重新初始化(换卡); 调用方保证无读事务、块池已空

    output reg         init_done,
    output reg         init_err,
    output reg  [3:0]  init_stage,     // 失败时停留的阶段(诊断)
    output reg         hs_mode,
    output reg  [31:0] card_blocks,    // 卡容量(块), 由 CSD v2 计算

    input  wire        st_start,
    input  wire [31:0] st_lba,
    input  wire [15:0] st_count,
    output wire        st_busy,
    output reg         st_done,
    output reg         st_err,
    output reg  [15:0] st_blocks,      // 本次已发布块数

    output wire [3:0]  pool_count,
    input  wire [6:0]  pool_raddr,
    output wire [31:0] pool_rdata,
    input  wire        pool_release,

    output wire        sd_clk,
    inout  wire        sd_cmd,
    input  wire [3:0]  sd_dat
);
    // ---------------- 子模块 ----------------
    reg  [1:0]  ck_mode;
    wire        ck_run;
    wire        h1, h2, adv, smp, ck_low, smp_mark, mark;
    sd_clkgen u_ck (.clk(clk), .rst_n(rst_n), .mode(ck_mode), .run(ck_run), .smp_late(cfg[2]),
                    .clk_h1(h1), .clk_h2(h2), .adv(adv), .smp(smp), .low(ck_low),
                    .mark(mark), .smp_mark(smp_mark));

    wire        cmd_o, cmd_oe, cmd_i;
    wire [3:0]  dat_i;
    sd_phy u_phy (.clk(clk), .rst_n(rst_n), .clk_h1(h1), .clk_h2(h2), .clk_inv(cfg[0]),
                  .cmd_o(cmd_o), .cmd_oe(cmd_oe), .cmd_i(cmd_i), .dat_i(dat_i),
                  .sd_clk(sd_clk), .sd_cmd(sd_cmd), .sd_dat(sd_dat));

    reg         c_start;
    reg  [5:0]  c_idx;
    reg  [31:0] c_arg;
    reg  [2:0]  c_rt;
    wire        c_busy, c_done;
    wire [3:0]  c_err;
    wire [127:0] c_resp;
    sd_cmd u_cmd (.clk(clk), .rst_n(rst_n), .adv(adv), .smp(smp), .mark(mark), .smp_mark(smp_mark),
                  .start(c_start), .idx(c_idx), .arg(c_arg), .rtype(c_rt),
                  .busy(c_busy), .done(c_done), .err(c_err), .resp(c_resp),
                  .cmd_o(cmd_o), .cmd_oe(cmd_oe), .cmd_i(cmd_i), .dat0_i(dat_i[0]));

    reg         d_arm, d_wide, d_discard, d_clear;
    reg  [7:0]  d_blen;
    reg  [15:0] d_limit;
    wire        d_ok, d_bad, d_to, d_ovf, d_inblk, d_hold;
    wire [3:0]  d_count;
    reg  [6:0]  h_raddr;
    reg         h_release;
    reg         h_own;                // 主机自己读块池(CMD6 状态)
    sd_dat_rx #(.SLOT_AW(3)) u_rx (
        .clk(clk), .rst_n(rst_n), .smp(smp), .dat_i(dat_i),
        .arm(d_arm), .wide(d_wide), .blen_words(d_blen), .discard(d_discard), .clear(d_clear),
        .pub_limit(d_limit), .to_limit(RD_TIMEOUT),
        .blk_ok(d_ok), .blk_bad(d_bad), .start_to(d_to), .overflow(d_ovf),
        .in_block(d_inblk), .hold_clk(d_hold),
        .c_count(d_count), .c_raddr(h_own ? h_raddr : pool_raddr), .c_rdata(pool_rdata),
        .c_release(h_own ? h_release : pool_release));
    assign pool_count = h_own ? 4'd0 : d_count;

    reg clk_on;
    assign ck_run = clk_on && !d_hold;

    // ---------------- 主状态机 ----------------
    localparam [2:0] R_NONE = 3'd0, R_48 = 3'd1, R_48B = 3'd2, R_136 = 3'd3, R_48NC = 3'd4;
    localparam [4:0]
        P_PWR = 5'd0,  P_IDCLK = 5'd1, P_CMD0 = 5'd2,  P_CMD8 = 5'd3,  P_C55A = 5'd4,
        P_A41 = 5'd5,  P_CMD2 = 5'd6,  P_CMD3 = 5'd7,  P_CMD9 = 5'd8,  P_CMD7 = 5'd9,
        P_C55B = 5'd10, P_A6 = 5'd11,  P_C6Q = 5'd12,  P_C6QD = 5'd13, P_C6S = 5'd14,
        P_C6SD = 5'd15, P_HSW = 5'd16, P_READY = 5'd17, P_RD = 5'd18,  P_STRM = 5'd19,
        P_STOP = 5'd20, P_FAIL = 5'd21, P_W6 = 5'd22, P_C6QW = 5'd23, P_C6SW = 5'd24;

    reg  [4:0]  ph;
    reg         issued;            // 当前阶段命令已发出, 等 done
    reg  [15:0] rca;
    reg  [11:0] tries;
    reg  [19:0] wcnt;
    reg  [15:0] want;
    reg         hs_ok, strm_err;
    reg  [3:0]  rdw;

    assign st_busy = (ph == P_RD) || (ph == P_STRM) || (ph == P_STOP);

    wire r1_err = |c_resp[31:19];  // R1 卡状态错误位

    task issue(input [5:0] i, input [31:0] a, input [2:0] r);
        begin c_start <= 1'b1; c_idx <= i; c_arg <= a; c_rt <= r; issued <= 1'b1; end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ph <= P_PWR; issued <= 1'b0; rca <= 16'd0; tries <= 12'd0; wcnt <= 20'd0;
            want <= 16'd0; hs_ok <= 1'b0; strm_err <= 1'b0; rdw <= 4'd0;
            c_start <= 1'b0; c_idx <= 6'd0; c_arg <= 32'd0; c_rt <= R_NONE;
            d_arm <= 1'b0; d_wide <= 1'b0; d_discard <= 1'b0; d_clear <= 1'b0; d_blen <= 8'd128; d_limit <= 16'd1;
            h_raddr <= 7'd0; h_release <= 1'b0;
            clk_on <= 1'b0; ck_mode <= 2'd0;
            init_done <= 1'b0; init_err <= 1'b0; init_stage <= 4'd0; hs_mode <= 1'b0;
            card_blocks <= 32'd0;
            st_done <= 1'b0; st_err <= 1'b0; st_blocks <= 16'd0;
        end else if (reinit) begin
            // 停卡时钟并从上电等待重新识别; 命令/数据子模块此时空闲, 不需复位
            ph <= P_PWR; issued <= 1'b0; rca <= 16'd0; tries <= 12'd0; wcnt <= 20'd0;
            want <= 16'd0; hs_ok <= 1'b0; strm_err <= 1'b0; rdw <= 4'd0;
            c_start <= 1'b0; c_idx <= 6'd0; c_arg <= 32'd0; c_rt <= R_NONE;
            d_arm <= 1'b0; d_wide <= 1'b0; d_discard <= 1'b0; d_clear <= 1'b0; d_blen <= 8'd128; d_limit <= 16'd1;
            h_raddr <= 7'd0; h_release <= 1'b0;
            clk_on <= 1'b0; ck_mode <= 2'd0;
            init_done <= 1'b0; init_err <= 1'b0; init_stage <= 4'd0; hs_mode <= 1'b0;
            card_blocks <= 32'd0;
            st_done <= 1'b0; st_err <= 1'b0; st_blocks <= 16'd0;
        end else begin
            c_start <= 1'b0; d_clear <= 1'b0; h_release <= 1'b0; st_done <= 1'b0;
            if (c_done) issued <= 1'b0;

            case (ph)
            // 上电后等待约 1ms, 再给识别时钟
            P_PWR: begin
                wcnt <= wcnt + 20'd1;
                if (wcnt == 20'd50000) begin wcnt <= 20'd0; clk_on <= 1'b1; ph <= P_IDCLK; end
            end
            P_IDCLK: if (smp) begin
                wcnt <= wcnt + 20'd1;
                if (wcnt == 20'd79) begin wcnt <= 20'd0; ph <= P_CMD0; end
            end
            P_CMD0: if (!issued && !c_busy) issue(6'd0, 32'd0, R_NONE);
                    else if (c_done) ph <= P_CMD8;
            P_CMD8: if (!issued && !c_busy) issue(6'd8, 32'h000001AA, R_48);
                    else if (c_done) begin
                        if (c_err != 0 || c_resp[11:0] != 12'h1AA) ph <= P_FAIL;
                        else ph <= P_C55A;
                    end
            P_C55A: if (!issued && !c_busy) issue(6'd55, 32'd0, R_48);
                    else if (c_done) ph <= (c_err != 0) ? P_FAIL : P_A41;
            P_A41:  if (!issued && !c_busy) issue(6'd41, 32'h40300000, R_48NC);
                    else if (c_done) begin
                        if (c_err != 0) ph <= P_FAIL;
                        else if (c_resp[31]) ph <= c_resp[30] ? P_CMD2 : P_FAIL;
                        else if (tries == ACMD41_TRIES) ph <= P_FAIL;
                        else begin tries <= tries + 12'd1; ph <= P_C55A; end
                    end
            P_CMD2: if (!issued && !c_busy) issue(6'd2, 32'd0, R_136);
                    else if (c_done) ph <= (c_err != 0) ? P_FAIL : P_CMD3;
            P_CMD3: if (!issued && !c_busy) issue(6'd3, 32'd0, R_48);
                    else if (c_done) begin
                        if (c_err != 0 || c_resp[15:13] != 3'd0 || c_resp[31:16] == 16'd0) ph <= P_FAIL;
                        else begin rca <= c_resp[31:16]; ph <= P_CMD9; end
                    end
            P_CMD9: if (!issued && !c_busy && ck_low) begin
                        ck_mode <= 2'd1;              // 数据传输模式, 25MHz
                        issue(6'd9, {rca, 16'd0}, R_136);
                    end else if (c_done) begin
                        // resp[127:0] = CSD[127:0]; CSD v2: [127:126]=01, C_SIZE=[69:48]
                        if (c_err != 0 || c_resp[127:126] != 2'b01) ph <= P_FAIL;
                        else begin card_blocks <= ({10'd0, c_resp[69:48]} + 32'd1) << 10; ph <= P_CMD7; end
                    end
            P_CMD7: if (!issued && !c_busy) issue(6'd7, {rca, 16'd0}, R_48B);
                    else if (c_done) ph <= (c_err != 0 || r1_err) ? P_FAIL : P_C55B;
            P_C55B: if (!issued && !c_busy) issue(6'd55, {rca, 16'd0}, R_48);
                    else if (c_done) ph <= (c_err != 0) ? P_FAIL : P_A6;
            P_A6:   if (!issued && !c_busy) issue(6'd6, 32'h00000002, R_48);
                    else if (c_done) begin
                        if (c_err != 0 || r1_err) ph <= P_FAIL;
                        else begin d_wide <= 1'b1; ph <= P_C6Q; end
                    end
            // CMD6 查询: 64B 状态; FG1 支持位 bit401 = 字3[9]
            // 数据块可能早于响应结束到达, 因此先 arm 再发命令
            P_C6Q:  if (!issued && !c_busy) begin
                        h_own <= 1'b1; d_blen <= 8'd16; d_limit <= 16'd1; d_arm <= 1'b1;
                        issue(6'd6, 32'h00FFFFF1, R_48);
                    end else if (c_done) begin
                        if (c_err != 0 || r1_err) begin d_arm <= 1'b0; ph <= P_READY; end
                        else ph <= P_C6QW;
                    end
            P_C6QW: if (d_bad || d_to) begin
                        d_arm <= 1'b0; d_clear <= 1'b1; ph <= P_READY;  // 维持 25MHz
                    end else if (d_count != 0) begin
                        h_raddr <= 7'd3; rdw <= 4'd0; ph <= P_C6QD;
                    end
            P_C6QD: begin
                        rdw <= rdw + 4'd1;
                        if (rdw == 4'd2) begin
                            hs_ok <= pool_rdata[9]; h_release <= 1'b1; d_arm <= 1'b0;
                            ph <= (pool_rdata[9] && !cfg[1]) ? P_W6 : P_READY;
                        end
                    end
            P_W6:   ph <= P_C6S;       // 让块池计数在归还后更新
            P_C6S:  if (!issued && !c_busy) begin
                        d_arm <= 1'b1;
                        issue(6'd6, 32'h80FFFFF1, R_48);
                    end else if (c_done) begin
                        if (c_err != 0 || r1_err) begin d_arm <= 1'b0; ph <= P_READY; end
                        else ph <= P_C6SW;
                    end
            P_C6SW: if (d_bad || d_to) begin
                        d_arm <= 1'b0; d_clear <= 1'b1; ph <= P_READY;
                    end else if (d_count != 0) begin
                        h_raddr <= 7'd4; rdw <= 4'd0; ph <= P_C6SD;
                    end
            // FG1 实际选择 [379:376] = 字4[3:0]
            P_C6SD: begin
                        rdw <= rdw + 4'd1;
                        if (rdw == 4'd2) begin
                            h_release <= 1'b1; d_arm <= 1'b0;
                            if (pool_rdata[3:0] == 4'd1) begin wcnt <= 20'd0; ph <= P_HSW; end
                            else ph <= P_READY;
                        end
                    end
            // 切换后旧频率下至少 8 个时钟, 在低电平时改 50MHz
            P_HSW:  if (smp && wcnt < 20'd8) wcnt <= wcnt + 20'd1;
                    else if (wcnt >= 20'd8 && ck_low) begin ck_mode <= 2'd2; hs_mode <= 1'b1; ph <= P_READY; end
            // 主机读 CMD6 状态占用的块池在此排空后才交给消费端
            P_READY: begin
                d_blen <= 8'd128; d_discard <= 1'b0;
                if (h_own) begin
                    if (d_count != 0 && !h_release) h_release <= 1'b1;
                    else if (d_count == 0 && !h_release) h_own <= 1'b0;
                end else begin
                    init_done <= 1'b1;
                end
                if (!init_done) begin
                    // 未交还块池前不受理读请求
                end else if (st_start && st_count == 16'd0) begin
                    st_done <= 1'b1; st_blocks <= 16'd0; st_err <= 1'b0;
                end else if (st_start) begin
                    d_limit <= st_count;
                    want <= st_count; st_blocks <= 16'd0; st_err <= 1'b0; strm_err <= 1'b0;
                    c_arg <= st_lba; ph <= P_RD;
                end
            end
            P_RD:   if (!issued && !c_busy) begin
                        d_arm <= 1'b1;
                        issue(6'd18, c_arg, R_48);
                    end else if (c_done) begin
                        if (c_err != 0 || r1_err) begin strm_err <= 1'b1; ph <= P_STOP; end
                        else ph <= P_STRM;
                    end
            // 发布限额由 sd_dat_rx 保证, 此处晚一拍看到计数达标即可发停止
            P_STRM: begin
                        if (st_blocks == want) begin
                            d_discard <= 1'b1; ph <= P_STOP;
                        end else if (d_bad || d_to || d_ovf) begin
                            d_discard <= 1'b1; strm_err <= 1'b1; ph <= P_STOP;
                        end
                    end
            P_STOP: if (!issued && !c_busy) begin
                        d_discard <= 1'b1;
                        issue(6'd12, 32'd0, R_48B);
                    end else if (c_done) begin
                        d_arm <= 1'b0; d_clear <= 1'b1; d_discard <= 1'b0;
                        st_err  <= strm_err || (c_err != 0);
                        st_done <= 1'b1;
                        ph <= P_READY;
                    end
            P_FAIL: begin init_err <= 1'b1; clk_on <= 1'b0; end
            default: ph <= P_FAIL;
            endcase
            if (ph != P_FAIL && ph < P_READY) init_stage <= ph[3:0];
            if (d_ok && !h_own && (ph == P_RD || ph == P_STRM || ph == P_STOP)) st_blocks <= st_blocks + 16'd1;
        end
    end
endmodule
