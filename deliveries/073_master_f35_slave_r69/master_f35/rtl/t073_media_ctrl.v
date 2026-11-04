`timescale 1ns / 1ps
// t073_media_ctrl：图片、视频、音乐与FAT授权控制，支持启动视频、前台图片及后台缩略图加载。
module t073_media_ctrl #(
    parameter integer ACMD41_TRIES = 4095,
    parameter integer EXT_AW       = 7,
    parameter [31:0]  SEC_CYCLES   = 32'd50_000_000,      // 1s @50MHz
    parameter [3:0]   MAX_PIC      = 4'd8,
    parameter [3:0]   MAX_VID      = 4'd10
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [2:0]  sd_cfg,
    input  wire [1:0]  tgt_mode,         // 0 图片 2 视频(电平, 已消抖)
    input  wire        mode_eff,         // video_mem_core 已提交的显示模式
    input  wire        photo_next,       // 单拍
    input  wire        photo_prev,
    input  wire        video_next,
    input  wire        video_prev,
    input  wire        reload_req,
    input  wire        any_key,          // 单拍: 任意按键(跳过启动动画)
    input  wire [15:0] v_shown,          // 视频已上屏帧数(页管理)
    input  wire [5:0]  period_s,         // 自动轮播周期 1..60s, 0 = 关
    input  wire        photo_hold,       // 播放器页: 背景图不自动轮播, 改为随切歌换图
    input  wire [2:0]  trans_cfg,        // 0 关 1..4 固定模式 7 轮换
    input  wire        wall_toggle,      // 单拍: 全屏 <-> 图墙
    input  wire        zoom_step,        // 单拍: 全屏缩放级别 +1(循环)
    input  wire        blank_busy,       // 黑缩略填充进行中
    output reg         blank_start,      // 单拍: 为当前槽写黑缩略
    output wire [2:0]  thumb_slot,       // 本次读图/填充的缩略槽
    output reg         wall_mode,
    output wire [1:0]  wall_cell,        // 焦点在本组内的格号
    output reg  [1:0]  zoom,
    output wire [3:0]  focus_idx,
    output wire        bg_load,          // 当前加载为后台缩略(不上屏)
    output wire        booting,          // 启动动画阶段(叠加层暂停绘制)
    // 音乐
    input  wire        music_on,
    input  wire        wav_next, wav_previous,
    input  wire        aud_room,         // 音频缓冲可再收一次音乐读(ctrl 域)
    input  wire        audio_drained_async, source_drained_async,
    output reg         wav_selected, wav_start,
    output wire        media_flush, media_eof,
    output reg         wav_error,
    output reg  [3:0]  wav_error_code,
    output reg  [1:0]  wav_slot,
    output reg         session_toggle,
    output wire [1:0]  wav_state,        // 0 关 1 播放 2 准备 3 无可播曲目
    output wire [31:0] wav_total,        // 当前曲目样本总数
    output wire        wav_hdr,          // 当前曲目文件头已解析(wav_total 有效)
    output reg  [3:0]  vid_idx,
    // 视频
    output wire        v_clear,          // 视频写通路/页管理保持清空
    output wire [1:0]  v_fmt,            // 1 RGB565 2 RGB332
    output wire        v_has_audio,
    output wire        mode_video,
    output wire        v_valid,
    output wire [31:0] v_data,
    input  wire        v_ready,
    output wire [5:0]  fps,
    output wire        aud_valid,
    output wire [31:0] aud_data,
    output wire        aud_first,
    input  wire        aud_ready,
    output wire        has_audio,
    // 图片
    output wire        f_valid,          // 文件字流 -> bmp_page_loader
    output wire [31:0] f_data,
    input  wire        f_ready,
    output reg         ld_start,         // 单拍: 新 BMP 开始
    input  wire        ld_done,
    input  wire        ld_err,
    input  wire        img_idle,
    output reg  [1:0]  img_page,
    output reg         show_req,
    output reg  [1:0]  show_page,
    output reg  [2:0]  show_mode,
    input  wire        trans_busy,

    output wire        sd_clk,
    inout  wire        sd_cmd,
    input  wire [3:0]  sd_dat,

    output wire [7:0]  status,           // {init_err, hs, video, slide, no_media, hdr_err, ld_err_seen, reloading}
    output reg  [3:0]  pic_idx
);
    // ---------------- SD 主机与端口复用 ----------------
    wire        init_done, init_err, hs_mode, st_busy, st_done, st_err;
    wire [3:0]  init_stage, pool_count;
    wire [31:0] card_blocks, pool_rdata;
    wire [15:0] st_blocks;
    reg  [1:0]  own;
    reg         sd_reinit;               // 重载期间保持, 由主控寄存器输出

    wire        fs_start, vs_start, rs_start, fs_rel, vs_rel, rs_rel;
    wire [31:0] fs_lba, vs_lba, rs_lba;
    wire [15:0] fs_cnt, vs_cnt, rs_cnt;
    wire [6:0]  fs_ra, vs_ra, rs_ra;

    sd_host #(.ACMD41_TRIES(ACMD41_TRIES)) u_sd (
        .clk(clk), .rst_n(rst_n), .cfg(sd_cfg), .reinit(sd_reinit),
        .init_done(init_done), .init_err(init_err), .init_stage(init_stage), .hs_mode(hs_mode),
        .card_blocks(card_blocks),
        .st_start(own == 2'd0 ? fs_start : own == 2'd1 ? vs_start : rs_start),
        .st_lba  (own == 2'd0 ? fs_lba   : own == 2'd1 ? vs_lba   : rs_lba),
        .st_count(own == 2'd0 ? fs_cnt   : own == 2'd1 ? vs_cnt   : rs_cnt),
        .st_busy(st_busy), .st_done(st_done), .st_err(st_err), .st_blocks(st_blocks),
        .pool_count(pool_count),
        .pool_raddr(own == 2'd0 ? fs_ra : own == 2'd1 ? vs_ra : rs_ra),
        .pool_rdata(pool_rdata),
        .pool_release(own == 2'd0 ? fs_rel : own == 2'd1 ? vs_rel : rs_rel),
        .sd_clk(sd_clk), .sd_cmd(sd_cmd), .sd_dat(sd_dat));

    // ---------------- FAT32 查找(授权 fg: 0 主控 1 音乐) ----------------
    reg         fg;
    reg         f_start_m, f_start_u;
    reg  [87:0] f_name_m, f_name_u;
    wire        f_busy, f_done;
    wire [2:0]  f_err;
    wire [31:0] f_size, ext_lba, ext_blocks;
    wire [EXT_AW:0] n_ext;
    wire [EXT_AW-1:0] vs_ext_ra;
    wire [EXT_AW:0] rs_ext_ra;
    wire        f_start = fg ? f_start_u : f_start_m;
    wire        fd_m = f_done && !fg, fd_u = f_done && fg;

    fat32_scan #(.EXT_AW(EXT_AW)) u_fat (
        .clk(clk), .rst_n(rst_n), .start(f_start), .name83(fg ? f_name_u : f_name_m), .bank(fg),
        .busy(f_busy), .done(f_done), .err_code(f_err), .file_size(f_size), .n_ext(n_ext),
        .ext_raddr(own == 2'd1 ? {1'b0, vs_ext_ra} : rs_ext_ra), .ext_lba(ext_lba), .ext_blocks(ext_blocks),
        .init_done(init_done), .st_start(fs_start), .st_lba(fs_lba), .st_count(fs_cnt),
        .st_done(own == 2'd0 && st_done), .st_err(st_err),
        .pool_count(own == 2'd0 ? pool_count : 4'd0), .pool_raddr(fs_ra),
        .pool_rdata(pool_rdata), .pool_release(fs_rel));

    // ---------------- 视频流 ----------------
    reg         v_en;
    wire        hdr_ok, hdr_err, video_quiescent;
    wire        video_aud_valid, video_aud_first, video_aud_ready, video_has_audio;
    wire [31:0] video_aud_data;
    wire [1:0]  vfmt;
    wire [15:0] v_retry;
    reg         v_cancel;
    sd_video_stream #(.EXT_AW(EXT_AW)) u_vs (
        .clk(clk), .rst_n(rst_n), .enable(v_en), .cancel(v_cancel), .quiescent(video_quiescent),
        .n_ext(n_ext), .ext_raddr(vs_ext_ra), .ext_lba(ext_lba), .ext_blocks(ext_blocks),
        .file_size(f_size),
        .hdr_ok(hdr_ok), .hdr_err(hdr_err), .fmt(vfmt), .fps(fps),
        .init_done(init_done),
        .st_start(vs_start), .st_lba(vs_lba), .st_count(vs_cnt), .st_busy(st_busy),
        .st_done(own == 2'd1 && st_done), .st_err(st_err), .st_blocks(st_blocks),
        .pool_count(own == 2'd1 ? pool_count : 4'd0), .pool_raddr(vs_ra), .pool_rdata(pool_rdata),
        .pool_release(vs_rel),
        .out_valid(v_valid), .out_data(v_data), .out_ready(v_ready),
        .aud_valid(video_aud_valid), .aud_data(video_aud_data), .aud_first(video_aud_first), .aud_ready(video_aud_ready),
        .has_audio(video_has_audio), .frame_count(v_frames), .retry_cnt(v_retry));

    // ---------------- 双上下文文件读(0 图片 1 音乐) ----------------
    localparam [1:0] UP_RUN = 2'd0, UP_DRAIN = 2'd1, UP_PARK = 2'd2;
    reg  [1:0] upk;                      // 播放中的停放子状态(视频让位)
    reg        trk_step, trk_back;       // 单拍: 曲目已换(方向)
    reg  [1:0]  r_start, r_cancel;
    wire [1:0]  r_busy, r_done;
    wire        r_idle, file_valid, file_ctx, file_ready;
    wire [31:0] file_data;
    reg         rd_hold;
    wire        parser_ready;
    sd_file_reader2 #(.EXT_AW(EXT_AW)) u_rd (
        .clk(clk), .rst_n(rst_n), .start(r_start), .cancel(r_cancel), .file_size(f_size), .n_ext(n_ext),
        .room1(aud_room && wav_selected && upk == UP_RUN), .hold(rd_hold), .busy(r_busy), .done(r_done), .idle(r_idle),
        .ext_raddr(rs_ext_ra), .ext_lba(ext_lba), .ext_blocks(ext_blocks),
        .st_start(rs_start), .st_lba(rs_lba), .st_count(rs_cnt), .st_busy(st_busy),
        .st_done(own == 2'd2 && st_done), .st_err(st_err), .st_blocks(st_blocks),
        .pool_count(own == 2'd2 ? pool_count : 4'd0), .pool_raddr(rs_ra), .pool_rdata(pool_rdata),
        .pool_release(rs_rel),
        .out_valid(file_valid), .out_data(file_data), .out_ctx(file_ctx), .out_ready(file_ready));
    assign f_valid    = file_valid && !file_ctx;
    assign f_data     = file_data;
    assign file_ready = file_ctx ? parser_ready : f_ready;

    // ---------------- WAV 解析与打包 ----------------
    wire        parser_pcm_valid, parser_pcm_ready, parser_header, parser_eof, parser_error, pack_done;
    wire [3:0]  parser_error_code;
    wire [15:0] parser_pcm;
    wire [31:0] total_samples;
    wire        wav_aud_valid, wav_aud_first;
    wire [31:0] wav_aud_data;
    t072_wav_parser u_wav_parser(.clk(clk), .rst_n(rst_n), .start(wav_start), .file_size(f_size),
        .in_valid(file_valid && file_ctx), .in_data(file_data), .in_ready(parser_ready),
        .stream_done(r_done[1]), .pcm_valid(parser_pcm_valid), .pcm(parser_pcm), .pcm_ready(parser_pcm_ready),
        .header_valid(parser_header), .eof(parser_eof), .error(parser_error), .error_code(parser_error_code),
        .samples_total(total_samples), .busy());
    t072_wav_audio_pack u_wav_pack(.clk(clk), .rst_n(rst_n), .start(wav_start), .header_valid(parser_header),
        .samples_total(total_samples), .pcm_valid(parser_pcm_valid), .pcm(parser_pcm), .pcm_ready(parser_pcm_ready),
        .out_valid(wav_aud_valid), .out_data(wav_aud_data), .out_first(wav_aud_first),
        .out_ready(aud_ready && wav_selected && !media_flush), .done(pack_done));
    assign wav_total = total_samples;

    // 音频源: 音乐播放中取 WAV, 否则取视频伴音
    assign aud_valid       = wav_selected ? wav_aud_valid : video_aud_valid;
    assign aud_data        = wav_selected ? wav_aud_data  : video_aud_data;
    assign aud_first       = wav_selected ? wav_aud_first : video_aud_first;
    assign video_aud_ready = !wav_selected && aud_ready;
    assign has_audio       = wav_selected || video_has_audio;

    // ---------------- 状态定义 ----------------
    localparam [4:0]
        M_WAIT = 5'd0, M_FINDV = 5'd1, M_FINDV_W = 5'd2, M_VIDEO = 5'd3,
        M_FINDP = 5'd4, M_FINDP_W = 5'd5, M_LOAD = 5'd6, M_LOAD_W = 5'd7,
        M_SHOW = 5'd8, M_DWELL = 5'd9, M_NOMEDIA = 5'd10, M_TRWAIT = 5'd11,
        M_VSTOP = 5'd12, M_SEL = 5'd13, M_VWAITM = 5'd14, M_VWAITX = 5'd15, M_VRST = 5'd16,
        M_VNONE = 5'd17, M_RELOAD = 5'd18, M_BLANK = 5'd19, M_WSHOW = 5'd20, M_WALL = 5'd21,
        M_BOOTF = 5'd22, M_BOOTX = 5'd23, M_BOOTS = 5'd24;
    localparam [2:0]
        U_OFF = 3'd0, U_FIND = 3'd1, U_FWAIT = 3'd2, U_FLUSH = 3'd3, U_START = 3'd4,
        U_PLAY = 3'd5, U_CANCEL = 3'd6, U_NONE = 3'd7;
    localparam [1:0] X_IDLE = 2'd0, X_HOLD = 2'd1, X_RUN = 2'd2, X_DONE = 2'd3;
    localparam [1:0] T_VIDEO = 2'd2;
    reg [4:0] ms;
    reg [2:0] mu;
    reg [1:0] fx;
    reg       fxm_req, fxu_req;

    // ---------------- FAT 查找仲裁 ----------------
    // 查找前暂停文件读并等其排空(块池归 FAT 使用), 完成后保持授权直到请求方撤销
    wire fx_ok   = r_idle && pool_count == 4'd0 && !st_busy && !f_busy && own != 2'd1;
    // 完成只对仍在请求的一方有效: 撤销请求后的那一拍 fx 仍停在 X_DONE, 不能被当成新结果
    wire fxm_done = (fx == X_DONE) && !fg && fxm_req;
    wire fxu_done = (fx == X_DONE) && fg && fxu_req;
    always @(*) rd_hold = (fx == X_HOLD) || (fx == X_RUN) || own == 2'd1 || ms == M_VWAITM;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin fx <= X_IDLE; fg <= 1'b0; end
        else case (fx)
        X_IDLE: if (fxm_req) begin fg <= 1'b0; fx <= X_HOLD; end
                else if (fxu_req) begin fg <= 1'b1; fx <= X_HOLD; end
        X_HOLD: if (fx_ok) fx <= X_RUN;
        X_RUN:  if (f_done) fx <= X_DONE;
        default: if (fg ? !fxu_req : !fxm_req) fx <= X_IDLE;
        endcase
    // 进入 X_RUN 的那一拍发起查找
    reg fx_go;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) fx_go <= 1'b0; else fx_go <= (fx == X_HOLD) && fx_ok;
    always @(*) begin f_start_m = fx_go && !fg; f_start_u = fx_go && fg; end

    // SD 端口归属: 查找期间给 FAT, 视频流期间给视频, 其余给文件读
    always @(posedge clk or negedge rst_n)
        if (!rst_n) own <= 2'd2;
        else own <= (fx == X_RUN) ? 2'd0 : v_en ? 2'd1 : 2'd2;

    // ---------------- 公共状态 ----------------
    reg  [4:0]  flush_count;
    reg  [19:0] cancel_count;
    reg         reload_pend, nav_pend, nav_back, dir_back, need_load, vid_missing;
    reg         vnav_pend, vnav_back;
    reg  [3:0]  vmiss;
    reg  [7:0]  slot_done;               // 图墙槽完成掩码(缩略已写或已填黑)
    reg         bg, wall_pend, blank_wait;
    reg  [3:0]  bg_idx, focus;
    reg  [4:0]  bg_ret;
    reg  [31:0] sec_cnt;
    reg  [5:0]  dwell_s;
    reg         shown_any, nomedia, ld_err_seen, is_video;
    reg  [1:0]  tgt_page;
    reg  [2:0]  nxt_mode;
    reg         ld_seen, ld_err_q, rd_seen;   // 加载器完成与读完成先后不定, 分别锁存
    reg         zoom_pend;               // 缩放请求: 加载/转场中按下也不丢, 停留时生效
    reg         boot_pend, boot_vid, boot_skip;   // 启动动画: 待播 / 播放中 / 已请求跳过
    reg  [1:0]  boot_page;
    wire [31:0] v_frames;

    assign mode_video = is_video;
    assign v_clear    = !v_en;
    assign v_fmt      = vfmt;
    assign v_has_audio = video_has_audio;

    function [87:0] pic_name(input [3:0] i);
        pic_name = {"PIC", 8'h30 + {4'd0, i}, "    BMP"};
    endfunction
    function [87:0] vid_name(input [3:0] i);
        vid_name = {"VID0000", 8'h30 + {4'd0, i}, "V29"};
    endfunction
    function [87:0] wav_name(input [1:0] i);
        wav_name = {"WAV", 8'h31 + {6'd0, i}, "    WAV"};
    endfunction
    wire [3:0] pic_fwd  = (pic_idx >= MAX_PIC) ? 4'd1 : pic_idx + 4'd1;
    wire [3:0] pic_back = (pic_idx == 4'd1) ? MAX_PIC : pic_idx - 4'd1;
    wire [3:0] vid_fwd  = (vid_idx == MAX_VID - 4'd1) ? 4'd0 : vid_idx + 4'd1;
    wire [3:0] vid_back = (vid_idx == 4'd0) ? MAX_VID - 4'd1 : vid_idx - 4'd1;
    // 图片侧空闲: 加载、转场、图片读全部结束
    wire photo_idle  = img_idle && !trans_busy && !r_busy[0] && fx == X_IDLE;
    wire leave_photo = tgt_mode == T_VIDEO || reload_pend;
    wire auto_on     = period_s != 6'd0 && !photo_hold;
    wire [3:0] cur_idx = bg ? bg_idx : pic_idx;
    assign thumb_slot = cur_idx[2:0] - 3'd1;
    assign wall_cell  = focus[1:0] - 2'd1;
    assign focus_idx  = focus;
    assign bg_load    = bg;
    assign booting    = boot_pend;
    reg [3:0] bg_next;                   // 下一个待后台读的槽(最小未完成号)
    integer bi;
    always @(*) begin
        bg_next = 4'd0;
        for (bi = 7; bi >= 0; bi = bi - 1) if (!slot_done[bi]) bg_next = bi[3:0] + 4'd1;
    end
    wire       all_done   = &slot_done;
    wire       grp_hi     = (focus > 4'd4);
    wire       grp_ok     = grp_hi ? &slot_done[7:4] : &slot_done[3:0];
    wire [3:0] focus_fwd  = (focus == 4'd8) ? 4'd1 : focus + 4'd1;
    wire [3:0] focus_back = (focus == 4'd1) ? 4'd8 : focus - 4'd1;
    wire       grp_chg    = ((nav_back ? focus_back : focus_fwd) > 4'd4) != grp_hi;
    wire       bg_can     = !all_done && photo_idle && !blank_busy;
    // 主控处于重载/等卡阶段: 音乐暂停发起新查找
    wire       main_reload = ms == M_RELOAD || ms == M_WAIT || (ms == M_SEL && reload_pend);

    // ======================= 主控 =======================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ms <= M_WAIT; f_name_m <= 88'd0; fxm_req <= 1'b0; v_en <= 1'b0; v_cancel <= 1'b0;
            r_start[0] <= 1'b0; r_cancel[0] <= 1'b0;
            ld_start <= 1'b0; img_page <= 2'd0; show_req <= 1'b0; show_page <= 2'd0; show_mode <= 3'd0;
            pic_idx <= 4'd1; vid_idx <= 4'd0; sec_cnt <= 32'd0; dwell_s <= 6'd0; shown_any <= 1'b0;
            nomedia <= 1'b0; ld_err_seen <= 1'b0; is_video <= 1'b0; tgt_page <= 2'd0; nxt_mode <= 3'd1;
            ld_seen <= 1'b0; ld_err_q <= 1'b0; rd_seen <= 1'b0;
            reload_pend <= 1'b0; nav_pend <= 1'b0; nav_back <= 1'b0; dir_back <= 1'b0;
            vnav_pend <= 1'b0; vnav_back <= 1'b0; vmiss <= 4'd0;
            need_load <= 1'b1; vid_missing <= 1'b0; sd_reinit <= 1'b0;
            slot_done <= 8'd0; bg <= 1'b0; wall_pend <= 1'b0; blank_wait <= 1'b0; bg_idx <= 4'd1; focus <= 4'd1;
            bg_ret <= M_DWELL; blank_start <= 1'b0; wall_mode <= 1'b0; zoom <= 2'd0;
            flush_count <= 5'd0; cancel_count <= 20'd0;
            boot_pend <= 1'b1; boot_vid <= 1'b0; boot_skip <= 1'b0; boot_page <= 2'd0; zoom_pend <= 1'b0;
        end else begin
            r_start[0] <= 1'b0; r_cancel[0] <= 1'b0; ld_start <= 1'b0; show_req <= 1'b0;
            sd_reinit <= (ms == M_RELOAD);
            blank_start <= 1'b0; v_cancel <= 1'b0;
            if (wall_toggle) wall_pend <= 1'b1;
            if (zoom_step && !wall_mode) zoom_pend <= 1'b1;
            if (zoom_pend && !wall_mode && ms == M_DWELL && !trans_busy) begin
                zoom_pend <= 1'b0; zoom <= (zoom == 2'd2) ? 2'd0 : zoom + 2'd1;
            end
            if (ld_done) begin ld_seen <= 1'b1; ld_err_q <= ld_err; end
            if (r_done[0]) rd_seen <= 1'b1;
            if (reload_req) reload_pend <= 1'b1;
            if (photo_next != photo_prev) begin nav_pend <= 1'b1; nav_back <= photo_prev; end
            if (video_next != video_prev && is_video) begin vnav_pend <= 1'b1; vnav_back <= video_prev; end
            if (any_key && boot_pend) boot_skip <= 1'b1;
            if (trk_step && photo_hold && !boot_pend) begin nav_pend <= 1'b1; nav_back <= trk_back; end
            case (ms)
            // 初始化失败(未插卡/接触不良)每秒自动重试, 也接受手动重载
            M_WAIT:    if (init_done) begin sec_cnt <= 32'd0; ms <= M_SEL; end
                       else if (init_err) begin
                           if (reload_pend || sec_cnt == SEC_CYCLES - 1) begin
                               sec_cnt <= 32'd0; flush_count <= 5'd31; ms <= M_RELOAD;
                           end else sec_cnt <= sec_cnt + 32'd1;
                       end
            // 调度: 此时主控无读卡事务, 显示已处于图片层(mode_eff=0)
            M_SEL: begin
                if (reload_pend) begin
                    // 等音乐侧也撤回查找/读文件后才重新初始化 SD
                    if (mu == U_OFF || mu == U_NONE) begin flush_count <= 5'd31; ms <= M_RELOAD; end
                end else if (tgt_mode == T_VIDEO) begin vmiss <= 4'd0; boot_pend <= 1'b0; ms <= M_FINDV; end
                else if (shown_any && !need_load && !nomedia) begin
                    sec_cnt <= 32'd0; dwell_s <= 6'd0; ms <= wall_mode ? M_WALL : M_DWELL;
                end else begin dir_back <= 1'b0; nav_pend <= 1'b0; ms <= M_FINDP; end
            end
            // SD 主机重新初始化, 媒体状态回到各模式第一项; 显示保持最后一帧
            M_RELOAD: begin
                reload_pend <= 1'b0; nav_pend <= 1'b0; vnav_pend <= 1'b0;
                pic_idx <= 4'd1; vid_idx <= 4'd0; need_load <= 1'b1; nomedia <= 1'b0; ld_err_seen <= 1'b0; vid_missing <= 1'b0;
                slot_done <= 8'd0; bg <= 1'b0; wall_pend <= 1'b0; wall_mode <= 1'b0; zoom <= 2'd0; focus <= 4'd1;
                if (flush_count == 5'd0) ms <= M_WAIT; else flush_count <= flush_count - 5'd1;
            end

            // ---- 视频(音乐此时已停, SD 独占) ----
            M_FINDV:   if (mu == U_OFF || mu == U_NONE || upk == UP_PARK) begin
                           f_name_m <= vid_name(vid_idx); fxm_req <= 1'b1;
                           if (fxm_done) begin
                               fxm_req <= 1'b0;
                               if (f_err == 3'd0) begin
                                   vmiss <= 4'd0; vnav_pend <= 1'b0; is_video <= 1'b1; ms <= M_VWAITM;
                               end else if (vmiss == MAX_VID - 4'd1) begin
                                   vid_missing <= 1'b1; ms <= M_VNONE;
                               end else begin
                                   // 缺号: 沿最近一次切换方向继续找
                                   vmiss <= vmiss + 4'd1; vid_idx <= vnav_back ? vid_back : vid_fwd;
                               end
                           end
                       end
            M_VWAITM:  if (mode_eff) begin v_en <= 1'b1; ms <= M_VIDEO; end
            M_VIDEO:   if (boot_vid) begin
                           if (v_shown == 16'd0) sec_cnt <= sec_cnt + 32'd1;
                           if (boot_skip || reload_pend || tgt_mode == T_VIDEO || hdr_err ||
                               (v_shown == 16'd0 && sec_cnt == {SEC_CYCLES[30:0], 1'b0}) ||
                               (hdr_ok && v_frames != 0 && v_shown >= v_frames[15:0])) begin
                               // 挂起 PIC1 显示请求(图片层生效时取用), 再请求切回图片层
                               show_req <= 1'b1; show_page <= boot_page; show_mode <= 3'd0;
                               is_video <= 1'b0; ms <= M_BOOTX;
                           end
                       end else if (tgt_mode != T_VIDEO || reload_pend || vnav_pend) begin
                           cancel_count <= 20'd0; v_cancel <= 1'b1; ms <= M_VSTOP;
                       end
            M_VSTOP: begin
                v_cancel <= 1'b1;
                if (video_quiescent) begin
                    v_en <= 1'b0; v_cancel <= 1'b0;
                    if (vnav_pend && tgt_mode == T_VIDEO && !reload_pend) begin
                        vid_idx <= vnav_back ? vid_back : vid_fwd;
                        flush_count <= 5'd31; ms <= M_VRST;
                    end else begin is_video <= 1'b0; vnav_pend <= 1'b0; ms <= M_VWAITX; end
                end else if (cancel_count == 20'd999999) begin v_en <= 1'b0; v_cancel <= 1'b0; is_video <= 1'b0; ms <= M_VWAITX; end
                else cancel_count <= cancel_count + 20'd1;
            end
            // 换片: v_en 低保持清空数拍(释放由存储侧等旧写事务取完), 然后查找新文件
            M_VRST:    if (flush_count == 5'd0) begin vnav_pend <= 1'b0; vmiss <= 4'd0; ms <= M_FINDV; end
                       else flush_count <= flush_count - 5'd1;
            M_VWAITX:  if (!mode_eff) ms <= M_SEL;
            M_VNONE:   if (tgt_mode != T_VIDEO || reload_pend) begin vid_missing <= 1'b0; ms <= M_SEL; end

            // ---- 图片 ----
            M_FINDP: begin
                f_name_m <= pic_name(cur_idx); fxm_req <= 1'b1;
                if (fxm_done) begin
                    if (f_err == 3'd0) ms <= M_TRWAIT;          // 授权保持到读文件启动
                    else begin
                        fxm_req <= 1'b0;
                        if (bg) begin img_page <= tgt_page; blank_start <= 1'b1; blank_wait <= 1'b1; ms <= M_BLANK; end
                        else if (dir_back && pic_idx != 4'd1) pic_idx <= pic_idx - 4'd1;
                        else if (!dir_back && pic_idx != 4'd1) pic_idx <= 4'd1;
                        else begin nomedia <= 1'b1; boot_pend <= 1'b0; ms <= M_NOMEDIA; end
                    end
                end
            end
            // 目标页不能是正在显示或转场中的页: 等转场结束
            M_TRWAIT:  if (!trans_busy) begin img_page <= tgt_page; ms <= M_LOAD; end
            M_LOAD:    begin
                           ld_start <= 1'b1; r_start[0] <= 1'b1; fxm_req <= 1'b0; ms <= M_LOAD_W;
                           ld_seen <= 1'b0; ld_err_q <= 1'b0; rd_seen <= 1'b0;
                       end
            // 格式错误时加载器先结束, 读侧仍会把文件读完(数据被丢弃)后结束
            M_LOAD_W:  if (ld_seen && rd_seen) begin
                           if (ld_err_q && bg) begin ld_err_seen <= 1'b1; blank_start <= 1'b1; blank_wait <= 1'b1; ms <= M_BLANK; end
                           else if (ld_err_q) begin ld_err_seen <= 1'b1; pic_idx <= dir_back ? pic_back : pic_fwd; ms <= M_FINDP; end
                           else begin
                               slot_done[cur_idx[2:0] - 3'd1] <= 1'b1;
                               if (bg) begin bg <= 1'b0; ms <= bg_ret; end
                               else ms <= M_SHOW;
                           end
                       end
            M_SHOW:    if (img_idle) begin
                           show_req  <= !boot_pend; show_page <= tgt_page; boot_page <= tgt_page;
                           show_mode <= !shown_any ? 3'd0 : (trans_cfg == 3'd7) ? nxt_mode :
                                        (trans_cfg > 3'd4) ? 3'd0 : trans_cfg;
                           // 首张图直接显示, 不消耗转场序号
                           if (shown_any && trans_cfg == 3'd7) nxt_mode <= (nxt_mode == 3'd4) ? 3'd1 : (nxt_mode == 3'd1) ? 3'd3 : 3'd4;
                           shown_any <= 1'b1; need_load <= 1'b0; tgt_page <= {1'b0, ~tgt_page[0]};
                           zoom <= 2'd0; wall_mode <= 1'b0;
                           sec_cnt <= 32'd0; dwell_s <= 6'd0; ms <= boot_pend ? M_BOOTF : M_DWELL;
                       end
            // 启动动画查找: 缺文件/不在图片页/已跳过 -> 直接显示 PIC1
            M_BOOTF: begin
                if (boot_skip || reload_pend || tgt_mode == T_VIDEO) begin
                    show_req <= 1'b1; show_page <= boot_page; show_mode <= 3'd0;
                    boot_pend <= 1'b0; boot_skip <= 1'b0; nav_pend <= 1'b0; wall_pend <= 1'b0; zoom_pend <= 1'b0;
                    ms <= M_SEL;
                end else if (mu == U_OFF || mu == U_NONE || upk == UP_PARK) begin
                    f_name_m <= "BOOT    V29"; fxm_req <= 1'b1;
                    if (fxm_done) begin
                        fxm_req <= 1'b0;
                        if (f_err == 3'd0) begin is_video <= 1'b1; boot_vid <= 1'b1; sec_cnt <= 32'd0; ms <= M_VWAITM; end
                        else begin
                            show_req <= 1'b1; show_page <= boot_page; show_mode <= 3'd0;
                            boot_pend <= 1'b0; boot_skip <= 1'b0; nav_pend <= 1'b0; ms <= M_SEL;
                        end
                    end
                end
            end
            // 等显示层切回图片(PIC1 已上屏), 再取消视频流
            M_BOOTX:   if (!mode_eff) begin v_cancel <= 1'b1; cancel_count <= 20'd0; ms <= M_BOOTS; end
            M_BOOTS: begin
                v_cancel <= 1'b1;
                if (video_quiescent || cancel_count == 20'd999999) begin
                    v_en <= 1'b0; v_cancel <= 1'b0; boot_vid <= 1'b0; boot_pend <= 1'b0; boot_skip <= 1'b0;
                    nav_pend <= 1'b0; wall_pend <= 1'b0; vnav_pend <= 1'b0; zoom_pend <= 1'b0; ms <= M_SEL;
                end else cancel_count <= cancel_count + 20'd1;
            end
            M_DWELL:   begin
                           if (leave_photo) begin
                               if (photo_idle) ms <= M_SEL;
                           end else begin
                               if (!auto_on) begin sec_cnt <= 32'd0; dwell_s <= 6'd0; end
                               else if (sec_cnt == SEC_CYCLES - 1) begin
                                   sec_cnt <= 32'd0;
                                   if (dwell_s != 6'h3F) dwell_s <= dwell_s + 6'd1;
                               end else sec_cnt <= sec_cnt + 32'd1;
                               if (wall_pend) begin
                                   wall_pend <= 1'b0; nav_pend <= 1'b0; wall_mode <= 1'b1; zoom <= 2'd0;
                                   focus <= pic_idx; ms <= M_WSHOW;
                               end else if (((auto_on && dwell_s >= period_s) || nav_pend) && !trans_busy) begin
                                   dir_back <= nav_pend && nav_back;
                                   pic_idx  <= (nav_pend && nav_back) ? pic_back : pic_fwd;
                                   nav_pend <= 1'b0; ms <= M_FINDP;
                               end else if (bg_can) begin
                                   bg <= 1'b1; bg_idx <= bg_next; bg_ret <= M_DWELL; ms <= M_FINDP;
                               end
                           end
                       end
            M_NOMEDIA: if (leave_photo && photo_idle) ms <= M_SEL;
            // 缺图/坏图槽: 写黑缩略
            M_BLANK:   begin
                           if (blank_busy) blank_wait <= 1'b0;
                           if (!blank_wait && !blank_busy && img_idle) begin
                               slot_done[bg_idx[2:0] - 3'd1] <= 1'b1; bg <= 1'b0; ms <= bg_ret;
                           end
                       end
            // 进入/切换图墙页: 本组未齐时先后台补读本组
            M_WSHOW:   begin
                           if (leave_photo) begin
                               if (photo_idle) ms <= M_SEL;
                           end else if (grp_ok) begin
                               if (!trans_busy && img_idle) begin
                                   show_req <= 1'b1; show_page <= {1'b1, grp_hi};
                                   show_mode <= (trans_cfg == 3'd7) ? 3'd1 : (trans_cfg > 3'd4) ? 3'd0 : trans_cfg;
                                   ms <= M_WALL;
                               end
                           end else if (bg_can) begin
                               bg <= 1'b1; bg_idx <= grp_hi ? ((!slot_done[4]) ? 4'd5 : (!slot_done[5]) ? 4'd6 : (!slot_done[6]) ? 4'd7 : 4'd8)
                                                            : bg_next;
                               bg_ret <= M_WSHOW; ms <= M_FINDP;
                           end
                       end
            M_WALL:    begin
                           if (leave_photo) begin
                               if (photo_idle) ms <= M_SEL;
                           end else if (wall_pend) begin
                               // 回全屏: 读焦点图并以转场显示
                               wall_pend <= 1'b0; nav_pend <= 1'b0; pic_idx <= focus; dir_back <= 1'b0; ms <= M_FINDP;
                           end else if (nav_pend && !trans_busy) begin
                               nav_pend <= 1'b0;
                               focus <= nav_back ? focus_back : focus_fwd;
                               if (grp_chg) ms <= M_WSHOW;
                           end else if (bg_can) begin
                               bg <= 1'b1; bg_idx <= bg_next; bg_ret <= M_WALL; ms <= M_FINDP;
                           end
                       end
            default:   ms <= M_WAIT;
            endcase
        end
    end

    // ======================= 音乐 =======================
    // 播放条件: MUSIC 开、不在视频、主控不在重载。条件撤销 -> 取消读文件并冲刷 sink。
    (* async_reg="true" *) reg [1:0] drained_sync, source_drained_sync;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin drained_sync <= 2'b00; source_drained_sync <= 2'b00; end
        else begin drained_sync <= {drained_sync[0], audio_drained_async}; source_drained_sync <= {source_drained_sync[0], source_drained_async}; end
    wire       mu_want = music_on && tgt_mode != T_VIDEO && !is_video && !reload_pend && !main_reload;
    wire       mu_nav  = wav_next != wav_previous;
    reg  [2:0] umiss;                    // 连续缺曲计数(4 首都缺 -> 无曲目)
    reg  [3:0] uflush;
    reg  [19:0] ucancel;
    reg        unav_back;
    wire       mu_keep = music_on && !reload_pend && !main_reload;   // 保留会话(只因视频让位)
    // 曲尾: 打包完、sink 与守护都排空
    wire       mu_tail = pack_done && drained_sync[1] && source_drained_sync[1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mu <= U_OFF; f_name_u <= 88'd0; fxu_req <= 1'b0; r_start[1] <= 1'b0; r_cancel[1] <= 1'b0;
            wav_selected <= 1'b0; wav_start <= 1'b0; wav_error <= 1'b0; wav_error_code <= 4'd0;
            wav_slot <= 2'd0; session_toggle <= 1'b0; umiss <= 3'd0; uflush <= 4'd0; ucancel <= 20'd0; unav_back <= 1'b0;
            upk <= UP_RUN; trk_step <= 1'b0; trk_back <= 1'b0;
        end else begin
            r_start[1] <= 1'b0; r_cancel[1] <= 1'b0; wav_start <= 1'b0; trk_step <= 1'b0;
            if (ms == M_RELOAD) wav_slot <= 2'd0;
            case (mu)
            U_OFF: if (mu_want && init_done) begin umiss <= 3'd0; wav_error <= 1'b0; mu <= U_FIND; end
            U_FIND: begin
                if (!mu_want) begin fxu_req <= 1'b0; mu <= U_OFF; end
                else begin
                    f_name_u <= wav_name(wav_slot); fxu_req <= 1'b1;
                    if (fxu_done) begin
                        if (f_err == 3'd0) begin
                            wav_selected <= 1'b1; session_toggle <= !session_toggle; uflush <= 4'd15; mu <= U_FLUSH;
                        end else begin
                            fxu_req <= 1'b0; wav_error <= 1'b1; wav_error_code <= 4'd8 + {1'b0, f_err};
                            if (umiss == 3'd3) mu <= U_NONE;
                            else begin umiss <= umiss + 3'd1; wav_slot <= unav_back ? wav_slot - 2'd1 : wav_slot + 2'd1; end
                        end
                    end
                end
            end
            // 新会话: 等 sink 冲刷完成再启动解析与读文件(授权保持到读启动)
            U_FLUSH: if (uflush == 4'd0) mu <= U_START; else uflush <= uflush - 4'd1;
            U_START: begin
                wav_start <= 1'b1; r_start[1] <= 1'b1; fxu_req <= 1'b0;
                umiss <= 3'd0; wav_error <= 1'b0; mu <= U_PLAY;
            end
            U_PLAY: begin
                if (upk == UP_DRAIN) begin
                    // 不再发音乐读(room1 被门控); 等音乐在途读排空(读侧空闲或已切到图片上下文)再停止送样
                    if (r_idle || !file_ctx) begin wav_selected <= 1'b0; uflush <= 4'd15; upk <= UP_PARK; end
                end else if (upk == UP_PARK) begin
                    if (uflush != 4'd0) uflush <= uflush - 4'd1;
                    else if (!mu_keep || mu_nav) begin
                        if (mu_nav) begin unav_back <= wav_previous; wav_slot <= wav_next ? wav_slot + 2'd1 : wav_slot - 2'd1; end
                        upk <= UP_RUN; r_cancel[1] <= 1'b1; ucancel <= 20'd0; mu <= U_CANCEL;
                    end else if (mu_want) begin wav_selected <= 1'b1; upk <= UP_RUN; end
                end else if (mu_keep && !mu_want && !mu_nav && !parser_error && !mu_tail) begin
                    upk <= UP_DRAIN;
                end else if (!mu_want || mu_nav || parser_error || mu_tail) begin
                    if (parser_error) begin wav_error <= 1'b1; wav_error_code <= parser_error_code; end
                    if (mu_nav) begin
                        unav_back <= wav_previous; wav_slot <= wav_next ? wav_slot + 2'd1 : wav_slot - 2'd1;
                        trk_step <= 1'b1; trk_back <= wav_previous;
                    end else if (mu_tail || parser_error) begin
                        unav_back <= 1'b0; wav_slot <= wav_slot + 2'd1; trk_step <= 1'b1; trk_back <= 1'b0;
                    end
                    r_cancel[1] <= 1'b1; ucancel <= 20'd0; mu <= U_CANCEL;
                end
            end
            // 撤回: 读文件上下文 1 放弃, 冲刷 sink, 结束本会话
            U_CANCEL: begin
                if (!r_busy[1]) begin
                    wav_selected <= 1'b0;
                    mu <= mu_want ? U_FIND : U_OFF;
                end else if (ucancel == 20'd999999) begin wav_selected <= 1'b0; mu <= U_OFF; end
                else ucancel <= ucancel + 20'd1;
                if (mu_nav) begin unav_back <= wav_previous; wav_slot <= wav_next ? wav_slot + 2'd1 : wav_slot - 2'd1; end
            end
            // 4 首都缺: 等关闭或重载后再试
            default: if (!mu_want || mu_nav) begin
                         umiss <= 3'd0;
                         if (mu_nav) wav_slot <= wav_next ? wav_slot + 2'd1 : wav_slot - 2'd1;
                         mu <= mu_want ? U_FIND : U_OFF;
                     end
            endcase
        end
    end
    // media_flush 作音频 sink 的异步清空, 必须由寄存器直接输出
    reg media_flush_q;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) media_flush_q <= 1'b1;
        else media_flush_q <= (mu == U_FLUSH) || (mu == U_CANCEL) || wav_start || ms == M_VSTOP || ms == M_BOOTS ||
                              (upk == UP_PARK && uflush != 4'd0);
    assign media_flush = media_flush_q;
    assign media_eof   = wav_selected && pack_done;
    assign wav_state   = (mu == U_PLAY && upk == UP_RUN) ? 2'd1 : (mu == U_NONE) ? 2'd3 : (mu == U_OFF) ? 2'd0 : 2'd2;
    assign wav_hdr     = parser_header && mu == U_PLAY;

    assign status = {init_err, hs_mode, is_video, !is_video && shown_any, nomedia || vid_missing, hdr_err, ld_err_seen,
                     ms == M_RELOAD || ms == M_WAIT};
endmodule
