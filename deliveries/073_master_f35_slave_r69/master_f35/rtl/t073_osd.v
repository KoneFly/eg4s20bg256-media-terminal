`timescale 1ns / 1ps
// ============================================================================
// t073_osd — 文字叠加层: ctrl 域排版器写字符 RAM, 像素域按 16×16 字格读出并画 5×7 字模
//
// 字符 RAM: 16 行 × 64 列, 每项 8 位 = {属性[1:0], 字符码[5:0]}, 码 0 = 透明。
//   属性: 0 数值(白字) 1 名称(浅青字) 2 标签块(黄字、蓝调底) 3 菜单焦点行(同 2)。
//   底色为半透明: 图像亮度保留约 90%(10% 暗化), 标签块与焦点行再叠加蓝调。
// 字符码与字串/字模 ROM 见 t073_osd_rom.vh(LUT 实现, 不依赖 BRAM 初值)。
// 版式(每格 16 像素):
//   仪表盘 第 0 行(INFO=ON): 64 列字段串, 像素端以 scroll 偏移横向读取并按 64 列回绕,
//     整行每帧左移 1 像素, 首尾循环。
//   菜单 第 3..14 行, 面板宽 26 列: 标题栏 / 7 项(名称第 1 列, 数值第 14 列, 焦点行
//     整行高亮并以 < > 括住数值) / 空行 / 两行键位提示。
//   播放器 第 4..6 行(player_on): 曲目 / 播放状态 + 已播放/总时长 / 进度条, 第 23 列起;
//     背景就是当前图片(不做封面/虚化合成)。
// 排版器连续逐行刷新, 每行按"程序"串行输出字串、数字与跳列:
//   数字字段现场做二进制 -> BCD(移位加 3, 14 拍), 去掉前导零; 时间直接以 BCD 计数。
// 像素域: 读地址取下一像素所在字格, RAM 出数正好对齐当前像素; 字模 2 倍放大, 字格内偏移 (3,1)。
// ============================================================================
module t073_osd #(
    parameter [31:0] SEC_CYCLES = 32'd50_000_000
)(
    input  wire        clk,
    input  wire        rst_n,
    // 显示开关
    input  wire        status_on,            // INFO = ON
    input  wire        menu_on,              // SW1
    input  wire        player_on,            // 音乐播放器页
    // 菜单
    input  wire [2:0]  focus,
    input  wire        music_on,
    input  wire [4:0]  volume,
    input  wire [2:0]  trans_sel,
    input  wire [5:0]  period_s,
    input  wire [1:0]  spec_sel,
    // 媒体状态
    input  wire        vid_mode,             // 视频页
    input  wire [1:0]  msg,                  // 0 无 1 NO CARD 2 RELOAD 3 NO FILE
    input  wire [5:0]  fps,
    input  wire        fmt565,
    input  wire        v_paused,
    input  wire        v_playing,
    input  wire        time_clear,           // 换片/重新播放
    input  wire [3:0]  pic_idx,
    input  wire [3:0]  vid_idx,
    input  wire        wall_on,
    input  wire [1:0]  zoom,
    input  wire [15:0] src_w,
    input  wire [15:0] src_h,
    input  wire [1:0]  wav_slot,
    input  wire [1:0]  wav_state,            // 0 关 1 播放 2 准备 3 无可播曲目
    input  wire        wav_sample,           // 音乐每送出一个样本字(单拍, 2 样本/字; 领先实际放音不超过缓冲深度)
    input  wire        wav_new,              // 新曲开始(单拍)
    input  wire        wav_len_valid,        // 曲目样本总数有效(文件头解析完成)
    input  wire [31:0] wav_total,            // 当前曲目样本总数
    input  wire        spk_only,
    // 像素域
    input  wire        pclk,
    input  wire        prst,
    input  wire        frame_boundary,
    input  wire        de,
    input  wire [9:0]  x,
    input  wire [9:0]  y,
    input  wire [15:0] rgb_in,
    output wire [15:0] rgb_out
);
    // ======================= 计时(BCD) =======================
    // 秒节拍: 运行时间常走; 视频时间只在播放且未暂停时走
    reg [31:0] sec_div;
    wire       sec_tick = (sec_div == SEC_CYCLES - 1);
    always @(posedge clk or negedge rst_n)
        if (!rst_n) sec_div <= 32'd0; else sec_div <= sec_tick ? 32'd0 : sec_div + 32'd1;
    // mm:ss 递增(BCD); 分钟到 99 回绕
    function [15:0] mmss_inc(input [15:0] t);
        reg [3:0] sl, sh, ml, mh;
        begin
            {mh, ml, sh, sl} = t;
            if (sl != 4'd9) sl = sl + 4'd1;
            else begin
                sl = 4'd0;
                if (sh != 4'd5) sh = sh + 4'd1;
                else begin
                    sh = 4'd0;
                    if (ml != 4'd9) ml = ml + 4'd1;
                    else begin ml = 4'd0; mh = (mh == 4'd9) ? 4'd0 : mh + 4'd1; end
                end
            end
            mmss_inc = {mh, ml, sh, sl};
        end
    endfunction
    // 音乐: 已送样本字每满 1 秒(24038 字)推进 wt; 总时长在文件头有效后以逐秒减法求出(无除法器),
    //   进度 = 已送字数 / (总样本数/256) 的整数部分, 0..128
    localparam [31:0] SPS = 32'd48077, WPS = 32'd24038;
    reg [15:0] ws_acc;
    reg [31:0] len_rem, bar_step, bar_acc;
    reg [15:0] wlen;                     // 总时长 mm:ss(BCD)
    reg        len_busy, len_seen;
    reg [7:0]  bar_n;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            ws_acc <= 0; len_rem <= 0; bar_step <= 0; bar_acc <= 0; wlen <= 0; len_busy <= 0; len_seen <= 0; bar_n <= 0;
        end else if (wav_new) begin
            ws_acc <= 0; len_rem <= 0; bar_step <= 0; bar_acc <= 0; wlen <= 0; len_busy <= 0; len_seen <= 0; bar_n <= 0;
        end else begin
            if (wav_len_valid && !len_seen) begin
                len_seen <= 1'b1; len_busy <= 1'b1; len_rem <= wav_total; bar_step <= {8'd0, wav_total[31:8]};
            end else if (len_busy) begin
                if (len_rem >= SPS) begin len_rem <= len_rem - SPS; wlen <= mmss_inc(wlen); end
                else len_busy <= 1'b0;
            end
            if (wav_sample) begin
                ws_acc <= (ws_acc == WPS[15:0] - 16'd1) ? 16'd0 : ws_acc + 16'd1;
                if (len_seen && bar_n != 8'd128) begin
                    if (bar_acc + 32'd1 >= bar_step) begin bar_acc <= 0; bar_n <= bar_n + 8'd1; end
                    else bar_acc <= bar_acc + 32'd1;
                end
            end
        end
    wire wav_tick = wav_sample && (ws_acc == WPS[15:0] - 16'd1);
    reg [15:0] vt, wt;                   // 视频 / 音乐已播放 mm:ss
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin vt <= 16'd0; wt <= 16'd0; end
        else begin
            if (time_clear) vt <= 16'd0;
            else if (sec_tick && vid_mode && v_playing && !v_paused) vt <= mmss_inc(vt);
            if (wav_new) wt <= 16'd0;
            else if (wav_tick) wt <= mmss_inc(wt);
        end

    // ======================= 字串/字模 ROM =======================
`include "t073_osd_rom.vh"

    // ======================= 行程序 =======================
    // 记号 8 位: [7:6] 00 字串(字串号) / 01 去前导零数字(字段) / 10 定长 BCD 两位(字段) / 11 跳到列
    localparam [3:0] F_FPS = 0, F_VOL = 1, F_PER = 2, F_PIC = 3, F_W = 4, F_H = 5, F_SLOT = 6, F_LM = 7, F_LS = 8,
                     F_VM = 9, F_VS = 10, F_WM = 11, F_WS = 12;
    function [7:0] ks(input [5:0] s); ks = {2'b00, s}; endfunction
    function [7:0] kn(input [3:0] f); kn = {4'b0100, f}; endfunction
    function [7:0] kb(input [3:0] f); kb = {4'b1000, f}; endfunction
    function [7:0] kt(input [5:0] c); kt = {2'b11, c}; endfunction

    wire [5:0] s_trans = (trans_sel == 3'd1) ? S_FADE : (trans_sel == 3'd2) ? S_WIPE : (trans_sel == 3'd3) ? S_CURT :
                         (trans_sel == 3'd4) ? S_AUTO : S_OFF;
    wire [5:0] s_spec  = (spec_sel == 2'd1) ? S_PLAY : (spec_sel == 2'd2) ? S_PRAW : S_OFF;
    wire [5:0] s_res   = (zoom == 2'd1) ? S_RES2 : (zoom == 2'd2) ? S_RES4 : S_RES;
    wire [5:0] s_msg   = (msg == 2'd1) ? S_NOCARD : (msg == 2'd2) ? S_RELOAD : S_NOFILE;
    wire [5:0] s_wst   = (wav_state == 2'd1) ? S_PLAY : (wav_state == 2'd3) ? S_NOWAV : S_STOP;
    wire       grp2    = pic_idx > 4'd4;

    reg [3:0] row;
    reg [4:0] ti;
    reg [7:0] tok;
    // 记号先寄存再译码: 行程序(含媒体状态输入)与字串表/数字通路分在两拍
    reg [7:0]  tok_q;
    // 菜单项行(5..11): 名称 / 跳列 / [<] / 数值 / [>]
    wire [2:0] mi   = row[2:0] - 3'd5;
    wire       mitem = menu_on && row >= 4'd5 && row <= 4'd11;
    wire       mfoc = mitem && mi == focus;
    always @(*) begin
        tok = 8'd0;
        case (row)
        // 仪表盘字段串(64 列, 循环滚动)
        4'd0: if (status_on) begin
            if (msg != 2'd0) case (ti)
                5'd0: tok = ks(S_TSD); 5'd1: tok = ks(s_msg); default: ; endcase
            else if (vid_mode) case (ti)
                5'd0: tok = ks(S_TVID); 5'd1: tok = ks(S_LRES); 5'd2: tok = ks(S_RES); 5'd3: tok = ks(S_SEP);
                5'd4: tok = ks(S_LFPS); 5'd5: tok = kn(F_FPS); 5'd6: tok = ks(S_SEP); 5'd7: tok = ks(fmt565 ? S_565 : S_332);
                5'd8: tok = ks(S_SEP); 5'd9: tok = ks(S_LTIME); 5'd10: tok = kb(F_VM); 5'd11: tok = ks(S_COLON);
                5'd12: tok = kb(F_VS); 5'd13: tok = ks(S_SEP); 5'd14: tok = ks(v_paused ? S_PAUSE : S_PLAY);
                default: ; endcase
            else case (ti)
                5'd0: tok = ks(wall_on ? S_TWALL : S_TPHO); 5'd1: tok = ks(S_LPIC); 5'd2: tok = kn(F_PIC);
                5'd3: tok = ks(S_OF8); 5'd4: tok = ks(S_SEP);
                5'd5: tok = ks(wall_on ? S_LGRP : S_LSRC); 5'd6: tok = wall_on ? ks(grp2 ? S_G2 : S_G1) : kn(F_W);
                5'd7: tok = wall_on ? ks(S_SEP) : ks(S_X); 5'd8: tok = wall_on ? ks(S_SEP) : kn(F_H);
                5'd9: tok = ks(S_SEP); 5'd10: tok = ks(S_LOUT); 5'd11: tok = ks(s_res); 5'd12: tok = ks(S_SEP);
                5'd13: tok = ks(S_LMUS); 5'd14: tok = (wav_state == 2'd1) ? ks(S_VWAV) : ks(s_wst);
                5'd15: tok = (wav_state == 2'd1) ? kn(F_SLOT) : kt(6'd0); default: ; endcase
        end
        // 菜单
        4'd3: if (menu_on && ti == 5'd0) tok = ks(S_TSET);
        4'd5, 4'd6, 4'd7, 4'd8, 4'd9, 4'd10, 4'd11: if (menu_on) case (ti)
            5'd0: tok = kt(6'd1);
            5'd1: tok = ks(mi == 3'd0 ? S_MMUS : mi == 3'd1 ? S_MVOL : mi == 3'd2 ? S_MTR :
                           mi == 3'd3 ? S_MPER : mi == 3'd4 ? S_MSPEC : mi == 3'd5 ? S_MINFO : S_MOUT);
            5'd2: tok = kt(6'd12);
            5'd3: tok = mfoc ? ks(S_LT) : kt(6'd12);
            5'd4: tok = kt(6'd14);
            5'd5: tok = (mi == 3'd0) ? ks(music_on ? S_ON : S_OFF) : (mi == 3'd1) ? kn(F_VOL) :
                        (mi == 3'd2) ? ks(s_trans) : (mi == 3'd3) ? ((period_s == 6'd0) ? ks(S_OFF) : kn(F_PER)) :
                        (mi == 3'd4) ? ks(s_spec) : (mi == 3'd5) ? ks(status_on ? S_ON : S_OFF) :
                        ks(spk_only ? S_SPK : S_HSPK);
            5'd6: tok = (mi == 3'd3 && period_s != 6'd0) ? ks(S_SEC) : kt(6'd14);
            5'd7: tok = mfoc ? kt(6'd23) : 8'd0;
            5'd8: tok = mfoc ? ks(S_GT) : 8'd0;
            default: ; endcase
        4'd13: if (menu_on) case (ti) 5'd0: tok = kt(6'd1); 5'd1: tok = ks(S_HINT1); default: ; endcase
        4'd14: if (menu_on) case (ti) 5'd0: tok = kt(6'd1); 5'd1: tok = ks(S_HINT2); default: ; endcase
        default: ;
        endcase
        if (player_on && !menu_on) case (row)
        // 播放器(菜单关闭时): 第 23 列起
        4'd4: case (ti)
            5'd0: tok = kt(6'd23); 5'd1: tok = ks(S_TMUS); 5'd2: tok = ks(S_LWAV); 5'd3: tok = kn(F_SLOT);
            5'd4: tok = ks(S_OF4); default: ; endcase
        4'd5: case (ti)
            5'd0: tok = kt(6'd23); 5'd1: tok = ks(s_wst); 5'd2: tok = kt(6'd29); 5'd3: tok = kb(F_WM);
            5'd4: tok = ks(S_COLON); 5'd5: tok = kb(F_WS); 5'd6: tok = ks(S_SL); 5'd7: tok = kb(F_LM);
            5'd8: tok = ks(S_COLON); 5'd9: tok = kb(F_LS); default: ; endcase
        default: ;
        endcase
    end

    // 行底: 仪表盘铺满 64 列(滚动无缝); 菜单行(含空行)铺满 26 列; 播放器 3 行(曲目/时间/进度条) 23..39 列
    wire       menu_row = menu_on && row >= 4'd3 && row <= 4'd14;
    wire       play_row = player_on && !menu_on && row >= 4'd4 && row <= 4'd6;
    wire [1:0] row_attr = (menu_on && row == 4'd3) ? 2'd2 : mfoc ? 2'd3 : 2'd0;

    // 数字字段: 二进制(去前导零输出)或 BCD 两位
    reg [13:0] fbin;
    reg [7:0]  fbcd;
    always @(*) begin
        fbin = 14'd0; fbcd = 8'd0;
        case (tok_q[3:0])
        F_FPS:   fbin = {8'd0, fps};
        F_VOL:   fbin = {9'd0, volume};
        F_PER:   fbin = {8'd0, period_s};
        F_PIC:   fbin = {10'd0, pic_idx};
        F_W:     fbin = (src_w > 16'd9999) ? 14'd9999 : src_w[13:0];
        F_H:     fbin = (src_h > 16'd9999) ? 14'd9999 : src_h[13:0];
        F_SLOT:  fbin = {12'd0, wav_slot} + 14'd1;
        F_LM:    fbcd = wlen[15:8];
        F_LS:    fbcd = wlen[7:0];
        F_VM:    fbcd = vt[15:8];
        F_VS:    fbcd = vt[7:0];
        F_WM:    fbcd = wt[15:8];
        default: fbcd = wt[7:0];
        endcase
    end

    // ======================= 排版器 =======================
    localparam [2:0] P_TOK = 0, P_STR = 1, P_CVT = 2, P_NUM = 3, P_FILL = 4, P_TAB = 5, P_DEC = 6;
    reg [2:0]  ps;
    reg [5:0]  col, tcol;
    reg [8:0]  sa;                           // 字串 ROM 读址
    reg [4:0]  sl;                           // 字串剩余长度
    reg [1:0]  sat;                          // 当前字串属性
    reg [15:0] bcd;                          // 待输出数字(BCD)
    reg [13:0] bsh;
    reg [3:0]  bcnt;
    reg [2:0]  ndig;                         // 剩余输出位数
    reg        lead;                         // 仍在前导零中
    reg        we;
    reg [9:0]  wa;
    reg [7:0]  wd;
    wire [15:0] loc = str_loc(tok_q[5:0]);
    wire [5:0]  sch = str_rom(sa);
    wire [3:0]  dtop = bcd[4*ndig - 4 +: 4];
    wire [1:0]  cat = (row_attr != 2'd0) ? row_attr : sat;
    wire [1:0]  nat = (row_attr != 2'd0) ? row_attr : 2'd0;
    wire        row_live = (row == 4'd0 && status_on) || menu_row || play_row;
    wire [5:0]  pad_lo = play_row ? 6'd23 : 6'd0;
    wire        pad_all = (row == 4'd0) && status_on;      // 跑马灯行 64 列全铺, 回绕无缝
    wire [5:0]  pad_hi = menu_row ? 6'd26 : play_row ? 6'd40 : 6'd63;
    function [15:0] dabble(input [15:0] b);
        reg [15:0] r; integer i;
        begin
            r = b;
            for (i = 0; i < 4; i = i + 1) if (r[4*i +: 4] >= 4'd5) r[4*i +: 4] = r[4*i +: 4] + 4'd3;
            dabble = r;
        end
    endfunction
    wire [15:0] bcd_d = dabble(bcd);

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            ps <= P_TOK; row <= 0; ti <= 0; col <= 0; tcol <= 0; sa <= 0; sl <= 0; sat <= 0; tok_q <= 0;
            bcd <= 0; bsh <= 0; bcnt <= 0; ndig <= 0; lead <= 0;
            we <= 1'b0; wa <= 0; wd <= 0;
        end else begin
            we <= 1'b0;
            case (ps)
            P_TOK: begin tok_q <= tok; ps <= P_DEC; end
            P_DEC: begin
                if (tok_q == 8'd0 || col == 6'd63) ps <= P_FILL;
                else case (tok_q[7:6])
                2'b00: begin sat <= loc[15:14]; sa <= loc[13:5]; sl <= loc[4:0]; ps <= P_STR; end
                2'b11: begin tcol <= tok_q[5:0]; ps <= P_TAB; end
                2'b10: begin bcd <= {8'd0, fbcd}; ndig <= 3'd2; lead <= 1'b0; ps <= P_NUM; end
                default: begin bcd <= 0; bsh <= fbin; bcnt <= 4'd14; ps <= P_CVT; end
                endcase
            end
            P_STR: begin
                if (sl == 5'd0 || col == 6'd63) begin ti <= ti + 5'd1; ps <= P_TOK; end
                else begin
                    we <= 1'b1; wa <= {row, col}; wd <= {cat, sch};
                    col <= col + 6'd1; sa <= sa + 9'd1; sl <= sl - 5'd1;
                end
            end
            P_TAB: begin
                if (col >= tcol) begin ti <= ti + 5'd1; ps <= P_TOK; end
                else begin we <= 1'b1; wa <= {row, col}; wd <= (col < pad_lo) ? 8'd0 : {nat, 6'd1}; col <= col + 6'd1; end
            end
            P_CVT: begin
                if (bcnt == 4'd0) begin ndig <= 3'd4; lead <= 1'b1; ps <= P_NUM; end
                else begin
                    bcd <= {bcd_d[14:0], bsh[13]};
                    bsh <= {bsh[12:0], 1'b0};
                    bcnt <= bcnt - 4'd1;
                end
            end
            P_NUM: begin
                if (ndig == 3'd0 || col == 6'd63) begin ti <= ti + 5'd1; ps <= P_TOK; end
                else begin
                    ndig <= ndig - 3'd1;
                    if (!(lead && dtop == 4'd0 && ndig != 3'd1)) begin
                        lead <= 1'b0;
                        we <= 1'b1; wa <= {row, col}; wd <= {nat, 2'b00, dtop} + 8'd2;
                        col <= col + 6'd1;
                    end
                end
            end
            default: begin   // P_FILL: 有内容的行补底到 pad_hi 列, 其余列透明, 然后下一行
                we <= 1'b1; wa <= {row, col};
                wd <= (row_live && col >= pad_lo && (col < pad_hi || pad_all)) ? {nat, 6'd1} : 8'd0;
                col <= col + 6'd1;
                if (col == 6'd63) begin row <= row + 4'd1; ti <= 0; ps <= P_TOK; end
            end
            endcase
        end

    // ======================= 字符 RAM(双时钟) =======================
    reg [7:0] cram [0:1023];
    reg [7:0] cq;
    always @(posedge clk) if (we) cram[wa] <= wd;

    // ======================= 像素域渲染 =======================
    // 跑马灯: 第 0 行横坐标加滚动偏移, 按 64 列(1024 像素)回绕, 每帧左移 1 像素
    reg [9:0] scroll;
    always @(posedge pclk or posedge prst)
        if (prst) scroll <= 10'd0; else if (frame_boundary) scroll <= scroll + 10'd1;
    wire        r0  = (y[9:4] == 6'd0);
    wire [9:0]  xn  = x + 10'd1;                        // 读地址提前一拍
    wire [9:0]  xs  = r0 ? xn + scroll : xn;           // 回绕在 10 位内自然完成(64 列 × 16)
    wire [9:0]  xd  = r0 ? x + scroll : x;              // 当前像素在字格内的位置
    always @(posedge pclk) cq <= cram[{y[7:4], xs[9:4]}];
    wire [3:0] lx = xd[3:0] - 4'd3;          // 字模区 x: 3..12
    wire [3:0] ly = y[3:0] - 4'd1;           // 字模区 y: 1..14
    wire       in_g = (xd[3:0] >= 4'd3) && (xd[3:0] <= 4'd12) && (y[3:0] >= 4'd1) && (y[3:0] <= 4'd14);
    wire [4:0] frow = font_row(cq[5:0], ly[3:1]);
    wire       ink = in_g && frow[3'd4 - lx[3:1]];
    wire       on_cell = de && (y < 10'd256) && (cq[5:0] != 6'd0);
    wire [1:0] at = cq[7:6];
    // 进度跨到像素域: 准静态, 两级同步后连续两拍一致才采用
    (* async_reg="true" *) reg [7:0] bn_m, bn_s;
    reg [7:0] bn_p, bar_n_p;
    always @(posedge pclk or posedge prst)
        if (prst) begin bn_m <= 0; bn_s <= 0; bn_p <= 0; bar_n_p <= 0; end
        else begin bn_m <= bar_n; bn_s <= bn_m; bn_p <= bn_s; if (bn_s == bn_p) bar_n_p <= bn_s; end
    // 播放器进度条: 第 6 行 x 368..623 一条 6 像素高的条, 已播部分白、未播部分灰
    wire       bar_row = player_on && !menu_on && (y[9:4] == 6'd6) && (y[3:0] >= 4'd5) && (y[3:0] <= 4'd10) &&
                         (x >= 10'd368) && (x < 10'd624);
    wire       bar_done = (x - 10'd368) < {1'b0, bar_n_p, 1'b0};
    // 半透明底: 各通道 ×(1 - 1/16 - 1/32) ≈ 0.91; 标签块/焦点行再加蓝调(饱和)
    wire [4:0] ir = rgb_in[15:11], ib = rgb_in[4:0];
    wire [5:0] ig = rgb_in[10:5];
    wire [4:0] dr = ir - (ir >> 4) - (ir >> 5);
    wire [5:0] dg = ig - (ig >> 4) - (ig >> 5);
    wire [4:0] db = ib - (ib >> 4) - (ib >> 5);
    wire       tint = at[1];
    wire [6:0] tg = {1'b0, dg} + (tint ? 7'd4 : 7'd0);
    wire [5:0] tb = {1'b0, db} + (tint ? 6'd8 : 6'd0);
    wire [15:0] bg = {dr, tg[6] ? 6'h3F : tg[5:0], tb[5] ? 5'h1F : tb[4:0]};
    wire [15:0] fg = (at == 2'd0) ? 16'hFFFF : (at == 2'd1) ? 16'h9EFF : 16'hFFE0;
    assign rgb_out = (de && bar_row) ? (bar_done ? 16'hFFFF : 16'h4208) :
                     !on_cell ? rgb_in : ink ? fg : bg;

endmodule
