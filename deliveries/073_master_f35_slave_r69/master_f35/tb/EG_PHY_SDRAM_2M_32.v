`timescale 1ns / 1ps
// ============================================================================
// EG_PHY_SDRAM_2M_32 — 仿真专用加严行为模型
//
// 与既有行为模型保持同一读时序语义(片内die首拍比JEDEC CL早一拍:
// READ在沿N0被采样, 首拍在N0+(CL-1)沿出现), 额外提供:
//   * 读突发流水: 多个READ排队, 间隔8拍的连续READ无缝衔接; 后发READ
//     到达起点时截断前一突发(JEDEC读中断语义)
//   * 时序检查(按T_CK_NS换算, EM638325最慢档): tRCD/tRP/tRAS(min/max)/
//     tRC/tRFC/tRRD/tWR/tMRD, 刷新最大间隔, 列地址BL8对齐, 写数据X,
//     预充电截断进行中的突发, 读输出期间收到写数据
//   * 统计: 刷新次数/最大间隔(拍), READ/WRITE命令数, 错误数
// 综合不使用本文件。
// ============================================================================
module EG_PHY_SDRAM_2M_32 (
    clk, ras_n, cas_n, we_n, addr, ba, dq, cs_n, dm0, dm1, dm2, dm3, cke
);
    parameter integer T_CK_PS     = 20000;   // 50MHz
    parameter integer REF_MAX_PS  = 15625000; // 4096次/64ms 的单次最大间隔
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

    // EM638325 最慢档(-7)最小值, 向上取整为拍数
    localparam integer C_RCD  = (21000 + T_CK_PS - 1) / T_CK_PS;
    localparam integer C_RP   = (21000 + T_CK_PS - 1) / T_CK_PS;
    localparam integer C_RAS  = (42000 + T_CK_PS - 1) / T_CK_PS;
    localparam integer C_RASX = 100000000 / T_CK_PS;
    localparam integer C_RC   = (63000 + T_CK_PS - 1) / T_CK_PS;
    localparam integer C_RFC  = (63000 + T_CK_PS - 1) / T_CK_PS;
    localparam integer C_RRD  = (14000 + T_CK_PS - 1) / T_CK_PS;
    localparam integer C_WR   = 2;
    localparam integer C_MRD  = 2;
    localparam integer C_REFX = REF_MAX_PS / T_CK_PS;

    localparam integer WORDS = 2097152;
    reg  [31:0] mem [0:WORDS-1];

    reg         bank_active [0:3];
    reg  [10:0] bank_row    [0:3];
    reg  [31:0] t_act       [0:3];   // 该bank最近ACT时刻
    reg  [31:0] t_pre       [0:3];   // 该bank最近PRE时刻
    reg  [31:0] t_wlast     [0:3];   // 该bank最近写数据拍

    reg  [31:0] now;                 // 模型拍计数(以命令采样沿计)
    reg  [31:0] t_last_act_any;
    reg  [31:0] t_last_ref;
    reg  [31:0] t_mrs;
    reg         ref_seen;

    reg         mode_set;
    reg  [3:0]  bl_reg;
    reg  [2:0]  cl_reg;

    reg         dq_oe_r;
    reg  [31:0] dq_r;

    // 读起点队列: 最多4个待启动READ
    reg  [2:0]  pq_cnt  [0:3];
    reg  [20:0] pq_addr [0:3];
    reg  [1:0]  pq_bank [0:3];
    reg  [1:0]  rd_bank;
    reg         pq_v    [0:3];
    // 当前输出突发
    reg  [20:0] rd_addr;
    reg  [3:0]  rd_beats;

    reg  [20:0] wr_addr;
    reg  [3:0]  wr_beats;
    reg  [1:0]  wr_bank;

    reg  [31:0] ref_count;
    reg  [31:0] ref_max_gap;
    reg  [31:0] read_cmd_count;
    reg  [31:0] write_cmd_count;
    reg  [31:0] err_count;
    reg  [31:0] trunc_count;

    wire [3:0]  dm = {dm3, dm2, dm1, dm0};
    wire [20:0] access_addr = {ba, bank_row[ba], addr[7:0]};

    assign dq = dq_oe_r ? dq_r : 32'bz;

    integer i;
    initial begin
        dq_oe_r = 1'b0; dq_r = 32'd0; rd_bank = 2'd0;
        mode_set = 1'b0; bl_reg = 4'd8; cl_reg = 3'd2;
        rd_addr = 0; rd_beats = 0; wr_addr = 0; wr_beats = 0; wr_bank = 0;
        now = 0; t_last_act_any = 0; t_last_ref = 0; t_mrs = 0; ref_seen = 0;
        ref_count = 0; ref_max_gap = 0; read_cmd_count = 0; write_cmd_count = 0;
        err_count = 0; trunc_count = 0;
        for (i = 0; i < 4; i = i + 1) begin
            bank_active[i] = 1'b0; bank_row[i] = 11'd0;
            t_act[i] = 0; t_pre[i] = 0; t_wlast[i] = 0;
            pq_v[i] = 1'b0; pq_cnt[i] = 3'd0; pq_addr[i] = 21'd0; pq_bank[i] = 2'd0;
        end
    end

    task model_err;
        input [8*48-1:0] msg;
        begin
            $display("MODEL ERROR @%0t now=%0d: %0s", $time, now, msg);
            err_count = err_count + 1;
        end
    endtask

    task write_beat;
        input [20:0] a;
        begin
            if (!dm0) mem[a][7:0]   = dq[7:0];
            if (!dm1) mem[a][15:8]  = dq[15:8];
            if (!dm2) mem[a][23:16] = dq[23:16];
            if (!dm3) mem[a][31:24] = dq[31:24];
            if (!(&dm) && (^dq === 1'bx)) model_err("WRITE data X/Z");
            if (dq_oe_r) model_err("WRITE data while model drives DQ");
        end
    endtask

    integer k;
    reg started;
    // 阻塞赋值顺序即模型内的因果顺序: 先推进输出/写流水, 再采样本沿命令
    always @(posedge clk) begin
        now = now + 1;

        // ---------- 读输出流水 ----------
        started = 1'b0;
        for (k = 0; k < 4; k = k + 1) begin
            if (pq_v[k]) begin
                if (pq_cnt[k] == 3'd1) begin
                    if (rd_beats != 0) trunc_count = trunc_count + 1;
                    rd_addr  = pq_addr[k];
                    rd_bank  = pq_bank[k];
                    rd_beats = bl_reg;
                    pq_v[k]  = 1'b0;
                    started  = 1'b1;
                end else begin
                    pq_cnt[k] = pq_cnt[k] - 3'd1;
                end
            end
        end
        if (rd_beats != 0) begin
            dq_r     <= mem[rd_addr];
            dq_oe_r  <= 1'b1;
            rd_addr  = {rd_addr[20:3], rd_addr[2:0] + 3'd1};
            rd_beats = rd_beats - 4'd1;
        end else begin
            dq_oe_r  <= 1'b0;
        end

        // ---------- 写突发后续拍 ----------
        if (wr_beats != 0) begin
            write_beat(wr_addr);
            t_wlast[wr_bank] = now;
            wr_addr  = {wr_addr[20:3], wr_addr[2:0] + 3'd1};
            wr_beats = wr_beats - 4'd1;
        end

        // ---------- 刷新间隔 ----------
        if (ref_seen && (now - t_last_ref) == C_REFX + 1)
            model_err("refresh interval exceeded");

        // ---------- 命令采样 ----------
        if (cke && !cs_n) begin
            if ({ras_n, cas_n, we_n} != 3'b111 && mode_set == 1'b0 && {ras_n, cas_n, we_n} != 3'b000
                && {ras_n, cas_n, we_n} != 3'b010 && {ras_n, cas_n, we_n} != 3'b001)
                model_err("command before MRS");
            if ({ras_n, cas_n, we_n} != 3'b111 && mode_set && (now - t_mrs) < C_MRD)
                model_err("tMRD");
            case ({ras_n, cas_n, we_n})
            3'b111: ;
            3'b011: begin // ACTIVE
                if (bank_active[ba]) model_err("ACTIVE to open bank");
                if ((now - t_pre[ba]) < C_RP) model_err("tRP (PRE->ACT)");
                if ((now - t_act[ba]) < C_RC && t_act[ba] != 0) model_err("tRC");
                if ((now - t_last_act_any) < C_RRD && t_last_act_any != 0) model_err("tRRD");
                if (ref_seen && (now - t_last_ref) < C_RFC) model_err("tRFC (REF->ACT)");
                bank_active[ba] = 1'b1;
                bank_row[ba]    = addr;
                t_act[ba]       = now;
                t_last_act_any  = now;
            end
            3'b101: begin // READ
                if (!bank_active[ba]) model_err("READ to closed bank");
                else begin
                    if ((now - t_act[ba]) < C_RCD) model_err("tRCD (READ)");
                    if (addr[2:0] != 3'd0) model_err("READ col not BL8 aligned");
                    if (addr[10]) model_err("auto-precharge not supported");
                    if (wr_beats != 0) model_err("READ interrupts write burst");
                    begin : enq
                        integer s; reg done_q; done_q = 1'b0;
                        for (s = 0; s < 4; s = s + 1)
                            if (!pq_v[s] && !done_q) begin
                                pq_v[s] = 1'b1; pq_cnt[s] = cl_reg - 3'd1;
                                pq_addr[s] = access_addr; pq_bank[s] = ba; done_q = 1'b1;
                            end
                        if (!done_q) model_err("read queue overflow");
                    end
                    read_cmd_count = read_cmd_count + 1;
                end
            end
            3'b100: begin // WRITE
                if (!bank_active[ba]) model_err("WRITE to closed bank");
                else begin
                    if ((now - t_act[ba]) < C_RCD) model_err("tRCD (WRITE)");
                    if (addr[2:0] != 3'd0) model_err("WRITE col not BL8 aligned");
                    if (addr[10]) model_err("auto-precharge not supported");
                    if (rd_beats != 0 || pq_v[0] || pq_v[1] || pq_v[2] || pq_v[3])
                        model_err("WRITE while read data pending");
                    write_beat(access_addr);
                    t_wlast[ba] = now;
                    wr_addr  = {access_addr[20:3], access_addr[2:0] + 3'd1};
                    wr_beats = bl_reg - 4'd1;
                    wr_bank  = ba;
                    write_cmd_count = write_cmd_count + 1;
                end
            end
            3'b010: begin // PRECHARGE
                for (k = 0; k < 4; k = k + 1) begin
                    if (addr[10] || ba == k[1:0]) begin
                        if (bank_active[k]) begin
                            if ((now - t_act[k]) < C_RAS) model_err("tRAS min");
                            if ((now - t_act[k]) > C_RASX) model_err("tRAS max");
                            if ((now - t_wlast[k]) < C_WR) model_err("tWR");
                        end
                        bank_active[k] = 1'b0;
                        t_pre[k] = now;
                    end
                end
                // 只有对正在突发的同一 bank 预充电才截断该突发
                if (wr_beats != 0 && (addr[10] || ba == wr_bank)) model_err("PRE truncates write burst");
                if (rd_beats != 0 && (addr[10] || ba == rd_bank)) model_err("PRE truncates read burst");
                for (k = 0; k < 4; k = k + 1)
                    if (pq_v[k] && (addr[10] || ba == pq_bank[k])) model_err("PRE truncates pending read");
            end
            3'b001: begin // AUTO REFRESH
                if (bank_active[0] || bank_active[1] || bank_active[2] || bank_active[3])
                    model_err("REFRESH with open bank");
                for (k = 0; k < 4; k = k + 1)
                    if ((now - t_pre[k]) < C_RP && t_pre[k] != 0) model_err("tRP (PRE->REF)");
                if (ref_seen && (now - t_last_ref) < C_RFC) model_err("tRFC (REF->REF)");
                if (ref_seen && mode_set && (now - t_last_ref) > ref_max_gap)
                    ref_max_gap = now - t_last_ref;
                ref_seen   = 1'b1;
                t_last_ref = now;
                ref_count  = ref_count + 1;
            end
            3'b000: begin // MRS
                if (bank_active[0] || bank_active[1] || bank_active[2] || bank_active[3])
                    model_err("MRS with open bank");
                case (addr[2:0])
                    3'b001:  bl_reg = 4'd1;
                    3'b010:  bl_reg = 4'd2;
                    3'b011:  bl_reg = 4'd4;
                    3'b100:  bl_reg = 4'd8;   // 与既有行为模型/上板实测值一致
                    default: begin bl_reg = 4'd8; model_err("unmodeled burst length code"); end
                endcase
                if (addr[3]) model_err("interleaved burst not modeled");
                cl_reg   = addr[6:4];
                mode_set = 1'b1;
                t_mrs    = now;
            end
            default: model_err("unsupported command");
            endcase
        end
    end

endmodule
