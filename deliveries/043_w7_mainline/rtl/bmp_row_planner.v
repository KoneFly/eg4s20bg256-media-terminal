`timescale 1ns/1ps
// ============================================================================
// bmp_row_planner — task_046 新增(B2 冻结 接口 2): 所需源行规划器
//
// 输入 = BMP 头字段(规划期一次性锁存) + 目标帧几何常量(640x480, CROP=6,
// KEEP_ASPECT=1 —— 与 bmp_resampler 常量同值); 输出 =
//   (a) plan_supported(发起像素加载前判定; 0 ⇒ 回退旧路径);
//   (b) 内容几何(content_w/h, lft, top/bot_black, x_off, src_win, row_bytes);
//   (c) 每内容行一条文件区间(单调递增):
//       offset = bfOffBits + sy(c)*row_bytes + x_off*3, length = src_win*3,
//       sy(c) = ceil((c+1)*src_h/content_h)-1 —— FSM 折返实现(与 resampler
//       vacc DDA 同义; 闭式等价穷举证明 sim/py046/prove_sampling_equiv.py
//       G2/G3/G4; 逐区间黄金向量对拍 tb_b3_planner)。
// 除法: 22 拍恢复余数除法器(与 resampler 几何除法同构, G1b 证明)。
// 结构: FSM 化(无 while/非法位选), P_ROWINIT 装增量 → P_ROWADV 逐拍折返。
// ============================================================================
module bmp_row_planner (
    input  wire        clk,
    input  wire        rst_n,

    // 启动与 BMP 头字段(装载期稳定)
    input  wire        start,          // 单拍: 开始规划
    input  wire [15:0] src_w,          // 绝对宽 [1,4096]
    input  wire [15:0] src_h,          // 绝对高 [1,4096]
    input  wire [31:0] bfOffBits,      // 像素起点(不假设 54)
    input  wire [31:0] file_size,      // 目录登记大小
    input  wire        fmt_hdrok,      // 头格式合法(BM/40/1/24/BI_RGB)

    // 判定与几何(plan_valid 单拍; plan_supported/几何量保持到下次 start)
    output reg         plan_valid,
    output reg         plan_supported, // 0 ⇒ 回退旧路径
    output reg  [15:0] content_w,
    output reg  [15:0] content_h,
    output reg  [15:0] x_off,
    output reg  [15:0] src_win,
    output reg  [10:0] lft,
    output reg  [9:0]  top_black,
    output reg  [9:0]  bot_black,
    output reg  [31:0] row_bytes,

    // 区间流: 每内容行一条(严格单调递增)
    output reg         ival_valid,
    input  wire        ival_ready,
    output reg  [31:0] ival_offset,
    output reg  [31:0] ival_length,
    output reg  [9:0]  ival_row,
    output reg         ival_last,
    output reg         plan_done       // 末区间受理后单拍
);
    localparam [15:0] DSTW = 16'd640;
    localparam [15:0] DSTH = 16'd480;

    localparam [3:0]
        P_IDLE    = 4'd0,
        P_DIV     = 4'd1,
        P_LATCH   = 4'd2,
        P_ROWINIT = 4'd3,   // vacc += sh - first?1:0 (单拍)
        P_ROWADV  = 4'd4,   // 逐拍折返(每拍最多一进位, ≤11 拍)
        P_EMIT    = 4'd5,   // 等本行区间受理
        P_FIN     = 4'd6;

    reg [3:0]  state;

    // ---- 输入/几何锁存 ----
    reg [15:0] sw_r, sh_r;
    reg [31:0] bfo_r, fsz_r;
    reg        fmt_r, case_a, crop;

    // 组合几何判定(用 sw_r/sh_r 锁存值; start 后任何拍求值同值)
    wire [17:0] four_h3  = {sh_r, 2'b00};
    wire [17:0] three_w3 = {1'b0, sw_r, 1'b0} + {2'b00, sw_r};
    wire        wide_axis = (four_h3 <= three_w3);
    wire [31:0] prod_wh   = ({16'd0, sh_r} << 9) + ({16'd0, sh_r} << 7);   // 640*sh
    wire [31:0] prod_hw   = ({16'd0, sw_r} << 9) - ({16'd0, sw_r} << 5);   // 480*sw
    wire [31:0] rb_w      = ((({16'd0, sw_r} * 32'd3) + 32'd3) >> 2) << 2;
    // EOF 截断防护: bfOffBits + row_bytes*sh <= file_size(扩展位宽, 防回绕)
    wire [48:0] need49    = {17'd0, bfo_r} + ({17'd0, rb_w} * {32'd0, sh_r});
    // 输入锁存后除法至少22拍; EOF乘积/加法提前两拍完成, 判定拍不变。
    reg [48:0] eof_product_r;
    reg [48:0] eof_need_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            eof_product_r <= 49'd0;
            eof_need_r <= 49'd0;
        end else begin
            eof_product_r <= {17'd0, rb_w} * {32'd0, sh_r};
            eof_need_r <= {17'd0, bfo_r} + eof_product_r;
        end
    end
    wire        sup_judge = fmt_r && (sw_r >= 16'd640) && (sh_r >= 16'd480) &&
                            !(crop && (sw_r < 16'd679)) &&
                            (eof_need_r[48:32] == 17'd0) && (eof_need_r[31:0] <= fsz_r);

    // 几何判定(输入侧, start 当拍锁存用)
    wire        wide_in = ({src_h, 2'b00} <= ({1'b0, src_w, 1'b0} + {2'b00, src_w}));
    wire        crop_in = ({src_h, 2'b00} <  ({1'b0, src_w, 1'b0} + {2'b00, src_w}));
    wire [31:0] pwh_in  = ({16'd0, src_h} << 9) + ({16'd0, src_h} << 7);
    wire [31:0] phw_in  = ({16'd0, src_w} << 9) - ({16'd0, src_w} << 5);
    wire [31:0] sw100_in = ({16'd0, src_w} << 6) + ({16'd0, src_w} << 5) + ({16'd0, src_w} << 2);

    // ---- 除法器(22 拍恢复余数) ----
    reg [15:0] div_rem;
    reg [21:0] div_num, div_sr;
    reg [15:0] div_d;
    reg [4:0]  div_cnt;
    reg        div_phase;          // 0=src_win 相, 1=内容轴相
    wire [16:0] div_trial = {div_rem, div_num[21]};
    wire        div_ge    = (div_trial >= {1'b0, div_d});
    wire [16:0] div_sub   = div_trial - {1'b0, div_d};
    wire [21:0] div_q     = {div_sr[20:0], div_ge};   // div_cnt==21 当拍有效商

    // ---- P_LATCH 几何中间量(线网层, 免表达式位选) ----
    wire [15:0] q_hl   = case_a ? ((div_q > {6'd0, DSTH}) ? DSTH : div_q[15:0])
                                : ((div_q > {6'd0, DSTW}) ? DSTW : div_q[15:0]);
    wire [15:0] cw_l   = case_a ? DSTW : q_hl;
    wire [15:0] ch_l   = case_a ? q_hl : DSTH;
    wire [15:0] lft_m  = (DSTW - cw_l) >> 1;
    wire [15:0] top_m  = (DSTH - ch_l) >> 1;
    wire [15:0] bot_m  = DSTH - ch_l - top_m;
    wire [10:0] lft_w  = lft_m[10:0];
    wire [9:0]  top_w  = top_m[9:0];
    wire [9:0]  bot_w  = bot_m[9:0];

    // ---- 行折返 ----
    reg [16:0] vacc;               // 17b: vacc+sh ≤ 8191
    reg [15:0] sy_r;
    reg [9:0]  c_r;
    reg        first_row;
    reg [15:0] ch_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= P_IDLE;
            sw_r <= 16'd0; sh_r <= 16'd0; bfo_r <= 32'd0; fsz_r <= 32'd0;
            fmt_r <= 1'b0; case_a <= 1'b0; crop <= 1'b0;
            plan_valid <= 1'b0; plan_supported <= 1'b0;
            content_w <= 16'd0; content_h <= 16'd0; x_off <= 16'd0;
            src_win <= 16'd0; lft <= 11'd0; top_black <= 10'd0; bot_black <= 10'd0;
            row_bytes <= 32'd0;
            div_rem <= 16'd0; div_num <= 22'd0; div_sr <= 22'd0;
            div_d <= 16'd0; div_cnt <= 5'd0; div_phase <= 1'b0;
            vacc <= 17'd0; sy_r <= 16'd0; c_r <= 10'd0; first_row <= 1'b0;
            ch_r <= 16'd0;
            ival_valid <= 1'b0; ival_offset <= 32'd0; ival_length <= 32'd0;
            ival_row <= 10'd0; ival_last <= 1'b0; plan_done <= 1'b0;
        end else begin
            plan_valid <= 1'b0;
            plan_done  <= 1'b0;

            case (state)
                // --------------------------------------------------------
                P_IDLE: begin
                    if (start) begin
                        sw_r   <= src_w;
                        sh_r   <= src_h;
                        bfo_r  <= bfOffBits;
                        fsz_r  <= file_size;
                        fmt_r  <= fmt_hdrok;
                        row_bytes <= ((({16'd0, src_w} * 32'd3) + 32'd3) >> 2) << 2;
                        case_a <= wide_in;
                        crop   <= crop_in;
                        // 除法相装配: crop ⇒ phase0(sw*100/106); 否则直达 phase1
                        if (crop_in) begin
                            div_phase <= 1'b0;
                            div_d     <= 16'd106;
                            div_num   <= sw100_in[21:0];
                        end else begin
                            div_phase <= 1'b1;
                            src_win   <= src_w;
                            x_off     <= 16'd0;
                            div_d     <= wide_in ? src_w : src_h;
                            div_num   <= wide_in ? pwh_in[21:0] : phw_in[21:0];
                        end
                        div_sr <= 22'd0; div_rem <= 16'd0; div_cnt <= 5'd0;
                        ival_valid <= 1'b0;
                        vacc <= 17'd0; sy_r <= 16'd0; c_r <= 10'd0;
                        first_row <= 1'b1;
                        state <= P_DIV;
                    end
                end
                // --------------------------------------------------------
                P_DIV: begin
                    if (div_cnt == 5'd21) begin
                        // 商已齐(div_q 有效): 冻结移位, P_LATCH 拍读取值不变
                        if (div_phase == 1'b0) begin
                            // phase0 商 = src_win(钳到 sw); 随即装 phase1
                            src_win   <= (div_q > {6'd0, sw_r}) ? sw_r : div_q[15:0];
                            x_off     <= (div_q > {6'd0, sw_r}) ? 16'd0 :
                                         ((sw_r - div_q[15:0]) >> 1);
                            div_phase <= 1'b1;
                            div_d     <= (div_q > {6'd0, sw_r}) ? sw_r : div_q[15:0];
                            div_num   <= prod_wh[21:0];
                            div_sr    <= 22'd0; div_rem <= 16'd0; div_cnt <= 5'd0;
                        end else begin
                            state <= P_LATCH;
                        end
                    end else begin
                        div_num <= {div_num[20:0], 1'b0};
                        div_sr  <= {div_sr[20:0], div_ge};
                        div_rem <= div_ge ? div_sub[15:0] : div_trial[15:0];
                        div_cnt <= div_cnt + 5'd1;
                    end
                end
                // --------------------------------------------------------
                P_LATCH: begin
                    content_w      <= cw_l;
                    content_h      <= ch_l;
                    ch_r           <= ch_l;
                    lft            <= lft_w;
                    top_black      <= top_w;
                    bot_black      <= bot_w;
                    // 节省谓词: 仅当行选确有跳行(ch < sh)才启用选择路径;
                    // 等字节几何(如 640x480)回退旧路径(选择路径含扫描/节流
                    // 开销, 无节省时严格更慢)
                    plan_supported <= sup_judge && (ch_l < sh_r);
                    plan_valid     <= 1'b1;
                    if (sup_judge && (ch_l < sh_r)) state <= P_ROWINIT;
                    else                            state <= P_FIN;
                end
                // --------------------------------------------------------
                P_ROWINIT: begin
                    // 单拍装增量: vacc += sh - (first ? 1 : 0)
                    vacc <= vacc + {1'b0, sh_r} - (first_row ? 17'd1 : 17'd0);
                    state <= P_ROWADV;
                end
                P_ROWADV: begin
                    // 逐拍折返: vacc >= ch 则 {vacc-=ch, sy+1}; (sh/ch<11 ⇒ ≤11 拍)
                    if (vacc >= {1'b0, ch_r}) begin
                        vacc <= vacc - {1'b0, ch_r};
                        sy_r <= sy_r + 16'd1;
                    end else begin
                        state <= P_EMIT;
                    end
                end
                P_EMIT: begin
                    first_row <= 1'b0;
                    if (!ival_valid) begin
                        ival_offset <= bfo_r + ({16'd0, sy_r} * row_bytes) +
                                       ({16'd0, x_off} * 32'd3);
                        ival_length <= {16'd0, src_win} * 32'd3;
                        ival_row    <= c_r;
                        ival_last   <= (c_r == (ch_r[9:0] - 10'd1));
                        ival_valid  <= 1'b1;
                    end else if (ival_ready) begin
                        ival_valid <= 1'b0;
                        if (c_r == (ch_r[9:0] - 10'd1)) begin
                            plan_done <= 1'b1;
                            state     <= P_FIN;
                        end else begin
                            c_r   <= c_r + 10'd1;
                            state <= P_ROWINIT;
                        end
                    end
                end
                P_FIN: state <= P_IDLE;
                default: state <= P_IDLE;
            endcase
        end
    end

endmodule
