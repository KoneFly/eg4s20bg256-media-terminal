`timescale 1ns / 1ps
// ============================================================================
// sd_card_model — SDHC 卡行为模型(仿真专用, 与 DUT 独立实现)
//
// 时间域建模: 卡在 SDCLK 上升沿采样 CMD; 输出在 DS/识别模式于下降沿、HS 模式
//   于上升沿之后更新: [沿+T_OH, 沿+T_ODLY) 期间输出随机值(二值仿真下代替 X),
//   之后为新值。主机采样点若落在无效窗口, 会以高概率造成 CRC 错。
// 驱动用 "使能 + 数值" 表示(队列项 {en, v}), 不在变量里存 z。
// 任务内局部队列一律显式清空: 本仿真器下 automatic 任务的局部队列跨调用残留。
// CRC 用整多项式长除法计算(不同于 DUT 的 LFSR 结构)。
// 支持命令: CMD0/2/3/6/7/8/9/12/18/55, ACMD6/41。
// 内容: 第 lba 块第 off 字节 = card_byte(lba, off), TB 用同一函数核对。
// 检查: 主机 CMD 相对 SDCLK 上升沿的建立/保持(T_ISU/T_IH)、HS 下时钟高低电平宽度。
// 注入: CORRUPT_LBA 指定的块第一次发送时翻转 DAT2 一位(之后重读正确)。
// ============================================================================
module sd_card_model #(
    parameter real    T_OH        = 2.5,
    parameter real    T_ODLY      = 14.0,
    parameter real    T_ISU       = 6.0,
    parameter real    T_IH        = 2.0,
    parameter integer ACMD41_BUSY = 3,
    parameter bit     SUPPORT_HS  = 1,
    parameter integer NAC_MIN     = 2,
    parameter integer NAC_MAX     = 40,
    parameter integer CORRUPT_LBA = -1,
    parameter [21:0]  C_SIZE      = 22'h00EDC8
)(
    input  wire       sd_clk,
    inout  wire       sd_cmd,
    inout  wire [3:0] sd_dat
);
    // ---------------- 内容函数 ----------------
    // +img=<文件> 时块内容取自稀疏镜像(未列出的块全 0), 否则用伪随机内容函数
    bit use_img = 0;
    logic [4095:0] img [int unsigned];
    initial begin : load_img
        string fn; int fd, r; int unsigned lba; logic [4095:0] v;
        if ($value$plusargs("img=%s", fn)) begin
            fd = $fopen(fn, "r");
            if (fd == 0) $display("CARD ERROR: cannot open %s", fn);
            else begin
                use_img = 1;
                while (!$feof(fd)) begin
                    r = $fscanf(fd, "%h %h", lba, v);
                    if (r == 2) img[lba] = v;
                end
                $fclose(fd);
            end
        end
    end
    function automatic [7:0] card_byte(input int unsigned lba, input int off);
        int unsigned x;
        if (use_img) begin
            card_byte = img.exists(lba) ? img[lba][4095 - 8*off -: 8] : 8'h00;
        end else begin
            x = lba * 32'h9E3779B1 + off * 32'h85EBCA6B;
            x = x ^ (x >> 15);
            card_byte = x[7:0] ^ x[23:16];
        end
    endfunction

    // ---------------- CRC(长除法) ----------------
    function automatic [6:0] crc7_div(input logic bits[$]);
        logic [7:0] r; int i;
        r = 0;
        for (i = 0; i < bits.size() + 7; i++) begin
            r = {r[6:0], (i < bits.size()) ? bits[i] : 1'b0};
            if (r[7]) r = r ^ 8'h89;
        end
        crc7_div = r[6:0];
    endfunction

    function automatic [15:0] crc16_div(input logic bits[$]);
        logic [16:0] r; int i;
        r = 0;
        for (i = 0; i < bits.size() + 16; i++) begin
            r = {r[15:0], (i < bits.size()) ? bits[i] : 1'b0};
            if (r[16]) r = r ^ 17'h11021;
        end
        crc16_div = r[15:0];
    endfunction

    // ---------------- 输出队列与驱动 ----------------
    logic [1:0] cmd_q[$];       // {en, v}
    logic [7:0] dat_q[$];       // {en[3:0], v[3:0]}
    logic       cmd_en = 1'b0, cmd_v = 1'b1;
    logic [3:0] dat_en = 4'b0, dat_v = 4'hF;
    assign sd_cmd = cmd_en ? cmd_v : 1'bz;
    genvar gl;
    generate for (gl = 0; gl < 4; gl++) begin : DL
        assign sd_dat[gl] = dat_en[gl] ? dat_v[gl] : 1'bz;
    end endgenerate
    localparam logic [1:0] CZ = 2'b00;
    localparam logic [7:0] DZ = 8'h00;
    function automatic logic [1:0] cb(input logic b); cb = {1'b1, b}; endfunction
    function automatic logic [7:0] db(input logic [3:0] v); db = {4'hF, v}; endfunction

    bit   hs = 0;
    int   errors = 0;
    int   blocks_sent = 0;
    int   stop_count = 0;

    logic [1:0] cmd_cur = CZ;
    logic [7:0] dat_cur = DZ;
    task automatic drive_edge();
        logic [1:0] c; logic [7:0] d;
        c = (cmd_q.size() != 0) ? cmd_q.pop_front() : CZ;
        d = (dat_q.size() != 0) ? dat_q.pop_front() : DZ;
        if (c != cmd_cur) begin
            cmd_en <= #(T_OH) (c[1] | cmd_cur[1]);
            cmd_v  <= #(T_OH) $urandom_range(0, 1);
            cmd_en <= #(T_ODLY) c[1];
            cmd_v  <= #(T_ODLY) c[0];
        end
        if (d != dat_cur) begin
            dat_en <= #(T_OH) (d[7:4] | dat_cur[7:4]);
            dat_v  <= #(T_OH) 4'($urandom_range(0, 15));
            dat_en <= #(T_ODLY) d[7:4];
            dat_v  <= #(T_ODLY) d[3:0];
        end
        cmd_cur = c; dat_cur = d;
    endtask

    always @(negedge sd_clk) if (!hs) drive_edge();

    // ---------------- 主机时序检查 ----------------
    realtime t_cmd_chg = 0, t_rise = -100, t_fall = -100, t_card_rel = -100;
    always @(negedge cmd_en) t_card_rel = $realtime;
    // 卡自身释放 CMD 引起的电平变化不是主机输出, 不计入主机建立/保持检查
    always @(sd_cmd) if ($realtime != t_card_rel) begin
        t_cmd_chg = $realtime;
        if (!card_drives && ($realtime - t_rise) < T_IH && $realtime > 1000) begin
            $display("CARD ERROR %0t: CMD hold violated (%0.2fns)", $realtime, $realtime - t_rise);
            errors++;
        end
    end
    always @(negedge sd_clk) begin
        if (hs && ($realtime - t_rise) < 7.0) begin $display("CARD ERROR: CLK high < 7ns"); errors++; end
        t_fall = $realtime;
    end

    // ---------------- 命令接收 ----------------
    typedef enum { S_IDLE, S_READY, S_IDENT, S_STBY, S_TRAN, S_DATA } cst_t;
    cst_t     st = S_IDLE;
    bit       app = 0;
    bit       wide = 0;
    int       acmd41_n = 0;
    logic [15:0] rca = 16'h1234;
    bit       card_drives;
    logic [47:0] sh;
    int       nbits = 0;
    bit       rx_on = 0;

    // 多块读状态
    bit          streaming = 0;
    int unsigned s_lba;
    bit          corrupted_once = 0;

    assign card_drives = cmd_en || cmd_cur[1] || (cmd_q.size() != 0);

    always @(posedge sd_clk) begin
        if (hs && ($realtime - t_fall) < 7.0 && t_fall > 0) begin $display("CARD ERROR: CLK low < 7ns"); errors++; end
        if (!card_drives && ($realtime - t_cmd_chg) < T_ISU && $realtime > 1000) begin
            $display("CARD ERROR %0t: CMD setup violated (%0.2fns)", $realtime, $realtime - t_cmd_chg);
            errors++;
        end
        t_rise = $realtime;
        if (hs) drive_edge();

        if (!card_drives) begin
            if (!rx_on) begin
                if (sd_cmd === 1'b0) begin rx_on = 1; nbits = 1; sh = 48'd0; end
            end else begin
                sh = {sh[46:0], sd_cmd};
                nbits++;
                if (nbits == 48) begin
                    rx_on = 0;
                    handle_cmd(sh);
                end
            end
        end
        // 多块读: 队列将空时补下一块(块间隔随机)
        if (streaming && dat_q.size() < 4) push_block(s_lba++, 1);
    end

    // ---------------- 响应构造 ----------------
    task automatic push_idle_cmd(input int n);
        repeat (n) cmd_q.push_back(CZ);
    endtask

    task automatic resp48(input [5:0] idx, input [31:0] payload, input bit nocrc);
        logic b[$]; logic [6:0] c; int i;
        b.delete();
        b.push_back(0); b.push_back(0);
        for (i = 5; i >= 0; i--) b.push_back(idx[i]);
        for (i = 31; i >= 0; i--) b.push_back(payload[i]);
        c = nocrc ? 7'h7F : crc7_div(b);
        for (i = 6; i >= 0; i--) b.push_back(c[i]);
        b.push_back(1);
        push_idle_cmd($urandom_range(2, 10));
        foreach (b[i]) cmd_q.push_back(cb(b[i]));
    endtask

    task automatic resp136(input [119:0] body);
        logic b[$]; logic c[$]; logic [6:0] cr; int i;
        b.delete(); c.delete();
        for (i = 119; i >= 0; i--) c.push_back(body[i]);
        cr = crc7_div(c);
        b.push_back(0); b.push_back(0);
        for (i = 0; i < 6; i++) b.push_back(1);
        foreach (c[i]) b.push_back(c[i]);
        for (i = 6; i >= 0; i--) b.push_back(cr[i]);
        b.push_back(1);
        push_idle_cmd($urandom_range(2, 10));
        foreach (b[i]) cmd_q.push_back(cb(b[i]));
    endtask

    function automatic [31:0] r1_status();
        r1_status = {19'd0, 4'(st), 3'b100, app, 5'd0};   // READY_FOR_DATA=1
    endfunction

    // 数据块: 按字节数组构造, 每线 CRC16 独立
    task automatic push_data(input logic [7:0] bytes[$], input bit w, input int nac);
        logic lane[4][$]; logic [15:0] c[4]; int i, l, k;
        for (l = 0; l < 4; l++) lane[l].delete();
        repeat (nac) dat_q.push_back(DZ);
        if (w) begin
            dat_q.push_back(db(4'b0000));
            foreach (bytes[i]) begin
                dat_q.push_back(db(bytes[i][7:4]));
                dat_q.push_back(db(bytes[i][3:0]));
                for (l = 0; l < 4; l++) begin lane[l].push_back(bytes[i][4+l]); lane[l].push_back(bytes[i][l]); end
            end
            for (l = 0; l < 4; l++) c[l] = crc16_div(lane[l]);
            for (k = 15; k >= 0; k--) dat_q.push_back(db({c[3][k], c[2][k], c[1][k], c[0][k]}));
            dat_q.push_back(db(4'b1111));
        end else begin
            dat_q.push_back(8'h10);
            foreach (bytes[i]) for (k = 7; k >= 0; k--) begin
                dat_q.push_back({4'h1, 3'b000, bytes[i][k]}); lane[0].push_back(bytes[i][k]);
            end
            c[0] = crc16_div(lane[0]);
            for (k = 15; k >= 0; k--) dat_q.push_back({4'h1, 3'b000, c[0][k]});
            dat_q.push_back(8'h11);
        end
    endtask

    task automatic push_block(input int unsigned lba, input bit gap);
        logic [7:0] bytes[$]; int i, pos;
        bytes.delete();
        for (i = 0; i < 512; i++) bytes.push_back(card_byte(lba, i));
        push_data(bytes, wide, gap ? $urandom_range(NAC_MIN, NAC_MAX) : NAC_MIN);
        if (CORRUPT_LBA >= 0 && lba == CORRUPT_LBA && !corrupted_once) begin
            corrupted_once = 1;
            pos = dat_q.size() - 18 - 300;              // 块中部的一个 nibble
            dat_q[pos] = dat_q[pos] ^ 8'h04;
        end
        blocks_sent++;
    endtask

    task automatic push_busy(input int n);
        dat_q.delete();
        repeat (2) dat_q.push_back(DZ);
        repeat (n) dat_q.push_back(8'h10);
    endtask

    task automatic handle_cmd(input [47:0] c);
        logic b[$]; int i; logic [5:0] idx; logic [31:0] arg; bit was_app;
        logic [7:0] st64[$];
        logic [127:0] csd;
        b.delete(); st64.delete();
        for (i = 47; i >= 8; i--) b.push_back(c[i]);
        idx = c[45:40]; arg = c[39:8];
        if ($test$plusargs("trace")) $display("CARD %0t rx %h st=%0d app=%0d", $realtime, c, st, app);
        if (c[46] !== 1'b1 || c[0] !== 1'b1 || crc7_div(b) !== c[7:1]) begin
            $display("CARD ERROR %0t: bad command frame/CRC idx=%0d", $realtime, idx);
            errors++;
            return;
        end
        was_app = app; app = 0;
        if (was_app) begin
            case (idx)
            6'd41: begin
                if (st != S_IDLE && st != S_READY) return;
                acmd41_n++;
                if (acmd41_n > ACMD41_BUSY) begin st = S_READY; resp48(6'h3F, 32'hC0FF8000, 1); end
                else resp48(6'h3F, 32'h00FF8000, 1);
            end
            6'd6: begin
                if (st != S_TRAN) return;
                resp48(idx, r1_status(), 0);
                wide = (arg[1:0] == 2'b10);
            end
            default: begin $display("CARD ERROR: unsupported ACMD%0d", idx); errors++; end
            endcase
            return;
        end
        case (idx)
        6'd0:  begin st = S_IDLE; wide = 0; hs = 0; streaming = 0; acmd41_n = 0; end
        6'd8:  resp48(idx, {20'd0, arg[11:0]}, 0);
        6'd55: begin app = 1; resp48(idx, r1_status() | 32'h20, 0); end
        6'd2:  if (st == S_READY) begin st = S_IDENT; resp136(120'h1D_4144_5344_3634_47_30_12345678_0_AB); end
        6'd3:  if (st == S_IDENT) begin st = S_STBY; resp48(idx, {rca, 16'h0500}, 0); end
        6'd9:  if (st == S_STBY) begin
                   csd = 128'd0;
                   csd[127:126] = 2'b01;  csd[119:112] = 8'h0E; csd[103:96] = 8'h32;
                   csd[95:84] = 12'h5B5;  csd[83:80] = 4'h9;    csd[69:48] = C_SIZE;
                   csd[46] = 1'b1;        csd[45:39] = 7'h7F;   csd[28:26] = 3'b010;
                   csd[25:22] = 4'h9;     csd[0] = 1'b1;
                   resp136(csd[127:8]);
               end
        6'd7:  if (arg[31:16] == rca && st == S_STBY) begin
                   st = S_TRAN; resp48(idx, r1_status(), 0); push_busy(20);
               end
        6'd6:  if (st == S_TRAN) begin
                   resp48(idx, r1_status(), 0);
                   for (i = 0; i < 64; i++) st64.push_back(8'h00);
                   st64[0] = 8'h00; st64[1] = 8'h64;                 // 最大电流
                   st64[12] = 8'h80; st64[13] = SUPPORT_HS ? 8'h03 : 8'h01;   // FG1 支持位
                   st64[16] = SUPPORT_HS ? 8'h01 : 8'h0F;            // FG1 选择结果
                   st64[17] = 8'h01;                                  // 数据结构版本 1
                   push_data(st64, wide, $urandom_range(NAC_MIN, NAC_MAX));
                   if (arg[31] && SUPPORT_HS) fork begin
                       // 状态块发送完后切换到 HS 时序
                       wait (dat_q.size() == 0);
                       hs = 1;
                   end join_none
               end
        6'd18: if (st == S_TRAN) begin
                   resp48(idx, r1_status(), 0);
                   st = S_DATA; s_lba = arg; streaming = 1;
                   push_block(s_lba++, 1);
               end
        6'd12: if (st == S_DATA) begin
                   streaming = 0;
                   stop_count++;
                   st = S_TRAN;
                   resp48(idx, r1_status(), 0);
                   push_busy($urandom_range(4, 60));
               end
        default: begin $display("CARD ERROR: unsupported CMD%0d", idx); errors++; end
        endcase
    endtask
endmodule
