`timescale 1ns/1ps
// ============================================================================
// bmp_selective_load_top — task_046 新增: 选择性加载参考集成顶层
//   把三新模块 + 复用件串成完整选择路径(供集成方 m1a_top 接线与验证 bit 用):
//
//     已验证挂载缓存或独立卷扫描(参数选择)
//       → fat32_interval_reader(区间: 头 [0,54) → [54,bfo)(可选) → 行区间)
//       → bmp_row_planner(几何+区间流) / bmp_selective_row_feeder(解码)
//       → bmp_row_order_adapter(行序+弹性, 既有件) → fb 写口
//
// 扇区口在外部接 sd_arbiter s2(顶层仲裁; 扫描/区间扫描/区间=时序互斥双源,
// 本层 OR 选择, 与 fat32_lite 内 scan/arb 二选一模式同构)。
// 输出签名 = resampler 输出经 row_adapter 后形态(直接替换装配点);
// sel_fallback=1 ⇒ 计划不支持或格式不符, 调用方改走旧连续流路径。
// ============================================================================
module bmp_selective_load_top #(parameter USE_MOUNT_CACHE=1'b0) (
    input  wire        clk,
    input  wire        rst_n,

    input wire cache_ready,input wire [3:0] cache_pic_valid,input wire [31:0] cache_cluster,cache_size,
    input wire [7:0] cache_spc,input wire [31:0] cache_fat_lba,cache_data_lba,cache_max_cluster,
    input  wire        sel_start,      // 单拍: 开始装载
    input  wire [1:0]  sel_index,      // 装载槽(0..3)
    output reg         sel_busy,
    output reg         sel_done,       // feeder frame_done + 读闭拢 单拍帧就绪
    output reg  [7:0]  sel_error,
    output reg         sel_fallback,   // 需回退旧路径(plan_supported=0)

    // 扇区事务口(对外至仲裁)
    output wire        sector_req,
    output wire [31:0] sector_lba,
    input  wire        sector_busy,
    input  wire        sector_valid,
    input  wire [7:0]  sector_byte,
    input  wire [8:0]  sector_byte_index,
    input  wire        sector_done,
    input  wire [7:0]  sector_error,

    // fb 写口(row_adapter 输出形)
    output wire [15:0] pix_data,
    output wire [10:0] pix_x,
    output wire [9:0]  pix_y,
    output wire        pix_valid,
    input  wire        pix_ready,

    // 本帧几何元数据(装载后稳定, 供槽登记/字幕: 源尺寸=feeder 头解析,
    // 内容尺寸=planner 几何, 与旧路径 resampler/src 引出同值)
    output wire [15:0] sel_src_w,
    output wire [15:0] sel_src_h,
    output wire [15:0] sel_cw,
    output wire [15:0] sel_ch,

    // 行适配真实排空(FIFO+pipe 均空): sel_mode 的适用跨区与尾流消隐期
    output wire        adapter_empty
);
    // ========================================================================
    // 控制 FSM
    // ========================================================================
    localparam [3:0]
        W_IDLE   = 4'd0,
        W_SCAN   = 4'd1,
        W_HDR    = 4'd2,
        W_HDRSK  = 4'd3,   // bfOffBits>54: 补读丢弃[54,bfo)
        W_PLAN   = 4'd4,
        W_ROWS   = 4'd5,
        W_FIN    = 4'd6,
        W_ERR    = 4'd7,
        W_FB     = 4'd8;   // fallback 置位(回 IDLE)

    reg [3:0]  wstate;
    reg [1:0]  idx_r;
    localparam [7:0] E_NONE = 8'h00, E_SCAN = 8'h50;

    // ========================================================================
    // 卷扫描器(复用既有件)
    // ========================================================================
    reg        scan_start;
    wire       scan_busy, scan_done;
    wire [7:0] scan_fs_error, scan_spc;
    wire [31:0] scan_fat_start, scan_data_start, scan_max_cluster;
    wire [3:0] scan_resource_valid;
    wire [31:0] res0_cluster, res1_cluster, res2_cluster, res3_cluster;
    wire [31:0] res0_size, res1_size, res2_size, res3_size;

    // 扫描器扇区口与其余源在层内 OR(扫描期独占, 区间期独占 — 控制 FSM 保证)
    wire        scan_sector_req;
    wire [31:0] scan_sector_lba;

    generate if(USE_MOUNT_CACHE)begin: shared_mount
        reg done_r;
        always @(posedge clk or negedge rst_n)begin
            if(!rst_n)done_r<=1'b0;else done_r<=scan_start;
        end
        assign scan_done=done_r;assign scan_busy=1'b0;
        assign scan_fs_error=cache_ready?8'd0:E_SCAN;
        assign scan_spc=cache_spc;assign scan_fat_start=cache_fat_lba;
        assign scan_data_start=cache_data_lba;assign scan_max_cluster=cache_max_cluster;
        assign scan_resource_valid=cache_pic_valid;
        assign res0_cluster=cache_cluster;assign res1_cluster=cache_cluster;
        assign res2_cluster=cache_cluster;assign res3_cluster=cache_cluster;
        assign res0_size=cache_size;assign res1_size=cache_size;
        assign res2_size=cache_size;assign res3_size=cache_size;
        assign scan_sector_req=1'b0;assign scan_sector_lba=32'd0;
    end else begin: independent_mount
    fat32_volume_scanner u_scan (
        .clk(clk), .rst_n(rst_n),
        .scan_start(scan_start), .scan_busy(scan_busy), .scan_done(scan_done),
        .fs_error(scan_fs_error), .partition_lba(),
        .sectors_per_cluster(scan_spc),
        .fat_start_lba(scan_fat_start), .data_start_lba(scan_data_start),
        .max_cluster(scan_max_cluster),
        .resource_valid(scan_resource_valid),
        .resource0_cluster(res0_cluster), .resource1_cluster(res1_cluster),
        .resource2_cluster(res2_cluster), .resource3_cluster(res3_cluster),
        .resource0_size(res0_size), .resource1_size(res1_size),
        .resource2_size(res2_size), .resource3_size(res3_size),
        .lrc_entry_valid(),.lrc_entry_slot(),.lrc_entry_cluster(),.lrc_entry_size(),
        .wav_valid(), .wav0_first_cluster(), .wav1_first_cluster(),
        .wav2_first_cluster(), .wav3_first_cluster(),
        .wav0_size(), .wav1_size(), .wav2_size(), .wav3_size(),
        .sector_req(scan_sector_req), .sector_lba(scan_sector_lba),
        .sector_busy(sector_busy), .sector_valid(sector_valid),
        .sector_byte(sector_byte), .sector_byte_index(sector_byte_index),
        .sector_done(sector_done), .sector_error(sector_error)
    );
    end endgenerate

    // 槽参数(sel 装载期间锁存)
    wire [31:0] slot_cluster = (idx_r == 2'd0) ? res0_cluster :
                               (idx_r == 2'd1) ? res1_cluster :
                               (idx_r == 2'd2) ? res2_cluster : res3_cluster;
    wire [31:0] slot_size    = (idx_r == 2'd0) ? res0_size :
                               (idx_r == 2'd1) ? res1_size :
                               (idx_r == 2'd2) ? res2_size : res3_size;
    wire        slot_valid   = scan_resource_valid[idx_r];

    // ========================================================================
    // 区间读取器
    // ========================================================================
    reg         hdr_req_valid;
    reg  [31:0] hdr_req_off, hdr_req_len;
    wire        rd_req_ready;
    wire [31:0] ival_off, ival_len;
    wire [9:0]  ival_row;
    wire        ival_valid, ival_last, plan_done;

    // 区间读取器请求源: 头阶段 = wrapper; 行阶段 = planner(W_ROWS 起互斥)
    wire        rd_req_valid = (wstate == W_ROWS) ? ival_valid : hdr_req_valid;
    wire [31:0] rd_req_off   = (wstate == W_ROWS) ? ival_off   : hdr_req_off;
    wire [31:0] rd_req_len   = (wstate == W_ROWS) ? ival_len   : hdr_req_len;

    wire        rd_byte_valid, rd_ival_done;
    wire [7:0]  rd_byte, rd_error;
    wire        feeder_byte_ready;
    wire        rd_sector_req;
    wire [31:0] rd_sector_lba;

    fat32_interval_reader u_reader (
        .clk(clk), .rst_n(rst_n),
        .spc(scan_spc), .fat_start_lba(scan_fat_start),
        .data_start_lba(scan_data_start), .max_cluster(scan_max_cluster),
        .file_first_cluster(slot_cluster), .file_size(slot_size),
        .req_valid(rd_req_valid), .req_ready(rd_req_ready),
        .req_offset(rd_req_off), .req_length(rd_req_len),
        .byte_valid(rd_byte_valid), .byte_data(rd_byte),
        .byte_ready(feeder_byte_ready),
        .ival_done(rd_ival_done), .error(rd_error),
        .sector_req(rd_sector_req), .sector_lba(rd_sector_lba),
        .sector_busy(sector_busy), .sector_valid(sector_valid),
        .sector_byte(sector_byte), .sector_byte_index(sector_byte_index),
        .sector_done(sector_done), .sector_error(sector_error)
    );

    // 层内扇区口 OR(W_SCAN 用扫描器, 其余用读取器; 控 FSM 保证互斥)
    assign sector_req = (wstate == W_SCAN) ? scan_sector_req : rd_sector_req;
    assign sector_lba = (wstate == W_SCAN) ? scan_sector_lba : rd_sector_lba;

    // ========================================================================
    // 行规划器
    // ========================================================================
    reg         plan_start;
    wire        plan_valid, plan_supported;
    wire [15:0] pcw, pch, pxoff, pswin;
    wire [10:0] plft;
    wire [9:0]  ptop, pbot;
    wire [31:0] row_bytes;

    // 头解析(feeder 内锁存)
    wire [15:0] hdr_w, hdr_h;
    wire        hdr_topdown, hdr_fmtok, hdr_valid, geom_latch;
    wire [31:0] hdr_bfo;

    bmp_row_planner u_plan (
        .clk(clk), .rst_n(rst_n),
        .start(plan_start),
        .src_w(hdr_w), .src_h(hdr_h), .bfOffBits(hdr_bfo),
        .file_size(slot_size), .fmt_hdrok(hdr_fmtok),
        .plan_valid(plan_valid), .plan_supported(plan_supported),
        .content_w(pcw), .content_h(pch), .x_off(pxoff), .src_win(pswin),
        .lft(plft), .top_black(ptop), .bot_black(pbot), .row_bytes(row_bytes),
        .ival_valid(ival_valid), .ival_ready(rd_req_ready && (wstate == W_ROWS)),
        .ival_offset(ival_off), .ival_length(ival_len),
        .ival_row(ival_row), .ival_last(ival_last), .plan_done(plan_done)
    );

    // ========================================================================
    // 行解码供流器 + 行序适配(既有)
    // ========================================================================
    reg          fs_start_hold;
    // fs_start 电平保持: 装载 1 结束后 feeder 停在 F_FIN, 单拍脉冲会被
    // F_FIN->F_IDLE 过渡吃掉(F_IDLE 再等不到第二拍, 装载 2 挂死)。
    // 保持至 feeder busy 且旧头已清时再撤销。
    wire         feeder_started = feeder_busy && !hdr_valid;
    // 保持启动信号直达feeder, F_GEOM回退停泊态也须受理新文件。
    wire         fs_start = fs_start_hold;
    wire  [7:0] feed_error;
    wire        feed_frame_done, feeder_busy;
    wire [10:0] fo_x;
    wire [9:0]  fo_y;
    wire [15:0] fo_pix;
    wire        fo_valid;
    wire        adapter_full, adapt_valid;
    wire [15:0] adapt_data;
    wire [10:0] adapt_x;
    wire [9:0]  adapt_y;

    reg hdr_skip_pulse;
    bmp_selective_row_feeder u_feed (
        .clk(clk), .rst_n(rst_n),
        .fs_start(fs_start),
        .hdr_skip(hdr_skip_pulse),
        .byte_valid(rd_byte_valid), .byte_data(rd_byte),
        .byte_ready(feeder_byte_ready),
        .ival_done(rd_ival_done), .rd_error(rd_error),
        .hdr_w(hdr_w), .hdr_h(hdr_h), .hdr_topdown(hdr_topdown),
        .hdr_bfo(hdr_bfo), .hdr_fmtok(hdr_fmtok), .hdr_valid(hdr_valid),
        .geom_latch(geom_latch),
        .content_w(pcw), .content_h(pch), .src_win(pswin),
        .lft(plft), .top_black(ptop), .bot_black(pbot),
        .out_x(fo_x), .out_y(fo_y), .out_pixel(fo_pix), .out_valid(fo_valid),
        .dn_full(adapter_full),
        .frame_done(feed_frame_done), .error(feed_error), .busy(feeder_busy)
    );
    assign geom_latch = plan_valid && plan_supported;

    bmp_row_order_adapter u_adapt (
        .clk(clk), .rst_n(rst_n),
        .top_down(hdr_topdown), .image_height(10'd480),
        .in_data(fo_pix), .in_x(fo_x), .in_y(fo_y), .in_valid(fo_valid),
        .out_data(adapt_data), .out_x(adapt_x), .out_y(adapt_y),
        .out_valid(adapt_valid), .out_ready(pix_ready),
        .fifo_full(adapter_full), .near_full(), .out_empty(adapter_empty)
    );
    assign pix_data  = adapt_data;
    assign pix_x     = adapt_x;
    assign pix_y     = adapt_y;
    assign pix_valid = adapt_valid;
    assign sel_src_w = hdr_w;
    assign sel_src_h = hdr_h;
    assign sel_cw    = pcw;
    assign sel_ch    = pch;

    // ========================================================================
    // 控制 FSM
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wstate        <= W_IDLE;
            idx_r         <= 2'd0;
            sel_busy      <= 1'b0;
            sel_done      <= 1'b0;
            sel_error     <= E_NONE;
            sel_fallback  <= 1'b0;
            scan_start    <= 1'b0;
            hdr_req_valid <= 1'b0;
            hdr_req_off   <= 32'd0;
            hdr_req_len   <= 32'd0;
            plan_start    <= 1'b0;
            hdr_skip_pulse <= 1'b0;
            fs_start_hold <= 1'b0;
        end else begin
            sel_done      <= 1'b0;
            scan_start    <= 1'b0;
            hdr_req_valid <= 1'b0;
            plan_start    <= 1'b0;
            hdr_skip_pulse <= 1'b0;
            // sel_fallback 不在此清: 保持位(见 W_IDLE)
            // fs_start_hold 自持: 至 feeder 进入 F_HDR 且清旧头才清;
            // feeder 报错则撤箭(勿在错误态重启)
            if (fs_start_hold && feeder_started) fs_start_hold <= 1'b0;
            if (feed_error != 8'd0) fs_start_hold <= 1'b0;

            case (wstate)
                W_IDLE: begin
                    sel_busy <= 1'b0;
                    if (sel_start) begin
                        idx_r    <= sel_index;
                        sel_busy <= 1'b1;
                        sel_error <= E_NONE;
                        // sel_fallback 为保持位: 此处清(新装载), 供顶层/TB
                        // 在回退发生后的任意时刻可靠采样
                        sel_fallback <= 1'b0;
                        scan_start <= 1'b1;
                        wstate   <= W_SCAN;
                    end
                end
                W_SCAN: begin
                    if (scan_done) begin
                        if (scan_fs_error != 8'd0 || !slot_valid) begin
                            sel_error <= E_SCAN;
                            wstate    <= W_ERR;
                        end else begin
                            // 保持 fs_start 至 feeder 进入 F_HDR(见上注)
                            fs_start_hold <= 1'b1;
                            wstate   <= W_HDR;
                        end
                    end
                end
                W_HDR: begin
                    // 头区间 [0,54)
                    if (!hdr_req_valid && rd_req_ready) begin
                        hdr_req_off   <= 32'd0;
                        hdr_req_len   <= 32'd54;
                        hdr_req_valid <= 1'b1;
                    end
                    if (rd_ival_done) begin
                        if (hdr_bfo > 32'd54) begin
                            hdr_skip_pulse <= 1'b1;
                            wstate         <= W_HDRSK;
                        end else begin
                            plan_start <= 1'b1;
                            wstate     <= W_PLAN;
                        end
                    end
                end
                W_HDRSK: begin
                    // 补读 [54, bfo)(feeder F_GEOM 下不消费, 交弃:
                    // byte_ready 口仍由 feeder 决定, byte_ready 关闭时
                    // reader 内部弹性满后将恒堵 ⇒ 由 feeder 的 byte_ready
                    // 承包: feeder 在 F_GEOM 之前不消费, 这里直接短路
                    // 丢弃字节(该区间不会进 feeder 视窗)
                    if (!hdr_req_valid && rd_req_ready) begin
                        hdr_req_off   <= 32'd54;
                        hdr_req_len   <= hdr_bfo - 32'd54;
                        hdr_req_valid <= 1'b1;
                    end
                    if (rd_ival_done) begin
                        plan_start <= 1'b1;
                        wstate     <= W_PLAN;
                    end
                end
                W_PLAN: begin
                    if (plan_valid) begin
                        if (plan_supported) begin
                            wstate <= W_ROWS;
                        end else begin
                            sel_fallback <= 1'b1;
                            wstate       <= W_FB;
                        end
                    end
                end
                W_ROWS: begin
                    if (feed_error != 8'd0) begin
                        // 错误可见: 槽不提交(无 sel_done), 错误码透传
                        sel_error <= feed_error;
                        sel_busy  <= 1'b0;
                        wstate    <= W_ERR;
                    end else if (fdn_seen && plan_done_seen) begin
                        // fdn_seen: frame_done 粘性锁存(sel_start 清) —— 单拍
                        // 脉冲直接采样存在与 plan_done_seen 置位时序的错窗
                        sel_done <= 1'b1;
                        sel_busy <= 1'b0;
                        wstate   <= W_FIN;
                    end
                end
                W_FIN: wstate <= W_IDLE;
                W_ERR: begin
                    sel_busy <= 1'b0;
                    if (sel_start) begin
                        sel_busy <= 1'b1;
                        sel_error <= E_NONE;
                        idx_r <= sel_index;
                        scan_start <= 1'b1;
                        wstate <= W_SCAN;
                    end
                end
                W_FB: begin
                    sel_busy <= 1'b0;
                    wstate   <= W_IDLE;   // 由调用方判定回退
                end
                default: wstate <= W_IDLE;
            endcase
        end
    end

    // plan_done_seen(plan_done 单拍可能先于 feeder frame_done)
    reg plan_done_seen;
    reg fdn_seen;                       // feeder frame_done 粘性锁存
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            plan_done_seen <= 1'b0;
            fdn_seen       <= 1'b0;
        end else begin
            plan_done_seen <= sel_start ? 1'b0 :
                              (plan_done_seen | plan_done);
            fdn_seen       <= sel_start ? 1'b0 :
                              (fdn_seen | feed_frame_done);
        end
    end

endmodule
