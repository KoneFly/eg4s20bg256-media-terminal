`timescale 1ns / 1ps
// ============================================================================
// bmp_sdram_loader — BMP->片上SDRAM帧缓冲加载集成 (Task 010)
//
// [M1a 集成副本 — task_022 偏差登记 §2.2] 本文件是 Task 012 基线的副本,
// 唯一集成修改 = "引出显示读端口组": 新增 d_display_*/d_frame_write_done 端口,
// 把内部 u_fb 的显示读端口直接对外(读响应不经 !load_busy gating)。
// 加载逻辑/状态机/原有端口逐字未动。理由: 显示链需在加载提交后读取前台
// 缓冲(双缓冲语义), 012 的 verify_valid && !load_busy gating 会掐断显示读;
// 原 verify_* 端口保留原语义(gated)以维持 012 兼容, M1a 顶层不使用其
// 显示功能(verify_req 恒 0)。基线 SHA256 见 doc/compile/run_report.md。
//
// [task_026 集成副本] 在 conv_pixel_* 与 u_row_adapt 之间插入 bmp_resampler
// (任意分辨率 -> 固定 640x480, 见 doc/spec/behavior_spec.md §5.2)。改动:
//   ST_HDR 删除"尺寸 != 640x480 即 size_error"分支(任意 <=4096 放行);
//   image_height_lock 改锁目标高度 480(行序映射按目标帧高);
//   px_wr 改计数 resampler 输出接受拍(= 目标像素, 恒 307200);
//   ST_WAIT_COMMIT 提交条件增加 res_done_seen + 适配层防挂死看门狗;
//   上游 converter 放宽 MAX 并加宽 conv_pixel_x/y 至 13/12bit。
//
// [task_026 第三步] 新增端口(加载 FSM/状态机逐字未动):
//   vsync_pulse  — 透传给 u_fb(VSYNC 帧边界提交, active_buffer 只在消隐
//                  脉冲拍翻转; frame_write_done/load_done 时序与旧版一致);
//   src_w_out/src_h_out — converter 解析出的源图宽/高引出(准静态, 供顶层
//                  帧提交拍锁存给分辨率字幕 res_caption)。
//
// 链路:
//   连续BMP字节流 -> 输入FIFO -> bmp_stream_align_shim(2字节滞后重对齐)
//     -> bmp24_to_rgb565_converter(Task005)
//     -> 行序坐标适配 fb_y (依据 bmp_top_down_observer 的 top_down)
//     -> 像素弹性FIFO -> sdram_frame_buffer(Task007, 640x480)
//
// 设计决策 (详见 doc/spec/behavior_spec.md):
//   1. Task005 头部解析丢弃文件字节54,55 (探针实证)。用 align_shim 输入侧重对齐。
//   2. Task005 无 top_down 状态。用并行 observer 观测 biHeight 符号位。
//   3. fb_y = top_down ? pixel_y : (image_height-1 - pixel_y)。
//      Task007 内部每次写/读各做一次行反转; 输入端补这一次反转后, HDMI
//      显示逻辑坐标 y=0 恰好读到 BMP 视觉顶行。
//   4. 背压: Task005 无 ready, loader 用"字级节流"——仅在像素弹性FIFO 余量
//      足够且距上次喂入>=4拍时喂 converter 下一个字。像素FIFO 吸收
//      Task007 pixel_ready=0 的瞬时积压。
//   5. load_done 只在整帧像素已写给 Task007 (frame_write_done) 后置位。
//
// 时序要点:
//   * ST_WAIT_INIT 阶段不喂 converter——init_done 约25000拍, 提前喂会令
//     converter 在 size_ok 评估(需等 init_done 后才有数据进行)前输出像素,
//     违反"不丢像素"。init 期间上游数据由输入FIFO(32深)打底, 满则背压。
//   * 尺寸/格式/流错误统一在 ST_HDR 依 converter 输出评估, 错误直接回 IDLE。
// ============================================================================
module bmp_sdram_loader #(
    parameter integer FRAME_WIDTH    = 640,
    parameter integer FRAME_HEIGHT   = 480,
    parameter integer FIFO_DEPTH     = 32,     // 输入字 FIFO 深度
    parameter integer PIX_FIFO_DEPTH = 32,     // 像素弹性 FIFO 深度
    // sdram_refresh_timer 参数: tREFI 15.625us @ ctrl_clk 实际频率。
    // 125MHz -> 1953(默认), 50MHz -> 781。上板顶层传 781, tb_top 不改(125M)。
    parameter integer REF_CYCLES_CTRL = 1953
)(
    input  wire        ctrl_clk,
    input  wire        sdram_clk,
    input  wire        rst_n,

    // 连续 BMP 文件字节流
    input  wire        stream_start,
    input  wire [31:0] data_in,
    input  wire        data_valid,
    input  wire        stream_done,
    output wire        stream_ready,

    // 加载状态与错误
    output reg         load_busy,
    output reg         load_done,
    output reg         format_error,
    output reg         size_error,
    output reg         stream_error,

    // 帧缓冲读回自检接口
    input  wire        verify_req,
    input  wire [10:0] verify_x,
    input  wire [9:0]  verify_y,
    output wire [15:0] verify_data,
    output wire        verify_valid,

    // [M1a 偏差 §2.2] 引出的显示读端口组(直连 u_fb, 无 gating)
    input  wire        d_display_req,     // fb 显示读请求(单拍脉冲协议, 019 语义)
    input  wire [10:0] d_display_x,
    input  wire [9:0]  d_display_y,
    output wire [15:0] d_display_data,
    output wire        d_display_valid,   // = fb_verify_valid(去掉 !load_busy gating)
    output wire        d_frame_write_done,// = fb_done(原内部信号)

    // [task_026 第三步] VSYNC 帧边界提交 + 源尺寸引出
    input  wire        vsync_pulse,       // ctrl 域帧消隐单拍脉冲(透传 u_fb)
    output wire [15:0] src_w_out,         // converter 源图宽(准静态)
    output wire [15:0] src_h_out,         // converter 源图高(准静态)

    // 帧缓冲状态
    output wire        init_done,
    output wire        active_buffer
);

    localparam integer FRAME_PIXELS = FRAME_WIDTH * FRAME_HEIGHT;

    // ========================================================================
    // 状态机
    // ========================================================================
    localparam [3:0]
        ST_IDLE        = 4'd0,
        ST_WAIT_INIT   = 4'd1,   // 等 init_done
        ST_HDR         = 4'd2,   // 解析头部 / 尺寸校验
        ST_LOAD        = 4'd3,   // 转换 + 写像素
        ST_WAIT_COMMIT = 4'd4,   // 等 converter done + FIFO 排空 + frame_write_done
        ST_DONE        = 4'd5,   // load_done 脉冲
        ST_FLUSH       = 4'd6;   // 错误后排空输入 FIFO 残渣, 再回 IDLE

    reg [3:0]  state;

    // ---- 协调信号 ----
    reg         size_ok;          // 图像尺寸 = FRAME 且无格式错误
    reg         size_eval;        // 已从 converter 评估尺寸
    reg         conv_done_seen;   // converter 已完成
    reg         str_done_seen;    // stream_done 已见
    reg [20:0]  pixel_cnt;        // 已写入 Task007 像素计数
    reg [9:0]   image_height_lock; // 绝对值高度 (用于 fb_y)
    reg         conv_start_pulse; // 启动脉冲 (喂 converter/observer/shim)
    reg [15:0]  trunc_cnt;        // 截断判定滞回计数
    reg [1:0]   flush_stage;      // FLUSH 阶段: 0=排空FIFO, 1=喂dummy推converter
    reg         fb_done_seen;     // Task007 帧翻转已见 (翻转可能早于 WAIT_COMMIT)
    reg         res_done_seen;    // [task_026] resampler 帧完成已见
    reg [19:0]  commit_wd;        // [task_026] 输出链停滞看门狗(2^20 拍)
    // 输出链为空且resampler尚未完成时累计停滞；不代表所有stream_error来源。
    // 首次frame_write_done前显示引擎未武装，不能以显示争抢解释首帧失败。
    wire        px_starve = !pix_fifo_full && pix_out_empty &&
                            !res_out_valid && !res_frame_done;

    // ========================================================================
    // 输入字 FIFO
    // ========================================================================
    wire        in_fifo_full, in_fifo_empty;
    wire [31:0] in_fifo_dout;
    wire        in_fifo_rd;

    sync_fifo #(.WIDTH(32), .DEPTH(FIFO_DEPTH))
        u_in_fifo (
            .clk      (ctrl_clk),
            .rst_n    (rst_n),
            .wr_en    (stream_ready && data_valid),
            .din      (data_in),
            .rd_en    (in_fifo_rd),
            .dout     (in_fifo_dout),
            .full     (in_fifo_full),
            .empty    (in_fifo_empty),
            .near_full(),
            .count    ()
        );

    // 接收窗口: 加载进行中接收; 提交后不再接收
    wire active_accept = (state == ST_WAIT_INIT) || (state == ST_HDR) ||
                         (state == ST_LOAD);
    assign stream_ready = !in_fifo_full && active_accept;

    // ========================================================================
    // 行序适配 + 像素弹性缓冲 (bmp_row_order_adapter, 职责详见模块头)
    // ========================================================================
    // converter 像素流输出 (前向声明提前, 消 HDL-5373; 定义见下方实例化)
    wire [15:0] conv_pixel_out;
    wire        conv_pixel_valid;
    wire [12:0] conv_pixel_x;   // [task_026] 13/12bit: 4K 坐标不截断
    wire [11:0] conv_pixel_y;
    // resampler 输出(前向声明提前, 消 HDL-5373; 定义见 u_resampler 实例化)
    wire [10:0] res_out_x;
    wire [9:0]  res_out_y;
    wire [15:0] res_out_pixel;
    wire        res_out_valid;
    wire        res_frame_done;
    reg         res_start_pulse;
    // conv 图像尺寸(前向声明提前供 u_resampler 端口使用, 消 HDL-5373)
    wire [15:0] conv_image_width;
    wire [15:0] conv_image_height;
    // top_down 观测器输出 (前向声明提前, 消 HDL-5373)
    wire        top_down;

    wire        pix_fifo_full;
    wire        pix_near_full, pix_out_empty;
    wire [15:0] pix_out_data;
    wire [10:0] pix_out_x;
    wire [9:0]  pix_out_y;
    wire        pix_out_valid;

    // [task_026] 目标像素接受计数(喂 fb 与 pixel_cnt 同拍): resampler 输出
    //   && 下游未满。state/pulse 门控防"上一帧 abort 残留输出"在新帧
    //   ST_LOAD 第 1 拍(frame_start 脉冲拍)被误计入新帧。
    wire        px_wr = res_out_valid && !pix_fifo_full && size_ok &&
                        ((state == ST_WAIT_COMMIT) ||
                         ((state == ST_LOAD) && !res_start_pulse));
    // resampler 输入门控(源像素, 仅 size_ok 期间放行)
    wire        res_in_valid = conv_pixel_valid && size_ok;

    // fb_pixel_ready 前向声明(Task007 实例在下方, 消 HDL-5373/隐式声明)
    wire        fb_pixel_ready;

    // ========================================================================
    // [task_026] 多分辨率适配: conv 源像素流 -> 目标 640x480 流(行优先+居中黑边)
    //   dn_full = u_row_adapt.fifo_full(契约指定); frame_start = 本帧几何锁存后
    //   的 res_start_pulse(进 ST_LOAD 第 1 拍, conv_image_* 已稳定 >=3 拍)。
    // ========================================================================
    bmp_resampler #(
        .DST_WIDTH   (FRAME_WIDTH),
        .DST_HEIGHT  (FRAME_HEIGHT),
        .KEEP_ASPECT (1)
    ) u_resampler (
        .clk         (ctrl_clk),
        .rst_n       (rst_n),
        .frame_start (res_start_pulse),
        .src_width   (conv_image_width),
        .src_height  (conv_image_height),
        .in_x        (conv_pixel_x),
        .in_y        (conv_pixel_y),
        .in_pixel    (conv_pixel_out),
        .in_valid    (res_in_valid),
        .out_x       (res_out_x),
        .out_y       (res_out_y),
        .out_pixel   (res_out_pixel),
        .out_valid   (res_out_valid),
        .dn_full     (pix_fifo_full),
        .frame_done  (res_frame_done)
    );

    bmp_row_order_adapter #(
        .FRAME_HEIGHT   (FRAME_HEIGHT),
        .PIX_FIFO_DEPTH (PIX_FIFO_DEPTH)
    ) u_row_adapt (
        .clk        (ctrl_clk),
        .rst_n      (rst_n),
        .top_down   (top_down),
        .image_height (image_height_lock[9:0]),
        .in_data    (res_out_pixel),   // [task_026] 改接 resampler 输出(目标坐标)
        .in_x       (res_out_x),
        .in_y       (res_out_y),
        .in_valid   (px_wr),
        .out_data   (pix_out_data),
        .out_x      (pix_out_x),
        .out_y      (pix_out_y),
        .out_valid  (pix_out_valid),
        .out_ready  (fb_pixel_ready),
        .fifo_full  (pix_fifo_full),
        .near_full  (pix_near_full),
        .out_empty  (pix_out_empty)
    );

    // ========================================================================
    // Task 007 帧缓冲
    // ========================================================================
    wire fb_init_done, fb_active_buffer, fb_done;
    wire [15:0] fb_verify_data;
    wire        fb_verify_valid;

    sdram_frame_buffer #(
        .FRAME_WIDTH (FRAME_WIDTH),
        .FRAME_HEIGHT(FRAME_HEIGHT),
        // tREFI 15.625us: 默认1953是125MHz值, ctrl_clk 实际频率 = 50MHz(上板)
        // / 125MHz(tb_top 手工双相时钟), 由参数 REF_CYCLES_CTRL 按频率换算覆盖
        .REF_INTERVAL_CYCLES (REF_CYCLES_CTRL)
    ) u_fb (
        .clk             (ctrl_clk),
        .sdram_clk       (sdram_clk),
        .rst_n           (rst_n),
        .init_done       (fb_init_done),
        .pixel_valid     (pix_out_valid),
        .pixel_ready     (fb_pixel_ready),
        .pixel_data      (pix_out_data),
        .pixel_x         (pix_out_x),
        .pixel_y         (pix_out_y),
        // [M1a 偏差 §2.2] 显示读端口直连引出的 d_display_* (verify_* 不再
        // 驱动 u_fb, M1a 顶层将 verify_req 恒接 0, 行为无差异)
        .display_req     (d_display_req),
        .display_x       (d_display_x),
        .display_y       (d_display_y),
        .display_data    (fb_verify_data),
        .display_valid   (fb_verify_valid),
        .vsync_pulse     (vsync_pulse),   // [task_026 第三步] 消隐提交窗口
        .frame_write_done(fb_done),
        .active_buffer   (fb_active_buffer)
    );

    assign init_done     = fb_init_done;
    assign active_buffer = fb_active_buffer;
    // verify 只在非加载(提交后)时被视为有效读回; 加载中(后台缓冲未定) gating
    // [M1a 偏差 §2.2] 原 verify_* 输出保留 012 原语义; 显示链使用新引出的
    // d_display_* = 未 gating 的 fb_verify_valid / fb_verify_data。
    assign verify_data   = fb_verify_data;
    assign verify_valid  = fb_verify_valid && !load_busy;
    assign d_display_data      = fb_verify_data;
    assign d_display_valid     = fb_verify_valid;
    assign d_frame_write_done  = fb_done;

    // [task_026 第三步] 源尺寸引出: converter 尺寸寄存器在 VALIDATE 拍锁存、
    // 保持到下一次 convert_start(残留语义见 ST_HDR 注释), 顶层在帧提交拍
    // (active_buffer 翻转)采样 => 与该帧图像严格同批。
    assign src_w_out           = conv_image_width;
    assign src_h_out           = conv_image_height;

    // ========================================================================
    // 输入侧: align_shim -> Task005 converter
    // ========================================================================
    wire [31:0] shim_data;
    wire        shim_valid;

    // FLUSH 后期: FIFO 已空, 喂 dummy 字 (0) 推动 converter 走到 DONE-IDLE
    wire flush_dummy = (state == ST_FLUSH) && (flush_stage == 2'd1);

    bmp_stream_align_shim u_shim (
        .clk         (ctrl_clk),
        .rst_n       (rst_n),
        .stream_start(conv_start_pulse),
        .raw_data    (flush_dummy ? 32'd0 : in_fifo_dout),
        .raw_valid   (in_fifo_rd),
        .align_ready (1'b1),
        .align_data  (shim_data),
        .align_valid (shim_valid)
    );

    // converter 接口
    wire        conv_busy, conv_done;
    wire        conv_format_error, conv_size_error;
    // (conv_image_*/conv_pixel_* 前向声明已提前至像素 FIFO 段, 消 HDL-5373)

    bmp24_to_rgb565_converter #(.MAX_WIDTH(16'd4096), .MAX_HEIGHT(16'd4096))
        u_conv (
            .clk          (ctrl_clk),
            .rst_n        (rst_n),
            .convert_start(conv_start_pulse),
            .convert_busy (conv_busy),
            .convert_done (conv_done),
            .format_error (conv_format_error),
            .size_error   (conv_size_error),
            .data_in      (shim_data),
            .data_valid   (shim_valid),
            .image_width  (conv_image_width),
            .image_height (conv_image_height),
            .pixel_out    (conv_pixel_out),
            .pixel_valid  (conv_pixel_valid),
            .pixel_x      (conv_pixel_x),
            .pixel_y      (conv_pixel_y)
        );

    // ========================================================================
    // 端口级 converter 状态推断 (TD 综合不支持层级引用 u_conv.state)
    //   conv_idle           ⇔ converter state==IDLE  (busy:1..4, done:5)
    //   conv_validate_done  ⇔ converter state>=WAIT_PIXEL_DATA(3'd3) 首拍:
    //                         shim 向 converter 送满 14 字(54字节头)后第 3 拍。
    //                         第14字在拍C0被converter采样(C0结束 feed_cnt=14),
    //                         C1=PARSE收尾, C2=VALIDATE(该拍结束锁存几何并
    //                         转 state 3/5), C3 起 va->vb 两级置位且几何为新值,
    //                         与原条件 state∈{3,4,5} 在同一拍成立、同一拍求值。
    // ========================================================================
    wire conv_idle = !conv_busy && !conv_done;

    reg [7:0] feed_cnt;
    reg       conv_va, conv_vb;
    wire      conv_validate_done = conv_vb;
    always @(posedge ctrl_clk or negedge rst_n) begin
        if (!rst_n) begin
            feed_cnt <= 8'd0;
            conv_va  <= 1'b0;
            conv_vb  <= 1'b0;
        end else if (conv_start_pulse) begin
            feed_cnt <= 8'd0;
            conv_va  <= 1'b0;
            conv_vb  <= 1'b0;
        end else begin
            if (shim_valid && (feed_cnt != 8'd255))
                feed_cnt <= feed_cnt + 8'd1;
            conv_va <= conv_va || (feed_cnt >= 8'd14);
            conv_vb <= conv_vb || conv_va;
        end
    end

    // ========================================================================
    // top_down 观测器 (并行, 不修改 Task005; wire 已前向声明)
    // ========================================================================
    bmp_top_down_observer u_obs (
        .clk         (ctrl_clk),
        .rst_n       (rst_n),
        .stream_start(conv_start_pulse),
        .data_in     (data_in),
        .accept      (stream_ready && data_valid),
        .top_down    (top_down)
    );

    // ========================================================================
    // 节流: 距上次喂入拍数 (>=4 满足 Task005 单字节处理约束)
    // ========================================================================
    reg [3:0] gap;
    wire feed_window = (state == ST_HDR) || (state == ST_LOAD);

    // FLUSH 后期: FIFO 已空, 喂 dummy 字 (0) 推动 converter 走到 DONE→IDLE

    // converter最小字距保留；resampler行缓冲隔离输入与成行输出。
    // 不能因像素FIFO near_full停读：FAT32每64拍发字且不接收背压，停读会丢字。
    assign in_fifo_rd = flush_dummy ? (gap >= 4'd4)
                        : (((state == ST_FLUSH) && !in_fifo_empty) ||
                           (feed_window && !in_fifo_empty && (gap >= 4'd4)));

    always @(posedge ctrl_clk or negedge rst_n) begin
        if (!rst_n) begin
            gap <= 4'd0;
        end else if (in_fifo_rd) begin
            gap <= 4'd0;
        end else if (gap < 4'd15) begin
            gap <= gap + 4'd1;
        end
    end

    // ========================================================================
    // 主状态机 (含像素计数: 必须与状态机同一 always 块, TD 不接受 reg 多驱动)
    // ========================================================================
    always @(posedge ctrl_clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= ST_IDLE;
            load_busy        <= 1'b0;
            load_done        <= 1'b0;
            format_error     <= 1'b0;
            size_error       <= 1'b0;
            stream_error     <= 1'b0;
            conv_start_pulse <= 1'b0;
            size_ok          <= 1'b0;
            size_eval        <= 1'b0;
            conv_done_seen   <= 1'b0;
            str_done_seen    <= 1'b0;
            image_height_lock<= 10'd0;
            res_start_pulse  <= 1'b0;
            res_done_seen    <= 1'b0;
            commit_wd        <= 20'd0;
            trunc_cnt        <= 16'd0;
            flush_stage      <= 2'd0;
            fb_done_seen     <= 1'b0;
        end else begin
            // 脉冲默认清零 (load_done 单拍; 错误锁存至下满 stream_start)
            load_done        <= 1'b0;
            conv_start_pulse <= 1'b0;
            res_start_pulse  <= 1'b0;

            // 像素计数递增 (ST_IDLE 启动分支在其后的 case 中重写为 0, 后者胜)
            if (px_wr)
                pixel_cnt <= pixel_cnt + 21'd1;

            // 错误标志锁存: ST_IDLE 收到新 stream_start 时清除
            if (state == ST_IDLE && stream_start) begin
                format_error <= 1'b0;
                size_error   <= 1'b0;
                stream_error <= 1'b0;
            end

            // Task007 帧翻转可能在 ST_LOAD 后期就发生 (前流残留计数),
            // 全局捕捉, WAIT_COMMIT 统一判定。
            if (fb_done && load_busy) fb_done_seen <= 1'b1;
            if (res_frame_done && load_busy) res_done_seen <= 1'b1;

            case (state)
                // ------------------------------------------------------------
                ST_IDLE: begin
                    // converter 必须已回 IDLE (FLUSH 后可能仍在排空), 否则
                    // convert_start 会被卡在 3/4 的 converter 无视
                    if (stream_start && !load_busy && conv_idle) begin
                        state            <= ST_WAIT_INIT;
                        load_busy        <= 1'b1;
                        conv_start_pulse <= 1'b1;
                        size_ok          <= 1'b0;
                        size_eval        <= 1'b0;
                        conv_done_seen   <= 1'b0;
                        str_done_seen    <= 1'b0;
                        pixel_cnt        <= 21'd0;
                        trunc_cnt        <= 16'd0;
                        flush_stage      <= 2'd0;
                        fb_done_seen     <= 1'b0;
                        res_done_seen    <= 1'b0;
                        commit_wd        <= 20'd0;
                    end
                end

                // ------------------------------------------------------------
                ST_WAIT_INIT: begin
                    // 不喂 converter; 数据进输入FIFO打底, 满则背压上游
                    if (fb_init_done) state <= ST_HDR;
                end

                // ------------------------------------------------------------
                ST_HDR: begin
                    // 尺寸/格式/流错误评估: 以 converter 头部完成为准
                    // (conv_validate_done: 送满14字后第2拍, VALIDATE 已完成,
                    // 尺寸/错误寄存器为新流的有效值, 见上方端口级推断注释)。
                    // 不能只看 conv_image_width!=0: converter 的尺寸寄存器在
                    // convert_start 后不清零, 会残留上一张图的值。
                    if (stream_done) str_done_seen <= 1'b1;
                    if (!size_eval && conv_validate_done) begin
                        size_eval        <= 1'b1;
`ifdef DBG_HDR_EVAL
                        $display("[HDR] t=%0t eval cw=%0d ch=%0d cfmt=%b csz=%b",
                                 $time, conv_image_width, conv_image_height,
                                 conv_format_error, conv_size_error);
