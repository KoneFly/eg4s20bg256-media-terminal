`timescale 1ns / 1ps
// ============================================================================
// bmp_resampler — 任意分辨率 RGB565 像素流 -> 固定目标分辨率流 (Task 026)
//
// 行为规格见 doc/spec/behavior_spec.md(与 TB 黄金互验的单一真值)。
//
// 功能: 把任意尺寸(1..4096; 本任务承诺范围 >=640x480)的行优先源像素流重采样
//   为固定 DST_WIDTH x DST_HEIGHT(默认 640x480)的目标流。
//   KEEP_ASPECT=1(默认): 等比(contain)+居中黑边(16'h0000); =0: 拉伸铺满。
//   src == DST: 逐像素直通。输出帧恒恰 DSTW*DSTH 像素, 坐标连续行优先。
//
// 架构(流式; 无整帧缓存; 数据通路无除法/DSP):
//   * 几何(帧首一次): frame_start 当拍锁存源尺寸并全位宽比较 4*src_h<=3*src_w
//     判受约束轴(LESSON-013); 受约束轴内容尺寸 = DST 常数, 另一轴由 22 拍顺序
//     恢复除法器求 floor(DST_const*src_other/src_this); 黑边余量 floor 取半。
//   * 输入级(永不因输出停顿): 源像素入 16 深弹性 FIFO(输入侧无背压, 冻结契约;
//     满则丢弃并置 ovf_sticky——仅范围外极端放大可达)。弹出引擎逐像素水平
//     DDA(acc_h += cw; 折返 src_w 即发出 1 目标像素 -> 写 8 行槽环,
//     槽号 = s_committed mod 8, 每槽 640x16 = 1 块真 BRAM 写口)。行尾
//     s_committed++ 逐行提交。覆写保护: 提交行与"消费中行 s_live"同槽
//     (mod-8 同余非同行)时不写并标 starve => 该事件内容行体相发黑。
//   * 输出级(写侧取指 + 8 深 {pixel,x,y} FIFO + 读侧透传): 行缓冲为
//     **同步寄存读出**(TD 推 BRAM18 真块, 每块 1 写口 + 1 读口): 写侧以
//     col_a(地址)/col_p(呈现)双指针流水, 发址拍寄存取数, 1 拍后连同体相位
//     压入输出 FIFO; 坐标随数据入队 => 对齐由构造保证。读侧
//     !dn_full && !empty 即弹出打拍呈现(dn_full 期间天然保持, ★S7)。
//     承诺范围内源行 >=640 像素 => 每行输入 >=1920 拍(3 拍/像素)vs 输出行
//     <=~700 拍, 读侧恒快、不触发覆写保护; 下游持续反压超 ~8 行才进入
//     starve 降级(坐标/节拍恒完整, 确定行为)。第 DSTW*DSTH 个弹出后的
//     下一空闲拍 frame_done 单拍。
//   * frame_start 任意时刻可中止重启(S8): 帧内状态全复位(sticky 仅 rst_n 清)。
//
// 闭式映射(TB 黄金按此用整数除法独立实现, 与 RTL 累加器 DDA 异构, LESSON-001;
// 本设计采用"段末"ceil 最近邻约定):
//   内容行内目标列 t <- 源列 sx(t) = ((t+1)*src_w + cw - 1)/cw - 1
//   第 c 个内容行    <- 源行 sy(c) = ((c+1)*src_h + ch - 1)/ch - 1
//   1:1(src==DST)时 sx=t, sy=c => 逐像素直通。
//
// 退化行为(范围外, 确定、不越界、不死锁): src 尺寸 0 => 整帧黑仍出满帧;
//   ch=0(极扁源) => 无内容行全黑; cw=0(极窄源) => 内容行体宽 0 全黑;
//   输出持续落后 => 落后槽内容行体相发黑(坐标/节拍恒完整); 极端放大输入
//   FIFO 溢出丢像素 => 行为确定但不完整(behavior_spec 承诺范围外)。
// ============================================================================

module bmp_resampler #(
    parameter integer DST_WIDTH   = 640,   // 目标显示宽(固定)
    parameter integer DST_HEIGHT  = 480,   // 目标显示高(固定)
    parameter integer KEEP_ASPECT = 1,     // 1=保持比例+居中黑边; 0=拉伸填满
    parameter integer CROP_PERCENT = 6     // 宽源(>4:3)轻微裁切百分比: 内容高度
                                           // 提升该比例(黑边变窄), 等比放大后居中
                                           // 裁左右; 0=纯 contain; 竖源不生效
)(
    input  wire        clk,          // ctrl_clk, 50 MHz
    input  wire        rst_n,

    // ---- 帧控制 ----
    input  wire        frame_start,  // 单拍脉冲: 开始新一帧

    // ---- 源图像信息(来自 converter, 帧首稳定) ----
    input  wire [15:0] src_width,    // 源图宽 (1..4096)
    input  wire [15:0] src_height,   // 源图高 (1..4096)

    // ---- 源像素流(converter 输出: 行优先, 源坐标) ----
    input  wire [12:0] in_x,         // 源列(映射不依赖坐标值)
    input  wire [11:0] in_y,         // 源行
    input  wire [15:0] in_pixel,     // RGB565
    input  wire        in_valid,

    // ---- 目标像素流(喂 bmp_row_order_adapter) ----
    output reg  [10:0] out_x,        // 目标列 0..DST_WIDTH-1
    output reg  [9:0]  out_y,        // 目标行 0..DST_HEIGHT-1
    output reg  [15:0] out_pixel,    // RGB565
    output reg         out_valid,
    input  wire        dn_full,      // 下游 FIFO 满(= row_adapter.fifo_full)

    // ---- 状态 ----
    output reg         frame_done,   // 整帧输出完成, 单拍脉冲
    // ---- [task_037 P-C] 内容尺寸引出: 本帧几何(cw/ch)实际值 —— KEEP_ASPECT=1
    //   时为去黑边后的内容区宽高(frame_start 几何相完成后帧内稳定)。二级字幕的
    //   "存储内容尺寸"以此为准(非 4:3 源有黑边, 不得用 DST 常量代替)。
    output wire [15:0] content_w,
    output wire [15:0] content_h
);

    localparam [15:0] DSTW  = DST_WIDTH[15:0];
    localparam [15:0] DSTH  = DST_HEIGHT[15:0];
    localparam [10:0] DSTW11 = DST_WIDTH[10:0];
    localparam [9:0]  DSTH9  = DST_HEIGHT[9:0];
    localparam [18:0] FP19  = DST_WIDTH * DST_HEIGHT;

    // ------------------------------------------------------------------------
    // 输入级
    // ------------------------------------------------------------------------
    localparam [1:0] I_IDLE = 2'd0, I_TAKE = 2'd1, I_WR = 2'd2, I_ROW = 2'd3;
    reg [1:0]  ie_s;
    reg [15:0] sw_r, sh_r;           // 锁存源尺寸
    reg [15:0] cw,  ch;              // 内容尺寸
    reg [15:0] x_off, src_win;       // 水平裁切窗口(源列): [x_off, x_off+src_win)
    reg        div_phase;            // 几何除法阶段: 0=src_win, 1=ch/cw
    reg [10:0] lft, rgt;             // 左/右黑边列数
    reg [9:0]  top_b, bot_b;         // 上/下黑边行数
    reg        geom_valid;
    reg        case_a;
    reg        geo_bad_sticky;       // 尺寸 0 / 商钳位(sticky, 仅探针)
    reg [15:0] acc_h;                // 水平 DDA 累加器(<sw_r)
    reg [15:0] rc;                   // 行内已消费像素数
    reg [10:0] bwidx;                // 暂存写索引(体相相对列)
    reg [15:0] px;
    reg        ovf_sticky;
    reg        starve_sticky;

    // [task_037 P-C] 内容尺寸 = 几何寄存器直引(frame_start 几何相完成后帧内稳定)
    assign content_w = cw;
    assign content_h = ch;

    reg [15:0] ififo [0:15];
    reg [3:0]  iw, ir;
    reg [5:0]  icnt;
    wire [15:0] ififo_hd  = ififo[ir];
    wire        ififo_full = (icnt == 6'd16);
    wire        push_ok   = in_valid && !frame_start && !ififo_full;
    wire        push_drop = in_valid && !frame_start && ififo_full;
    wire        pop_en    = (ie_s == I_TAKE) && !frame_start && (icnt != 6'd0);
    wire        ie_go     = (ie_s == I_IDLE) && geom_valid && (icnt != 6'd0);
    wire [15:0] hnext = acc_h + cw;
    wire        hwr1  = (hnext >= src_win);
    wire [15:0] hrem  = hnext - src_win;
    wire        hwr2  = (hrem >= src_win);
    wire [15:0] win_end = x_off + src_win;
    wire        in_win  = (rc >= x_off) && (rc < win_end);  // 裁切窗口内源列
    wire        row_last     = (rc == sw_r - 16'd1);   // 本拍消费行末像素
    wire        row_last_wr  = (rc == sw_r);           // I_WR 续写后行尾

    // 8 深行槽环(每槽 1024x16 = 16Kbit = 2 块 BRAM9K(实测): 1 写口(输入)+1 同步读口
    // (输出); 2 的幂深度 + 无 initial 初始化 = 工程已验证的 BRAM 映射形态
    // (同 u_pixel_fifo 1024x16); 640 深度非 2 幂/带 init 会被 TD 展成 FF)。
    // 覆盖缩小场景每输出行 <=9 源行跨度; 提交节奏 >=1920 拍/行(sw>=640)远慢
    // 于读槽占用窗 => 承诺范围内环不碰撞。
    reg [15:0] buf0 [0:1023];
    reg [15:0] buf1 [0:1023];
    reg [15:0] buf2 [0:1023];
    reg [15:0] buf3 [0:1023];
    reg [15:0] buf4 [0:1023];
    reg [15:0] buf5 [0:1023];
    reg [15:0] buf6 [0:1023];
    reg [15:0] buf7 [0:1023];

    // 行提交/覆写保护/消费进度
    reg [15:0] s_committed;          // 已提交源行数
    reg [15:0] s_live;               // 输出侧正在消费的源行
    reg [15:0] s_cons;               // 下一内容行要消费的源行号(ceil 段末)
    reg [15:0] vacc;                 // 垂直 DDA 余数
    reg        slot_starv0, slot_starv1, slot_starv2, slot_starv3;
    reg        slot_starv4, slot_starv5, slot_starv6, slot_starv7;
    // 同槽且非同行 => 本行写会毁在途数据 => 丢弃写入并标星
    wire       row_drop = (s_committed[2:0] == s_live[2:0]) && (s_committed != s_live);
    // 行槽环唯一写口(I_TAKE/I_WR 两支合流): 每阵列单条件写 = BRAM 映射形态
    wire       buf_wr_take = (ie_s == I_TAKE) && (icnt != 6'd0) && hwr1 && in_win &&
                             !row_drop && !frame_start;
    wire       buf_wr_iwr  = (ie_s == I_WR) && !row_drop && !frame_start;
    wire       buf_wr      = buf_wr_take || buf_wr_iwr;
    wire [15:0] buf_wdata  = (ie_s == I_TAKE) ? ififo_hd : px;
    // 提交行 -> 槽号 / 锁存消费行 -> 星位
    wire [2:0] wr_slot = s_committed[2:0];
    wire       cons_starv =
        (s_cons[2:0] == 3'd0) ? slot_starv0 :
        (s_cons[2:0] == 3'd1) ? slot_starv1 :
        (s_cons[2:0] == 3'd2) ? slot_starv2 :
        (s_cons[2:0] == 3'd3) ? slot_starv3 :
        (s_cons[2:0] == 3'd4) ? slot_starv4 :
        (s_cons[2:0] == 3'd5) ? slot_starv5 :
        (s_cons[2:0] == 3'd6) ? slot_starv6 : slot_starv7;

    // ------------------------------------------------------------------------
    // 几何除法(22 拍恢复余数)
    // ------------------------------------------------------------------------
    reg [15:0] div_rem;
    reg [21:0] div_num, div_sr;
    reg [15:0] div_d;
    reg [4:0]  div_cnt;
    reg        div_run;
    wire [16:0] div_trial = {div_rem, div_num[21]};
    wire        div_ge    = (div_trial >= {1'b0, div_d});
    wire [16:0] div_sub   = div_trial - {1'b0, div_d};
    wire [21:0] div_qfin  = {div_sr[20:0], div_ge};
    // phase0 商钳位到源宽(src_win 不得超 sw)
    wire [15:0] div_qcl_w = (div_qfin > {6'd0, sw_r}) ? sw_r : div_qfin[15:0];
    wire [21:0] div_qcl   = case_a ? ((div_qfin > {6'd0, DSTH}) ? {6'd0, DSTH} : {6'd0, div_qfin[15:0]})
                                   : ((div_qfin > {6'd0, DSTW}) ? {6'd0, DSTW} : {6'd0, div_qfin[15:0]});
    wire [15:0] fin_cw = case_a ? DSTW : div_qcl[15:0];
    wire [15:0] fin_ch = case_a ? div_qcl[15:0] : DSTH;
    wire [10:0] fin_lft = (DSTW - fin_cw) >> 1;
    wire [10:0] fin_rgt = DSTW - fin_cw - fin_lft;
    wire [9:0]  fin_top = (DSTH - fin_ch) >> 1;
    wire [9:0]  fin_bot = DSTH - fin_ch - fin_top;
    wire        fin_clamp = case_a ? (div_qfin > {6'd0, DSTH})
                                   : (div_qfin > {6'd0, DSTW});
    wire [17:0] four_h3  = {src_height, 2'b00};
    wire [17:0] three_w3 = {1'b0, src_width, 1'b0} + {2'b00, src_width};
    wire        wide_axis = (four_h3 <= three_w3);
    wire [31:0] div_prod_wh = {16'd0, DSTW} * {16'd0, src_height};
    wire [31:0] div_prod_hw = {16'd0, DSTH} * {16'd0, src_width};

    // ------------------------------------------------------------------------
    // 输出级: 写侧双指针取指(同步读) + 8 深 {pix,x,y} FIFO + 读侧
    // ------------------------------------------------------------------------
    localparam [2:0] W_IDLE = 3'd0, W_EVT = 3'd1, W_FETCH = 3'd2,
                     W_END = 3'd3, W_FIN = 3'd4;
    localparam [1:0] EP_ADD = 2'd0, EP_SUB = 2'd1, EP_WAIT = 2'd2;
    reg [2:0]  ws;
    reg [1:0]  ep;
    reg        first_row;            // 首内容行(sy(0)=ceil(sh/ch)-1 免预加修正)
    reg [10:0] col_a;                // 取指地址指针(下一发址列, 0..640)
    reg [10:0] col_p;                // 呈现指针(下一压入列, 0..640)
    // 每槽独立同步读寄存(阵列读出直接寄存 -> TD 推真 BRAM18; mux 后置)
    reg [15:0] rq0, rq1, rq2, rq3, rq4, rq5, rq6, rq7;
    reg        body_q;               // 待发数据对应列为体相
    reg        dv;                   // rd_q/body_q 有效且未压入
    reg [9:0]  oy_f;                 // 写侧行 0..479
    reg [2:0]  w_slot;               // 当前写行锁存槽号
    reg        w_starved;            // 当前写行星位
    reg        w_content;            // 当前写行为内容行(黑边行为 0)
    reg [18:0] rd_cnt;               // 读侧弹出计数
    reg [2:0]  fw, fr;
    reg [3:0]  fcnt;                 // 占用 0..8
    reg [15:0] fp [0:7];
    reg [10:0] fX [0:7];
    reg [9:0]  fY [0:7];
    wire        fifo_full  = (fcnt == 4'd8);
    wire        fifo_empty = (fcnt == 4'd0);
    wire        push_ok_o  = (ws == W_FETCH) && dv && !fifo_full && !frame_start;
    wire        pop_ok_o   = !dn_full && !fifo_empty && !frame_start;
    wire [2:0]  fnext_w = fw + 3'd1;
    wire [2:0]  fnext_r = fr + 3'd1;
    wire [3:0]  fcnt_n  = fcnt + {3'b000, push_ok_o} - {3'b000, pop_ok_o};

    // ---- 同步读口: 体相地址 = col_a - lft(仅 body_a 时有意义) ----
    wire [11:0] cola12 = {1'b0, col_a};
    wire [11:0] bl12   = {1'b0, lft};
    wire [11:0] be12   = {1'b0, lft} + {2'b00, cw[10:0]};
    wire        body_a = w_content && !w_starved &&
                         (cola12 >= bl12) && (cola12 < be12);
    wire [10:0] bcol_a = col_a - lft;
    wire [9:0]  oxf9   = bcol_a[9:0];
    wire [15:0] slot_val =
        (w_slot == 3'd0) ? rq0 :
        (w_slot == 3'd1) ? rq1 :
        (w_slot == 3'd2) ? rq2 :
        (w_slot == 3'd3) ? rq3 :
        (w_slot == 3'd4) ? rq4 :
        (w_slot == 3'd5) ? rq5 :
        (w_slot == 3'd6) ? rq6 : rq7;
    // 发址条件: 行内还有列未发, 且流水线空出位置(未压入的读出数据不覆写)
    wire        issue_en = (ws == W_FETCH) && (col_a < DSTW11) &&
                           (!dv || push_ok_o) && !frame_start;
    wire [15:0] push_val = body_q ? slot_val : 16'h0000;

    // 垂直 DDA(内容行起点): 每事件行 vacc += sh_r; 折返 ch 次数 => s_cons 增量。
    // 闭式 sy(c)=((c+1)*sh + ch-1)/ch - 1 与增量式对 c=0 差 1 => 首行预减 1。
    wire [15:0] ov_next = vacc + sh_r - {15'd0, first_row};
    wire        ov_wr1  = (ov_next >= ch);
    wire [15:0] ov_rem  = ov_next - ch;
    wire        ov_wr2  = ov_wr1 && (ov_rem >= ch);
    wire [15:0] ov_rem2 = ov_rem - ch;
    // 下一行是否内容行(行尾写去向)
    wire [9:0]  oy_n    = oy_f + 10'd1;
    wire [10:0] oyl11   = {1'b0, oy_n};
    wire [11:0] contE   = {1'b0, top_b} + {2'b00, ch[9:0]};
    wire        nxt_content = (ch != 16'd0) && (oyl11 >= {1'b0, top_b}) &&
                              (oyl11 < contE);
    // 行完(最后列已压入)
    wire        row_pushed = push_ok_o && (col_p == DSTW11 - 11'd1);

    // ------------------------------------------------------------------------
    // 主时序(单 always; TD 多驱动规避: 各信号仅一写点)
    // ------------------------------------------------------------------------
    integer ii;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sw_r <= 16'd0; sh_r <= 16'd0;
            x_off <= 16'd0; src_win <= 16'd0; div_phase <= 1'b0;
            cw <= 16'd0; ch <= 16'd0;
            lft <= 11'd0; rgt <= 11'd0; top_b <= 10'd0; bot_b <= 10'd0;
            geom_valid <= 1'b0; case_a <= 1'b0; geo_bad_sticky <= 1'b0;
            div_rem <= 16'd0; div_num <= 22'd0; div_sr <= 22'd0;
            div_d <= 16'd0; div_cnt <= 5'd0; div_run <= 1'b0;
            iw <= 4'd0; ir <= 4'd0; icnt <= 6'd0;
            ovf_sticky <= 1'b0; starve_sticky <= 1'b0;
            ie_s <= I_IDLE; acc_h <= 16'd0; rc <= 16'd0;
            bwidx <= 11'd0; px <= 16'd0;
            s_committed <= 16'd0; s_live <= 16'd0;
            s_cons <= 16'd0; vacc <= 16'd0;
            slot_starv0 <= 1'b0; slot_starv1 <= 1'b0;
            slot_starv2 <= 1'b0; slot_starv3 <= 1'b0;
            slot_starv4 <= 1'b0; slot_starv5 <= 1'b0;
            slot_starv6 <= 1'b0; slot_starv7 <= 1'b0;
            ws <= W_IDLE; ep <= EP_ADD; first_row <= 1'b1;
            col_a <= 11'd0; col_p <= 11'd0; body_q <= 1'b0;
            rq0 <= 16'd0; rq1 <= 16'd0; rq2 <= 16'd0; rq3 <= 16'd0;
            rq4 <= 16'd0; rq5 <= 16'd0; rq6 <= 16'd0; rq7 <= 16'd0;
            dv <= 1'b0;
            oy_f <= 10'd0;
            w_slot <= 3'd0; w_starved <= 1'b0; w_content <= 1'b0;
            fw <= 3'd0; fr <= 3'd0; fcnt <= 4'd0;
            rd_cnt <= 19'd0;
            out_x <= 11'd0; out_y <= 10'd0; out_pixel <= 16'd0;
            out_valid <= 1'b0; frame_done <= 1'b0;
        end else begin
            frame_done <= 1'b0;

            // ================================================================
            // frame_start: 帧复位 + 几何启动
            // ================================================================
            if (frame_start) begin
                sw_r <= src_width; sh_r <= src_height;
                iw <= 4'd0; ir <= 4'd0; icnt <= 6'd0;
                ie_s <= I_IDLE; acc_h <= 16'd0; rc <= 16'd0;
                bwidx <= 11'd0;
                s_committed <= 16'd0; s_live <= 16'd0;
                s_cons <= 16'd0; vacc <= 16'd0;
                slot_starv0 <= 1'b0; slot_starv1 <= 1'b0;
                slot_starv2 <= 1'b0; slot_starv3 <= 1'b0;
                slot_starv4 <= 1'b0; slot_starv5 <= 1'b0;
                slot_starv6 <= 1'b0; slot_starv7 <= 1'b0;
                ws <= W_IDLE; ep <= EP_ADD; first_row <= 1'b1;
                col_a <= 11'd0; col_p <= 11'd0; dv <= 1'b0;
                oy_f <= 10'd0;
                w_slot <= 3'd0; w_starved <= 1'b0; w_content <= 1'b0;
                fw <= 3'd0; fr <= 3'd0; fcnt <= 4'd0;
                rd_cnt <= 19'd0;
                out_valid <= 1'b0;
                geom_valid <= 1'b0; div_run <= 1'b0;
                if (src_width == 16'd0 || src_height == 16'd0) begin
                    geo_bad_sticky <= 1'b1;
                    cw <= 16'd0; ch <= 16'd0;
                    lft <= 11'd0; rgt <= 11'd0;
                    top_b <= 10'd0; bot_b <= 10'd0;
                    x_off <= 16'd0; src_win <= 16'd0;
                    geom_valid <= 1'b1;
                end else if (KEEP_ASPECT == 0) begin
                    cw <= DSTW; ch <= DSTH;
                    lft <= 11'd0; rgt <= 11'd0;
                    top_b <= 10'd0; bot_b <= 10'd0;
                    x_off <= 16'd0; src_win <= src_width;
                    geom_valid <= 1'b1;
                end else if (wide_axis && (CROP_PERCENT > 0) &&
                             (four_h3 < three_w3)) begin
                    // 宽源(严格宽于4:3, 即纯contain会有上下黑边)+裁切:
                    // phase0 先算源窗口宽, phase1 再算内容高
                    case_a    <= 1'b1;
                    div_phase <= 1'b0;
                    div_d     <= 16'd100 + CROP_PERCENT[15:0];
                    div_num   <= ({6'd0, src_width} << 6) +
                                 ({7'd0, src_width} << 5) +
                                 ({10'd0, src_width} << 2);   // sw*100
                    div_sr    <= 22'd0; div_rem <= 16'd0; div_cnt <= 5'd0;
                    div_run   <= 1'b1;
                end else begin
                    case_a    <= wide_axis;
                    div_phase <= 1'b1;
                    x_off     <= 16'd0; src_win <= src_width;
                    div_d     <= wide_axis ? src_width  : src_height;
                    div_num   <= wide_axis ? div_prod_wh[21:0] : div_prod_hw[21:0];
                    div_sr    <= 22'd0; div_rem <= 16'd0; div_cnt <= 5'd0;
                    div_run   <= 1'b1;
                end
            end else begin
            // ================================================================
            // 输入 FIFO
            // ================================================================
            if (push_ok) begin
                ififo[iw] <= in_pixel;
                iw <= iw + 4'd1;
            end else if (push_drop) begin
                ovf_sticky <= 1'b1;
            end
            if (pop_en) ir <= ir + 4'd1;
            if (push_ok && pop_en) icnt <= icnt;
            else if (push_ok)      icnt <= icnt + 6'd1;
            else if (pop_en)       icnt <= icnt - 6'd1;

            // ================================================================
            // 几何除法步进
            // ================================================================
            if (div_run) begin
                div_num <= {div_num[20:0], 1'b0};
                div_sr  <= {div_sr[20:0], div_ge};
                div_rem <= div_ge ? div_sub[15:0] : div_trial[15:0];
                if (div_cnt == 5'd21) begin
                    if (div_phase == 1'b0) begin
                        // phase0: src_win = sw*100/(100+CROP), 居中裁切偏移
                        src_win   <= div_qcl_w;
                        x_off     <= (sw_r - div_qcl_w) >> 1;
                        div_phase <= 1'b1;
                        div_d     <= div_qcl_w;        // case_a 除数=源窗口宽
                        div_num   <= div_prod_wh[21:0];// case_a 被除数=640*sh
                        div_sr    <= 22'd0; div_rem <= 16'd0; div_cnt <= 5'd0;
                    end else begin
                        div_run <= 1'b0;
                        cw <= fin_cw; ch <= fin_ch;
                        lft <= fin_lft; rgt <= fin_rgt;
                        top_b <= fin_top; bot_b <= fin_bot;
                        geom_valid <= 1'b1;
                        if (fin_clamp) geo_bad_sticky <= 1'b1;
                    end
                end else begin
                    div_cnt <= div_cnt + 5'd1;
                end
            end

            // ================================================================
            // 输入级 FSM(1 拍/像素; 多次折返续写 I_WR; 行尾提交 I_ROW)
            // ================================================================
            case (ie_s)
                I_IDLE: if (ie_go) ie_s <= I_TAKE;
                I_TAKE: begin
                    if (icnt != 6'd0) begin
                        px <= ififo_hd;
                        rc <= rc + 16'd1;
                        if (in_win) begin
                            if (hwr1) begin
                                if (!row_drop) bwidx <= bwidx + 11'd1;
                                acc_h <= hrem;
                                if (hwr2)            ie_s <= I_WR;
                                else if (row_last)   ie_s <= I_ROW;
                                else                 ie_s <= I_TAKE;
                            end else begin
                                acc_h <= hnext;
                                if (row_last) ie_s <= I_ROW;
                                else          ie_s <= I_TAKE;
                            end
                        end else if (row_last) ie_s <= I_ROW;
                        else                   ie_s <= I_TAKE;
                    end else ie_s <= I_IDLE;
                end
                I_WR: begin
                    if (!row_drop) bwidx <= bwidx + 11'd1;
                    if (acc_h >= src_win) begin
                        acc_h <= acc_h - src_win;
                        ie_s  <= I_WR;
                    end else if (row_last_wr) ie_s <= I_ROW;
                    else if (icnt != 6'd0)    ie_s <= I_TAKE;
                    else                      ie_s <= I_IDLE;
                end
                I_ROW: begin
                    rc    <= 16'd0;
                    acc_h <= 16'd0;
                    bwidx <= 11'd0;
                    case (wr_slot)
                        3'd0: slot_starv0 <= row_drop;
                        3'd1: slot_starv1 <= row_drop;
                        3'd2: slot_starv2 <= row_drop;
                        3'd3: slot_starv3 <= row_drop;
                        3'd4: slot_starv4 <= row_drop;
                        3'd5: slot_starv5 <= row_drop;
                        3'd6: slot_starv6 <= row_drop;
                        default: slot_starv7 <= row_drop;
                    endcase
                    if (row_drop) starve_sticky <= 1'b1;
                    s_committed <= s_committed + 16'd1;
                    ie_s   <= I_IDLE;
                end
                default: ie_s <= I_IDLE;
            endcase

            // ================================================================
            // 行槽环写口(合流, 每阵列恰一处条件写)与同步读口(每阵列独立
            // 寄存读出; 读使能=发址拍——FIFO 冻结时 rq 必须停走, 否则解冻
            // 装载后一列数据 off-by-one)
            // ================================================================
            if (buf_wr) begin
                case (wr_slot)
                    3'd0: buf0[bwidx[9:0]] <= buf_wdata;
                    3'd1: buf1[bwidx[9:0]] <= buf_wdata;
                    3'd2: buf2[bwidx[9:0]] <= buf_wdata;
                    3'd3: buf3[bwidx[9:0]] <= buf_wdata;
                    3'd4: buf4[bwidx[9:0]] <= buf_wdata;
                    3'd5: buf5[bwidx[9:0]] <= buf_wdata;
                    3'd6: buf6[bwidx[9:0]] <= buf_wdata;
                    default: buf7[bwidx[9:0]] <= buf_wdata;
                endcase
            end
            if (issue_en) begin
                rq0 <= buf0[oxf9]; rq1 <= buf1[oxf9];
                rq2 <= buf2[oxf9]; rq3 <= buf3[oxf9];
                rq4 <= buf4[oxf9]; rq5 <= buf5[oxf9];
                rq6 <= buf6[oxf9]; rq7 <= buf7[oxf9];
            end

            // ================================================================
            // 输出 FIFO: 占用计数 + 读侧弹出(独立于写侧)
            // ================================================================
            fcnt <= fcnt_n;
            if (pop_ok_o) begin
                out_pixel <= fp[fr];
                out_x     <= fX[fr];
                out_y     <= fY[fr];
                out_valid <= 1'b1;
                fr        <= fnext_r;
                rd_cnt    <= rd_cnt + 19'd1;
            end else if (fifo_empty && !dn_full) begin
                out_valid <= 1'b0;
            end

            // ================================================================
            // 输出写侧 FSM(同步读取指流水: 发址 -> 1 拍后压入)
            // ================================================================
            case (ws)
                W_IDLE: begin
                    // 等几何沉降后定首行相位: 首行即内容(top=0 且有内容行)
                    // 必须走 W_EVT 提交门; 否则黑行直发(body_a=0, 色恒 0)。
                    if (geom_valid) begin
                        if (top_b == 10'd0 && ch != 16'd0) begin
                            ws <= W_EVT; ep <= EP_ADD;
                        end else begin
                            ws <= W_FETCH;
                        end
                    end
                end
                W_EVT: begin
                    if (geom_valid) begin
                        case (ep)
                            EP_ADD: begin
                                first_row <= 1'b0;
                                if (ov_wr2) begin
                                    vacc <= ov_rem2; s_cons <= s_cons + 16'd2;
                                    ep   <= EP_SUB;
                                end else if (ov_wr1) begin
                                    vacc <= ov_rem; s_cons <= s_cons + 16'd1;
                                    ep   <= EP_WAIT;
                                end else begin
                                    vacc <= ov_next; ep <= EP_WAIT;
                                end
                            end
                            EP_SUB: begin
                                if (vacc >= ch) begin
                                    vacc <= vacc - ch; s_cons <= s_cons + 16'd1;
                                end else ep <= EP_WAIT;
                            end
                            EP_WAIT: begin
                                // 等事件行提交, 且取指流水/FIFO 可动才锁存
                                if (s_committed > s_cons && !dv) begin
                                    w_slot    <= s_cons[2:0];
                                    w_starved <= cons_starv;
                                    s_live    <= s_cons;
                                    w_content <= 1'b1;
                                    col_a     <= 11'd0; col_p <= 11'd0;
                                    ep        <= EP_ADD;
                                    ws        <= W_FETCH;
                                end
                            end
                            default: ep <= EP_ADD;
                        endcase
                    end
                end
                W_FETCH: begin
                    // 发址(寄存读出, 推 BRAM 推断)
                    if (issue_en) begin
                        col_a  <= col_a + 11'd1;
                        body_q <= body_a;
                        if (!dv || push_ok_o) dv <= 1'b1;
                    end
                    // 压入(带 1 拍数据滞后, 坐标随列)
                    if (push_ok_o) begin
                        fp[fw]  <= push_val;
                        fX[fw]  <= col_p;
                        fY[fw]  <= oy_f;
                        fw      <= fnext_w;
                        col_p   <= col_p + 11'd1;
                        if (dv && !issue_en) dv <= 1'b0;
                        if (row_pushed) begin
                            col_a <= 11'd0; col_p <= 11'd0;
                            if (oy_f == DSTH9 - 10'd1) begin
                                ws <= W_END; w_content <= 1'b0;
                            end else begin
                                oy_f <= oy_n;
                                if (nxt_content) begin
                                    ws <= W_EVT; ep <= EP_ADD;
                                end else begin
                                    w_content <= 1'b0;
                                end
                            end
                        end
                    end
                end
                W_END: begin
                    // 480 行已全部推入; 末像素呈现已可被下游接受的拍上完成:
                    // 清 valid(读侧同拍亦清, 单写点)、发 frame_done 单拍、转终结。
                    // dn_full 时延后(末接受未完成即不得报 done)。
                    if (fifo_empty && !dn_full && rd_cnt == FP19) begin
                        ws         <= W_FIN;
                        frame_done <= 1'b1;
                    end
                end
                W_FIN: begin
                    ws <= W_FIN;          // 终结态自保持, 仅 frame_start 可出
                end
                default: ws <= W_IDLE;
            endcase
            end // else(非 frame_start)
        end
    end

    // ------------------------------------------------------------------------
    // 显式初值(iverilog 友好, 工程既有风格)
    // ------------------------------------------------------------------------
    initial begin
        sw_r = 16'd0; sh_r = 16'd0; cw = 16'd0; ch = 16'd0;
        x_off = 16'd0; src_win = 16'd0; div_phase = 1'b0;
        lft = 11'd0; rgt = 11'd0; top_b = 10'd0; bot_b = 10'd0;
        geom_valid = 1'b0; case_a = 1'b0; geo_bad_sticky = 1'b0;
        div_rem = 16'd0; div_num = 22'd0; div_sr = 22'd0;
        div_d = 16'd0; div_cnt = 5'd0; div_run = 1'b0;
        iw = 4'd0; ir = 4'd0; icnt = 6'd0;
        ovf_sticky = 1'b0; starve_sticky = 1'b0;
        ie_s = I_IDLE; acc_h = 16'd0; rc = 16'd0;
        bwidx = 11'd0; px = 16'd0;
        s_committed = 16'd0; s_live = 16'd0; s_cons = 16'd0; vacc = 16'd0;
        slot_starv0 = 1'b0; slot_starv1 = 1'b0;
        slot_starv2 = 1'b0; slot_starv3 = 1'b0;
        slot_starv4 = 1'b0; slot_starv5 = 1'b0;
        slot_starv6 = 1'b0; slot_starv7 = 1'b0;
        ws = W_IDLE; ep = EP_ADD; first_row = 1'b1;
        col_a = 11'd0; col_p = 11'd0; body_q = 1'b0; dv = 1'b0;
        rq0 = 16'd0; rq1 = 16'd0; rq2 = 16'd0; rq3 = 16'd0;
        rq4 = 16'd0; rq5 = 16'd0; rq6 = 16'd0; rq7 = 16'd0;
        oy_f = 10'd0;
        w_slot = 3'd0; w_starved = 1'b0; w_content = 1'b0;
        fw = 3'd0; fr = 3'd0; fcnt = 4'd0;
        rd_cnt = 19'd0;
        out_x = 11'd0; out_y = 11'd0; out_pixel = 16'd0;
        out_valid = 1'b0; frame_done = 1'b0;
        // 行槽环**故意不初始化**: RAM init 会阻断 TD 的 BRAM 映射(展开成 FF);
        // 结构上读口仅访问已被输入引擎写过并提交(EP_WAIT 门)的列 => 无 X 风险。
        for (ii = 0; ii < 16; ii = ii + 1) ififo[ii] = 16'd0;
    end

endmodule
