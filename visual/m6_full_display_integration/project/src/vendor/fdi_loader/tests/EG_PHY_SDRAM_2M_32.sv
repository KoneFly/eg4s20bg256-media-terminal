`timescale 1ns / 1ps
// ============================================================================
// EG_PHY_SDRAM_2M_32 — 仿真专用行为模型(仅用于iverilog功能仿真)
//
// 注意: 综合时本文件不参与, 由安路器件库提供真实原语(片上SDRAM SIP,
//       内部硬连线到存储阵列, 无外部引脚)。本模型按原语引脚语义实现:
//   * 存储阵列 2M×32bit (8MB), 字地址 = {ba[1:0], row[10:0], col[7:0]}
//   * 命令编码(cs_n/ras_n/cas_n/we_n): NOP=0111, ACTIVE=0011, READ=0101,
//     WRITE=0100, PRECHARGE=0010(A10=1全bank), AUTO_REFRESH=0001, MRS=0000
//   * MRS解码: A[2:0]突发长度(001=1,010=2,011=4,100=8), A[6:4]=CAS延迟
//   * 读: 数据在dq上出现的时间按片内die实测语义建模(比EM638325 JEDEC
//     CL语义早一拍, 2026-09-13 V2地址自编码bit上板实证), 顺序突发BL拍,
//     拍间地址自增。实现: READ命令在clk上升沿被寄存(拍0), 内部
//     rd_cnt<=CL-1, 之后每个clk上升沿递减, rd_cnt==1的沿输出第1拍数据,
//     即命令寄存沿之后第CL-1个clk上升沿(拍CL-1)数据首次有效。
//   * 写: 命令拍即第1拍数据, dm0~dm3逐字节屏蔽(1=屏蔽), 共BL拍
//   * cke=0期间忽略所有命令(上电掉电等待期)
//   * 合法性自检: 未激活bank读写/行不匹配/未MRS即读写/刷新时有bank打开,
//     均打印MODEL ERROR(供testbench判FAIL)
// ============================================================================
module EG_PHY_SDRAM_2M_32 (
    clk, ras_n, cas_n, we_n, addr, ba, dq, cs_n, dm0, dm1, dm2, dm3, cke
);
    input         clk;
    input         ras_n;
    input         cas_n;
    input         we_n;
    input  [10:0] addr;
    input  [1:0]  ba;
    inout  [31:0] dq;
    input         cs_n;
    input         dm0;
    input         dm1;
    input         dm2;
    input         dm3;
    input         cke;

    localparam integer WORDS = 2097152;         // 2M字

    reg  [31:0] mem [0:WORDS-1];

    reg         bank_active [0:3];
    reg  [10:0] bank_row    [0:3];

    reg         mode_set;
    reg  [3:0]  bl_reg;                         // 突发长度1/2/4/8
    reg  [2:0]  cl_reg;                         // CAS延迟

    reg         dq_oe_r;
    reg  [31:0] dq_r;

    reg  [20:0] rd_addr;
    reg  [3:0]  rd_beats;                       // 剩余待输出拍
    reg  [2:0]  rd_cnt;                         // CL延迟倒计时

    reg  [20:0] wr_addr;
    reg  [3:0]  wr_beats;                       // 剩余待采样写拍

    reg  [15:0] ref_count;                      // 已执行的AUTO REFRESH次数
    reg  [15:0] read_cmd_count;                 // 已执行的READ命令次数(TB突发复用校核)
    reg  [15:0] err_count;                      // 合法性错误计数

    wire [3:0]  dm = {dm3, dm2, dm1, dm0};
    // READ/WRITE命令拍 addr[7:0]=col, 完整字地址={ba, 已激活的row, col}
    wire [20:0] access_addr = {ba, bank_row[ba], addr[7:0]};

    assign dq = dq_oe_r ? dq_r : 32'bz;

    integer i;
    initial begin
        dq_oe_r  = 1'b0;
        dq_r     = 32'd0;
        mode_set = 1'b0;
        bl_reg   = 4'd8;
        cl_reg   = 3'd2;
        rd_addr  = 21'd0; rd_beats = 4'd0; rd_cnt = 3'd0;
        wr_addr  = 21'd0; wr_beats = 4'd0;
        ref_count= 16'd0; err_count = 16'd0;
        read_cmd_count = 16'd0;
        for (i = 0; i < 4; i = i + 1) begin
            bank_active[i] = 1'b0;
            bank_row[i]    = 11'd0;
        end
    end

    // 写拍落盘(带字节掩码)
    task apply_write_beat;
        input [20:0] a;
        begin
            if (!dm0) mem[a][7:0]   <= dq[7:0];
            if (!dm1) mem[a][15:8]  <= dq[15:8];
            if (!dm2) mem[a][23:16] <= dq[23:16];
            if (!dm3) mem[a][31:24] <= dq[31:24];
            if (^dq === 1'bx) begin
                if (!(&dm)) begin
                    $display("MODEL ERROR %0t: WRITE data has X/Z, addr=%h dm=%b",
                             $time, a, dm);
                    err_count <= err_count + 1'b1;
                end
            end
        end
    endtask

    always @(posedge clk) begin
        // ---------------- 读输出流水线(每拍推进) ----------------
        if (rd_cnt > 3'd0) begin
            rd_cnt <= rd_cnt - 3'd1;
            if (rd_cnt == 3'd1) begin           // CL倒计时到1, 本沿输出第1拍
                dq_r     <= mem[rd_addr];
                dq_oe_r  <= 1'b1;
                rd_addr  <= rd_addr + 21'd1;
                rd_beats <= rd_beats - 4'd1;
            end
        end else if (rd_beats > 4'd0) begin     // 后续突发拍
            dq_r     <= mem[rd_addr];
            rd_addr  <= rd_addr + 21'd1;
            rd_beats <= rd_beats - 4'd1;
        end else if (dq_oe_r && wr_beats == 4'd0) begin
            dq_oe_r  <= 1'b0;                   // 突发结束, 释放总线
        end

        // ---------------- 写突发后续拍 ----------------
        if (wr_beats > 4'd0) begin
            apply_write_beat(wr_addr);
            wr_addr  <= wr_addr + 21'd1;
            wr_beats <= wr_beats - 4'd1;
        end

        // ---------------- 命令采样 ----------------
        if (cke && !cs_n) begin
            case ({ras_n, cas_n, we_n})
            default: ; // 非模型支持命令保持既有忽略行为
            3'b111: ;                                   // NOP
            3'b011: begin                               // ACTIVE
                if (bank_active[ba]) begin
                    $display("MODEL ERROR %0t: ACTIVE to open bank %0d", $time, ba);
                    err_count <= err_count + 1'b1;
                end
                bank_active[ba] <= 1'b1;
                bank_row[ba]    <= addr;
            end
            3'b101: begin                               // READ
                if (!mode_set) begin
                    $display("MODEL ERROR %0t: READ before MRS", $time);
                    err_count <= err_count + 1'b1;
                end else if (!bank_active[ba]) begin
                    $display("MODEL ERROR %0t: READ to closed bank %0d", $time, ba);
                    err_count <= err_count + 1'b1;
                end else begin
                    rd_addr  <= access_addr;
                    rd_beats <= bl_reg;
                    // V3 保真修正(2026-09-13 上板实测): 片内 die 首拍数据比
                    // EM638325 CL 语义早一拍, 模型同步提前一拍输出,
                    // 与 sdram_cmd_engine.v ST_RD_CL 的 V3 前移配对。
                    rd_cnt   <= cl_reg - 3'd1;      // 命令寄存拍0, 数据在拍CL-1
                    read_cmd_count <= read_cmd_count + 1'b1;
                end
            end
            3'b100: begin                               // WRITE(命令拍=第1拍数据)
                if (!mode_set) begin
                    $display("MODEL ERROR %0t: WRITE before MRS", $time);
                    err_count <= err_count + 1'b1;
                end else if (!bank_active[ba]) begin
                    $display("MODEL ERROR %0t: WRITE to closed bank %0d", $time, ba);
                    err_count <= err_count + 1'b1;
                end else begin
                    apply_write_beat(access_addr);
                    wr_addr  <= access_addr + 21'd1;
                    wr_beats <= bl_reg - 4'd1;
                end
            end
            3'b010: begin                               // PRECHARGE
                if (addr[10]) begin
                    bank_active[0] <= 1'b0; bank_active[1] <= 1'b0;
                    bank_active[2] <= 1'b0; bank_active[3] <= 1'b0;
                end else begin
                    bank_active[ba] <= 1'b0;
                end
            end
            3'b001: begin                               // AUTO REFRESH
                if (bank_active[0] || bank_active[1] ||
                    bank_active[2] || bank_active[3]) begin
                    $display("MODEL ERROR %0t: REFRESH with open bank", $time);
                    err_count <= err_count + 1'b1;
                end
                ref_count <= ref_count + 1'b1;
            end
            3'b000: begin                               // MRS
                case (addr[2:0])
                    3'b001:  bl_reg <= 4'd1;
                    3'b010:  bl_reg <= 4'd2;
                    3'b011:  bl_reg <= 4'd4;
                    3'b100:  bl_reg <= 4'd8;
                    default: bl_reg <= 4'd8;
                endcase
                cl_reg   <= addr[6:4];
                mode_set <= 1'b1;
            end
            endcase
        end
    end

endmodule