`endif
                        image_height_lock<= FRAME_HEIGHT[9:0];  // [task_026] 目标高 480
                        if (conv_format_error || conv_size_error) begin
                            // 格式错误 / 源尺寸超限(>4096 或 0): converter 判定
                            format_error <= 1'b1;
                            size_ok      <= 1'b0;
                            load_busy    <= 1'b0;
                            state        <= ST_FLUSH;
                        end else begin
                            // [task_026] 任意 <=4096 尺寸放行(适配层负责缩放);
                            // 尺寸不匹配不再报 size_error —— 由 resampler 等比
                            // 缩放/黑边消化; 真正 >4096 的超限由 conv_size_error 拦截。
                            size_ok           <= 1'b1;
                            res_start_pulse   <= 1'b1;
                            state             <= ST_LOAD;
                        end
                    end
                    // 流提前结束: converter 已回 IDLE 且从未完成 VALIDATE -> 截断
                    else if (!size_eval && conv_idle &&
                             str_done_seen) begin
                        stream_error <= 1'b1;
                        load_busy    <= 1'b0;
                        state        <= ST_FLUSH;
                    end
                end

                // ------------------------------------------------------------
                ST_LOAD: begin
                    if (stream_done) str_done_seen <= 1'b1;
                    if (conv_done) begin
                        conv_done_seen <= 1'b1;
                        state          <= ST_WAIT_COMMIT;
                    end
                    // 截断死锁保护: 流已结束+输入FIFO空, converter 持续在转换态
                    // 等更多输入(永不 done)。需持续 TRUNC_WIN 拍才判定,
                    // 避免正常排空瞬态误判。
                    else if (str_done_seen && in_fifo_empty &&
                             conv_validate_done && conv_busy &&
                             !conv_done) begin
                        if (trunc_cnt == 16'd64) begin
                            stream_error <= 1'b1;
                            load_busy    <= 1'b0;
                            state        <= ST_FLUSH;
                        end else begin
                            trunc_cnt <= trunc_cnt + 16'd1;
                        end
                    end else begin
                        trunc_cnt <= 16'd0;
                    end
                end

                // ------------------------------------------------------------
                ST_WAIT_COMMIT: begin
                    // 像素经 pipe 寄存后才提交给 u_fb, 排空条件必须含
                    // pipe 空, 否则最后一像素仍压在 pipe 时会提前判定
                    // "已排空"并提交, u_fb 写队列缺一像素(TC-03 (63,0)=X 根因)
                    // 排空条件用适配器 out_empty(FIFO+pipe 均空):
                    // converter 完成 + 像素流全排空 → 才允许提交判定
                    // [task_026] 还需 res_done_seen: 源流长于目标流时, 尾行/
                    //   底黑边可能尚未发完即遇 FIFO 瞬排空, 会提前判定排空。
                    // 输出链空闲判据连续2^20拍成立时报告停滞。
                    // 首帧板上错误归因须依据首次触发分支和上游字流证据。
                    if (conv_done_seen && !res_done_seen) begin
                        if (px_starve) begin
                            if (commit_wd == 20'hFFFFF) begin
                                stream_error <= 1'b1;
                                load_busy    <= 1'b0;
                                state        <= ST_FLUSH;
                            end else begin
                                commit_wd <= commit_wd + 20'd1;
                            end
                        end else begin
                            commit_wd <= 20'd0;   // 输出链有活动 => 清零重启
                        end
                    end
                    if (conv_done_seen && res_done_seen && pix_out_empty) begin
                        // converter 已完成且像素FIFO排空;
                        // 像素数 == 帧大小 且 帧翻转已发生 -> 提交成功,
                        // 像素数不足 -> 提前结束(截断), 不提交
                        if (pixel_cnt == FRAME_PIXELS[20:0] &&
                            (fb_done_seen || fb_done)) begin
                            load_done <= 1'b1;
                            load_busy <= 1'b0;
                            state     <= ST_DONE;
                        end else if (pixel_cnt != FRAME_PIXELS[20:0]) begin
                            stream_error <= 1'b1;
                            load_busy    <= 1'b0;
                            state        <= ST_FLUSH;
                        end
                    end
                end

                // ------------------------------------------------------------
                ST_DONE: begin
                    load_done <= 1'b0;
                    state     <= ST_IDLE;
                end

                // ------------------------------------------------------------
                ST_FLUSH: begin
                    // 错误后清理: 先排空输入 FIFO 残渣, 再喂 dummy 字推动
                    // converter 走完 (converter 只在 IDLE 收 convert_start,
                    // 卡在 3/4 会吞掉下一流的 start), 直到其回 IDLE。
                    if (!in_fifo_empty) begin
                        flush_stage <= 2'd0;
                    end else if (conv_idle) begin
                        state <= ST_IDLE;
                    end else begin
                        flush_stage <= 2'd1;
                    end
                end

                default: state <= ST_IDLE;
            endcase

            // 截断检测已移入 ST_WAIT_COMMIT (等 converter done 后按像素数判定),
            // 不再在此处过早触发, 避免 stream_done 后 converter 仍在排空被误判。
        end
    end

endmodule