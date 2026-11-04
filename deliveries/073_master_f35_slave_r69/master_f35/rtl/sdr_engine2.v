`timescale 1ns / 1ps
// sdr_engine2：50MHz四bank开页流水SDRAM引擎。列、bank、行分别取逻辑地址[7:0]、[9:8]、[20:10]；刷新计数不依赖媒体流是否停顿。
module sdr_engine2 #(
    parameter integer T_INIT    = 10000, // 200us @50MHz
    parameter integer T_RCD     = 3,
    parameter integer T_RP      = 3,
    parameter integer T_RAS     = 3,
    parameter integer T_MRD     = 2,
    parameter integer T_RFC     = 8,
    parameter integer CAS_LAT   = 3,
    parameter integer DQ_LAT    = 1,
    parameter integer T_COL2PRE = 10,    // 列命令 -> 同 bank PRE: 写=末拍+tWR+1, 读=突发全部离开
    parameter integer T_R2W     = 11,    // 读列 -> 写列: 读数据离开 DQ 后再驱动
    parameter integer T_W2R     = 9,     // 写列 -> 读列
    parameter integer REF_SOFT  = 384,
    parameter integer REF_HARD  = 700,
    parameter integer TAGW      = 3
)(
    input  wire            clk,
    input  wire            rst_n,
    output reg             init_done,

    input  wire            req_valid,
    output wire            req_ready,
    input  wire            req_write,
    input  wire [20:0]     req_addr,
    input  wire [8:0]      req_len,       // 1..256
    input  wire [TAGW-1:0] req_tag,

    output wire            wr_pop,
    output wire [TAGW-1:0] wr_pop_tag,
    output wire            wr_pop_last,   // 本事务最后一个写字
    input  wire [31:0]     wr_data,
    input  wire [3:0]      wr_be,

    output reg             rd_valid,
    output reg  [31:0]     rd_data,
    output reg  [TAGW-1:0] rd_tag,
    output reg             rd_last,

    output reg             ref_overrun,   // 刷新间隔超过 REF_LIMIT(粘滞诊断)

    output reg             sdr_cke,
    output reg             sdr_cs_n,
    output reg             sdr_ras_n,
    output reg             sdr_cas_n,
    output reg             sdr_we_n,
    output reg  [10:0]     sdr_addr,
    output reg  [1:0]      sdr_ba,
    output reg  [3:0]      sdr_dm,
    output reg  [31:0]     sdr_dq_out,
    output reg             sdr_dq_oe,
    input  wire [31:0]     sdr_dq_in
);
    localparam integer RD_LAT    = CAS_LAT + DQ_LAT;
    localparam integer REF_LIMIT = 780;
    // FIXME: A[2:0]=100 按上板验证值选定(JEDEC 表中 BL8 为 011), 连续突发仍需复核
    localparam [10:0]  MRS_VAL   = 11'h034;
    localparam [10:0]  PRE_ALL   = 11'h400;
    localparam [2:0]   C_NOP = 3'b111, C_ACT = 3'b011, C_RD = 3'b101, C_WR = 3'b100,
                       C_PRE = 3'b010, C_REF = 3'b001, C_MRS = 3'b000;

    // ------------------------------------------------------------------
    // 事务队列(1 项) + 拆分器
    // ------------------------------------------------------------------
    reg            q_v, q_wr;
    reg [20:0]     q_addr;
    reg [8:0]      q_len;
    reg [TAGW-1:0] q_tag;

    reg            s_busy, s_wr, s_first;
    reg [17:0]     s_bl, s_last_bl;
    reg [2:0]      s_lo, s_hi;
    reg [TAGW-1:0] s_tag;

    // 槽 FIFO(4 项, 并行可见供前瞻)
    localparam integer SW = 1 + 2 + 11 + 5 + 8 + TAGW + 1;
    reg  [SW-1:0]  sf [0:3];
    reg  [2:0]     sf_cnt;
    wire           head_pop;

    wire           s_push   = s_busy && (sf_cnt != 3'd4 || head_pop);
    wire           s_lastsl = (s_bl == s_last_bl);
    wire [7:0]     s_mlo    = s_first  ? (8'hFF << s_lo)        : 8'hFF;
    wire [7:0]     s_mhi    = s_lastsl ? (8'hFF >> (3'd7 - s_hi)) : 8'hFF;
    wire [SW-1:0]  s_slot   = {s_wr, s_bl[6:5], s_bl[17:7], s_bl[4:0], s_mlo & s_mhi, s_tag, s_lastsl};
    wire           s_load   = q_v && (!s_busy || (s_push && s_lastsl));

    assign req_ready = !q_v && init_done;

    wire [20:0] q_end = q_addr + q_len - 21'd1;

    // 槽字段
    function        f_wr  (input [SW-1:0] x); f_wr   = x[SW-1];                 endfunction
    function [1:0]  f_ba  (input [SW-1:0] x); f_ba   = x[SW-2 -: 2];            endfunction
    function [10:0] f_row (input [SW-1:0] x); f_row  = x[SW-4 -: 11];           endfunction
    function [4:0]  f_col (input [SW-1:0] x); f_col  = x[SW-15 -: 5];          endfunction
    function [7:0]  f_mask(input [SW-1:0] x); f_mask = x[TAGW+8 -: 8];          endfunction
    function [TAGW-1:0] f_tag(input [SW-1:0] x); f_tag = x[TAGW:1];             endfunction
    function        f_last(input [SW-1:0] x); f_last = x[0];                    endfunction

    // ------------------------------------------------------------------
    // bank 状态与时序计数(饱和)
    // ------------------------------------------------------------------
    reg        b_open [0:3];
    reg [10:0] b_row  [0:3];
    reg [4:0]  b_sa   [0:3];   // since ACT
    reg [4:0]  b_sp   [0:3];   // since PRE
    reg [4:0]  b_sc   [0:3];   // since 本 bank 列命令
    reg [4:0]  g_sc;           // since 任意列命令
    reg        g_lastwr;
    reg [4:0]  g_sref;         // since REF(tRFC)
    reg [9:0]  ref_age;        // since REF(刷新期限)

    // ------------------------------------------------------------------
    // 决策
    // ------------------------------------------------------------------
    localparam [1:0] M_PWR = 2'd0, M_INIT = 2'd1, M_RUN = 2'd2;
    reg  [1:0]  mode;
    reg  [13:0] icnt;
    reg         ref_hold;

    wire        idle_all = (sf_cnt == 3'd0) && !s_busy && !q_v;
    wire        ref_want = (ref_age >= REF_HARD) || ((ref_age >= REF_SOFT) && idle_all);

    wire [SW-1:0] h  = sf[0];
    wire [1:0]    hb = f_ba(h);
    // 计数器在命令决策后下一拍为 0, 因此"间隔 >= T"等价于"计数 >= T-1"
    wire          dir_ok = (f_wr(h) == g_lastwr) ? (g_sc >= 5'd7)
                         : (f_wr(h) ? (g_sc >= T_R2W - 1) : (g_sc >= T_W2R - 1));
    wire          col_go = (mode == M_RUN) && !ref_hold && (sf_cnt != 3'd0) &&
                           b_open[hb] && (b_row[hb] == f_row(h)) && (b_sa[hb] >= T_RCD - 1) && dir_ok;
    assign        head_pop = col_go;

    // 前瞻 PRE/ACT
    reg        pa_go, pa_act;
    reg [1:0]  pa_ba;
    reg [10:0] pa_row;
    integer    j, i;
    reg        blk, need, can;
    reg [1:0]  bj;
    always @(*) begin
        pa_go = 1'b0; pa_act = 1'b0; pa_ba = 2'd0; pa_row = 11'd0;
        for (j = 3; j >= 0; j = j - 1) begin
            bj   = f_ba(sf[j]);
            need = (j < sf_cnt) && !(b_open[bj] && b_row[bj] == f_row(sf[j]));
            blk  = 1'b0;
            for (i = 0; i < 3; i = i + 1)
                if (i < j && i < sf_cnt && f_ba(sf[i]) == bj) blk = 1'b1;
            can  = b_open[bj] ? ((b_sa[bj] >= T_RAS - 1) && (b_sc[bj] >= T_COL2PRE - 1))
                              : ((b_sp[bj] >= T_RP - 1) && (g_sref >= T_RFC - 1));
            if (need && !blk && can) begin
                pa_go = 1'b1; pa_act = !b_open[bj]; pa_ba = bj; pa_row = f_row(sf[j]);
            end
        end
        if (mode != M_RUN || ref_hold || col_go) pa_go = 1'b0;
    end

    // 刷新序列条件
    reg any_open, all_preok, all_rpok;
    integer k;
    always @(*) begin
        any_open = 1'b0; all_preok = 1'b1; all_rpok = 1'b1;
        for (k = 0; k < 4; k = k + 1) begin
            if (b_open[k]) begin
                any_open = 1'b1;
                if (!((b_sa[k] >= T_RAS - 1) && (b_sc[k] >= T_COL2PRE - 1))) all_preok = 1'b0;
            end
            if (b_sp[k] < T_RP - 1) all_rpok = 1'b0;
        end
    end
    wire ref_pre = (mode == M_RUN) && ref_hold && any_open && all_preok;
    wire ref_go  = (mode == M_RUN) && ref_hold && !any_open && all_rpok && (g_sref >= T_RFC - 1);

    // ------------------------------------------------------------------
    // 写拍 / 读拍 发生器
    // ------------------------------------------------------------------
    wire        col_wr = col_go && f_wr(h);
    wire        col_rd = col_go && !f_wr(h);
    reg  [6:0]  wb_mask;
    reg  [2:0]  wb_cnt;
    reg         wb_last;
    reg  [TAGW-1:0] wb_tag;
    wire [7:0]  hm = f_mask(h);

    assign wr_pop      = col_wr ? hm[0] : wb_mask[0] && (wb_cnt != 3'd0);
    assign wr_pop_tag  = col_wr ? f_tag(h) : wb_tag;
    assign wr_pop_last = col_wr ? (f_last(h) && hm[0] && (hm[7:1] == 7'd0))
                                : (wb_last && wb_mask[0] && (wb_mask[6:1] == 6'd0) && (wb_cnt != 3'd0));
    wire        wbeat_now  = col_wr || (wb_cnt != 3'd0);

    reg  [7:0]  rb_mask;
    reg  [3:0]  rb_cnt;
    reg         rb_last;
    reg  [TAGW-1:0] rb_tag;
    wire        e_v    = (rb_cnt != 4'd0) && rb_mask[0];
    wire        e_last = e_v && rb_last && (rb_mask[7:1] == 7'd0);
    reg  [RD_LAT-1:0]   dl_v, dl_l;
    reg  [TAGW-1:0]     dl_t [0:RD_LAT-1];

    // ------------------------------------------------------------------
    // 时序逻辑
    // ------------------------------------------------------------------
    reg [2:0]  c1_cmd;
    reg        c1_cs;
    reg [1:0]  c1_ba;
    reg [10:0] c1_addr;
    reg        c1_cke;
    reg        d_beat, d_valid;

    integer n;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode <= M_PWR; icnt <= 14'd0; init_done <= 1'b0;
            q_v <= 1'b0; q_wr <= 1'b0; q_addr <= 21'd0; q_len <= 9'd1; q_tag <= {TAGW{1'b0}};
            s_busy <= 1'b0; s_wr <= 1'b0; s_first <= 1'b0; s_bl <= 18'd0; s_last_bl <= 18'd0;
            s_lo <= 3'd0; s_hi <= 3'd0; s_tag <= {TAGW{1'b0}};
            sf_cnt <= 3'd0;
            for (n = 0; n < 4; n = n + 1) begin
                sf[n] <= {SW{1'b0}};
                b_open[n] <= 1'b0; b_row[n] <= 11'd0;
                b_sa[n] <= 5'd31; b_sp[n] <= 5'd31; b_sc[n] <= 5'd31;
            end
            g_sc <= 5'd31; g_lastwr <= 1'b0; g_sref <= 5'd31; ref_age <= 10'd0;
            ref_hold <= 1'b0; ref_overrun <= 1'b0;
            wb_mask <= 7'd0; wb_cnt <= 3'd0; wb_last <= 1'b0; wb_tag <= {TAGW{1'b0}};
            rb_mask <= 8'd0; rb_cnt <= 4'd0; rb_last <= 1'b0; rb_tag <= {TAGW{1'b0}};
            dl_v <= {RD_LAT{1'b0}}; dl_l <= {RD_LAT{1'b0}};
            for (n = 0; n < RD_LAT; n = n + 1) dl_t[n] <= {TAGW{1'b0}};
            rd_valid <= 1'b0; rd_data <= 32'd0; rd_tag <= {TAGW{1'b0}}; rd_last <= 1'b0;
            c1_cmd <= C_NOP; c1_cs <= 1'b1; c1_ba <= 2'd0; c1_addr <= 11'd0; c1_cke <= 1'b0;
            d_beat <= 1'b0; d_valid <= 1'b0;
            sdr_cke <= 1'b0; sdr_cs_n <= 1'b1; sdr_ras_n <= 1'b1; sdr_cas_n <= 1'b1; sdr_we_n <= 1'b1;
            sdr_addr <= 11'd0; sdr_ba <= 2'd0; sdr_dm <= 4'b0000; sdr_dq_out <= 32'd0; sdr_dq_oe <= 1'b0;
        end else begin
            // ---------------- 事务队列 ----------------
            if (req_valid && req_ready) begin
                q_v <= 1'b1; q_wr <= req_write; q_addr <= req_addr; q_len <= req_len; q_tag <= req_tag;
            end else if (s_load) begin
                q_v <= 1'b0;
            end

            // ---------------- 拆分器 ----------------
            if (s_load) begin
                s_busy <= 1'b1; s_wr <= q_wr; s_tag <= q_tag; s_first <= 1'b1;
                s_bl <= q_addr[20:3]; s_last_bl <= q_end[20:3];
                s_lo <= q_addr[2:0];  s_hi <= q_end[2:0];
            end else if (s_push) begin
                s_first <= 1'b0;
                s_bl    <= s_bl + 18'd1;
                if (s_lastsl) s_busy <= 1'b0;
            end

            // ---------------- 槽 FIFO ----------------
            if (head_pop) begin
                for (n = 0; n < 3; n = n + 1) sf[n] <= sf[n+1];
                if (s_push) sf[sf_cnt - 3'd1] <= s_slot;
                sf_cnt <= sf_cnt + {2'd0, s_push} - 3'd1;
            end else if (s_push) begin
                sf[sf_cnt] <= s_slot;
                sf_cnt <= sf_cnt + 3'd1;
            end

            // ---------------- 计数器 ----------------
            for (n = 0; n < 4; n = n + 1) begin
                if (b_sa[n] != 5'd31) b_sa[n] <= b_sa[n] + 5'd1;
                if (b_sp[n] != 5'd31) b_sp[n] <= b_sp[n] + 5'd1;
                if (b_sc[n] != 5'd31) b_sc[n] <= b_sc[n] + 5'd1;
            end
            if (g_sc   != 5'd31) g_sc   <= g_sc + 5'd1;
            if (g_sref != 5'd31) g_sref <= g_sref + 5'd1;
            if (init_done && ref_age != 10'h3FF) ref_age <= ref_age + 10'd1;
            if (ref_age > REF_LIMIT) ref_overrun <= 1'b1;

            // ---------------- 命令决策 -> c1 ----------------
            c1_cmd <= C_NOP; c1_cs <= 1'b0;
            case (mode)
            M_PWR: begin
                c1_cs <= 1'b1;
                icnt  <= icnt + 14'd1;
                if (icnt == T_INIT - 1) begin c1_cke <= 1'b1; mode <= M_INIT; icnt <= 14'd0; end
            end
            M_INIT: begin
                icnt <= icnt + 14'd1;
                if (icnt == 2)                          begin c1_cmd <= C_PRE; c1_addr <= PRE_ALL; end
                else if (icnt == 2 + T_RP)              c1_cmd <= C_REF;
                else if (icnt == 2 + T_RP + T_RFC)      c1_cmd <= C_REF;
                else if (icnt == 2 + T_RP + 2*T_RFC)    begin c1_cmd <= C_MRS; c1_addr <= MRS_VAL; c1_ba <= 2'd0; end
                else if (icnt == 2 + T_RP + 2*T_RFC + T_MRD + 2) begin
                    mode <= M_RUN; init_done <= 1'b1; g_sref <= 5'd31;
                end
            end
            default: begin
                if (!ref_hold && ref_want) ref_hold <= 1'b1;
                if (col_go) begin
                    c1_cmd  <= f_wr(h) ? C_WR : C_RD;
                    c1_ba   <= hb;
                    c1_addr <= {3'b000, f_col(h), 3'b000};
                    b_sc[hb] <= 5'd0;
                    g_sc     <= 5'd0;
                    g_lastwr <= f_wr(h);
                end else if (ref_pre) begin
                    c1_cmd <= C_PRE; c1_addr <= PRE_ALL;
                    for (n = 0; n < 4; n = n + 1) begin b_open[n] <= 1'b0; b_sp[n] <= 5'd0; end
                end else if (ref_go) begin
                    c1_cmd   <= C_REF;
                    g_sref   <= 5'd0;
                    ref_age  <= 10'd0;
                    ref_hold <= 1'b0;
                end else if (pa_go) begin
                    c1_ba <= pa_ba;
                    if (pa_act) begin
                        c1_cmd  <= C_ACT; c1_addr <= pa_row;
                        b_open[pa_ba] <= 1'b1; b_row[pa_ba] <= pa_row; b_sa[pa_ba] <= 5'd0;
                    end else begin
                        c1_cmd  <= C_PRE; c1_addr <= 11'd0;
                        b_open[pa_ba] <= 1'b0; b_sp[pa_ba] <= 5'd0;
                    end
                end
            end
            endcase

            // ---------------- 写拍 ----------------
            if (col_wr) begin
                wb_mask <= hm[7:1]; wb_cnt <= 3'd7; wb_last <= f_last(h); wb_tag <= f_tag(h);
            end else if (wb_cnt != 3'd0) begin
                wb_mask <= {1'b0, wb_mask[6:1]}; wb_cnt <= wb_cnt - 3'd1;
            end
            d_beat  <= wbeat_now;
            d_valid <= wr_pop;

            // ---------------- 读拍 ----------------
            if (col_rd) begin
                rb_mask <= hm; rb_cnt <= 4'd8; rb_last <= f_last(h); rb_tag <= f_tag(h);
            end else if (rb_cnt != 4'd0) begin
                rb_mask <= {1'b0, rb_mask[7:1]}; rb_cnt <= rb_cnt - 4'd1;
            end
            dl_v <= {dl_v[RD_LAT-2:0], e_v};
            dl_l <= {dl_l[RD_LAT-2:0], e_last};
            dl_t[0] <= rb_tag;
            for (n = 1; n < RD_LAT; n = n + 1) dl_t[n] <= dl_t[n-1];
            rd_valid <= dl_v[RD_LAT-1];
            rd_last  <= dl_l[RD_LAT-1];
            rd_tag   <= dl_t[RD_LAT-1];
            rd_data  <= sdr_dq_in;

            // ---------------- 输出寄存 ----------------
            sdr_cke  <= c1_cke;
            sdr_cs_n <= c1_cs;
            {sdr_ras_n, sdr_cas_n, sdr_we_n} <= c1_cmd;
            sdr_ba   <= c1_ba;
            sdr_addr <= c1_addr;
            sdr_dq_oe  <= d_beat;
            sdr_dq_out <= d_valid ? wr_data : 32'd0;
            sdr_dm     <= d_valid ? ~wr_be : (d_beat ? 4'b1111 : 4'b0000);
        end
    end
endmodule
