`timescale 1ns / 1ps
// t073_master_top：主板媒体与显示顶层。空闲零PCM，媒体页KEY3完整重启。LED1纯心跳，LED2为SD高速且SDRAM就绪，LED3为图片提交/视频头状态，LED4为综合错误。
module t073_master_top #(
    parameter integer MS_CYCLES    = 50_000,        // 面板 1ms
    parameter [31:0]  SEC_CYCLES   = 32'd50_000_000,
    parameter integer ACMD41_TRIES = 4095,
    parameter integer TRANS_FRAMES = 30
)(
    input  wire        clk_50m,
    input  wire        rst_n,
    input  wire [3:0]  sw,
    input  wire        key2_n,
    input  wire        key3_n,
    input  wire        key4_n,
    input wire c1_rx_data,
    output wire c1_tx_data,
    output wire c1_d3_low,c1_e3_low,c1_e4_low,c1_k1_low,c1_j1_low,c1_f4_low,

    output wire        sd_clk,
    inout  wire        sd_cmd,
    input  wire [3:0]  sd_dat,

    output wire        HDMI_CLK_P,
    output wire        HDMI_D0_P,
    output wire        HDMI_D1_P,
    output wire        HDMI_D2_P,
    output wire        HDMI_DDC_SCL,
    inout  wire        HDMI_DDC_SDA,

    output wire [3:0]  led
);
    wire system_rst_n;
    wire ctrl_clk, mem_clk, sdram_locked;
    sdram_clk_gen_50m u_sdram_pll (.ref_clk(clk_50m), .pll_rst_n(system_rst_n),
        .ctrl_clk(ctrl_clk), .mem_clk(mem_clk), .pll_locked(sdram_locked));

    wire pixel_clk, serial_clk, audio_mclk, hdmi_locked;
    hdmi_pll u_hdmi_pll (.ref_clk(clk_50m), .pll_rst_n(system_rst_n),
        .pixel_clk(pixel_clk), .serial_clk(serial_clk), .audio_mclk(audio_mclk),
        .pll_locked(hdmi_locked));

    reg [2:0] rs_c;
    always @(posedge ctrl_clk or negedge sdram_locked)
        if (!sdram_locked) rs_c <= 3'b000; else rs_c <= {rs_c[1:0], 1'b1};
    wire crst_n = rs_c[2];

    reg [2:0] rs_p;
    always @(posedge pixel_clk or negedge hdmi_locked)
        if (!hdmi_locked) rs_p <= 3'b111; else rs_p <= {rs_p[1:0], 1'b0};
    wire prst = rs_p[2];
    // TMDS PHY 使用像素复位末级的局部副本: 避免高扇出复位网络长线进入串化器恢复时序
    (* preserve = "true" *) reg prst_phy;
    always @(posedge pixel_clk or negedge hdmi_locked)
        if (!hdmi_locked) prst_phy <= 1'b1; else prst_phy <= rs_p[1];

    // ---- 面板 ----
    wire [3:0] sw_q;
    wire [1:0] page, tgt_mode;
    wire [2:0] k_short, k_long;
    t073_panel #(.MS_CYCLES(MS_CYCLES)) u_panel (.clk(ctrl_clk), .rst_n(crst_n), .sw(sw), .keys_n({key4_n, key3_n, key2_n}),
        .sw_q(sw_q), .page(page), .tgt_mode(tgt_mode), .k_short(k_short), .k_long(k_long));
    wire pg_photo = page == 2'd0, pg_wav = page == 2'd1, pg_video = page == 2'd2;
    wire reload_req    = k_long[1] && page != 2'd3;
    // 请求锁存后跨到板载参考时钟域；PLL复位期间计时器仍继续运行。
    reg restart_request;
    (* async_reg = "true" *) reg [1:0] restart_key_sync;
    always @(posedge ctrl_clk or negedge crst_n)
        if (!crst_n) restart_key_sync <= 2'b11;
        else restart_key_sync <= {restart_key_sync[0], key3_n};
    always @(posedge ctrl_clk or negedge crst_n)
        if (!crst_n) restart_request <= 1'b0;
        else if (restart_key_sync[1]) restart_request <= 1'b0;
        else if (reload_req) restart_request <= 1'b1;
    t073_restart_guard u_restart (.clk(clk_50m), .rst_n(rst_n),
        .request_async(restart_request), .key_n_async(key3_n), .system_rst_n(system_rst_n));

    wire photo_next    = pg_photo && k_short[0];
    wire photo_prev    = pg_photo && k_short[1];
    wire zoom_step     = pg_photo && k_short[2];
    wire wall_toggle   = pg_photo && k_long[0];
    wire music_toggle  = pg_wav && k_short[0];
    wire wav_next      = pg_wav && k_short[1];
    wire wav_previous  = pg_wav && k_short[2];
    wire video_next    = pg_video && k_short[1];
    wire video_prev    = pg_video && k_short[2];
    reg  video_pause;
    always @(posedge ctrl_clk or negedge crst_n)
        if (!crst_n) video_pause <= 1'b0;
        else if (tgt_mode != 2'd2 || video_next || video_prev) video_pause <= 1'b0;
        else if (pg_video && k_short[0]) video_pause <= !video_pause;
    // ---- 菜单(持续参数) ----
    wire [2:0] m_focus, m_trans_sel, trans_cfg;
    wire [4:0] m_volume;
    wire [5:0] period_s;
    wire [1:0] m_spec;
    wire       m_music, m_info, m_spk;
    t073_menu u_menu (.clk(ctrl_clk), .rst_n(crst_n), .active(page == 2'd3), .k_short(k_short), .k_long(k_long),
        .music_toggle(music_toggle), .focus(m_focus), .music_on(m_music), .volume(m_volume), .trans_sel(m_trans_sel),
        .period_s(period_s), .spec_sel(m_spec), .info_on(m_info), .spk_only(m_spk), .trans_cfg(trans_cfg));
    // 音量为准静态多位量: 像素域连续两拍同步值一致才提交
    (* async_reg="true" *) reg [4:0] vol_m, vol_s;
    reg [4:0] vol_p, volume_steps_pixel;
    always @(posedge pixel_clk or posedge prst)
        if (prst) begin vol_m <= 5'd20; vol_s <= 5'd20; vol_p <= 5'd20; volume_steps_pixel <= 5'd20; end
        else begin
            vol_m <= m_volume; vol_s <= vol_m; vol_p <= vol_s;
            if (vol_s == vol_p) volume_steps_pixel <= vol_s;
        end
    // 输出切换: SPK ONLY 时 HDMI 音频置零, 送副板的 PCM 与频谱不受影响
    (* async_reg="true" *) reg [1:0] spk_sync;
    always @(posedge pixel_clk or posedge prst)
        if (prst) spk_sync <= 2'b00; else spk_sync <= {spk_sync[0], m_spk};

    // ---- SD 媒体控制 ----
    wire        mode_video, v_valid, v_ready, a_valid, a_first, a_ready, has_audio;
    wire [31:0] v_data, a_data, f_data;
    wire [5:0]  fps;
    wire        f_valid, f_ready, ld_start, ld_done, ld_err, img_idle, show_req, trans_busy;
    wire [1:0]  img_page, show_page;
    wire [2:0]  show_mode;
    wire [7:0]  status;      // {init_err, hs, video, slide, no_media, hdr_err, ld_err, fat_busy}
    wire [3:0]  pic_idx;
    wire        video_ok = !status[2];      // 视频文件头未报错
    wire wav_selected,wav_error,wav_start,media_flush,media_eof,media_session;
    wire[3:0] wav_error_code;wire[1:0] wav_slot;
    wire sink_drained,guarded_drained,sink_warm_hold,sink_tick,sink_started;
    wire mode_eff, v_clear, v_paused, v_disp_valid, v_has_audio;
    wire [1:0] v_fmt, wav_state, wall_cell, zoom;
    wire [2:0] thumb_slot;
    wire [3:0] focus_idx;
    wire       wall_mode, blank_start, blank_busy;
    wire guard_zero_stream;
    wire playback_frame_valid;
    wire signed[15:0] playback_frame_sample;
    wire [31:0] wav_total;
    wire [15:0] shown_cnt;
    wire        bg_load, booting;
    wire        wav_hdr;
    wire [3:0]  vid_idx;
    wire        aud_room;
    t073_media_ctrl #(.ACMD41_TRIES(ACMD41_TRIES), .SEC_CYCLES(SEC_CYCLES)) u_mc (
        .clk(ctrl_clk), .rst_n(crst_n), .sd_cfg(3'b000),
        .tgt_mode(tgt_mode), .mode_eff(mode_eff), .photo_next(photo_next), .photo_prev(photo_prev),
        .video_next(video_next), .video_prev(video_prev), .reload_req(1'b0),
        .any_key(k_short != 3'd0 || k_long != 3'd0), .v_shown(shown_cnt), .period_s(period_s), .photo_hold(pg_wav), .trans_cfg(trans_cfg),
        .wall_toggle(wall_toggle), .zoom_step(zoom_step), .blank_busy(blank_busy), .blank_start(blank_start),
        .thumb_slot(thumb_slot), .wall_mode(wall_mode), .wall_cell(wall_cell), .zoom(zoom), .focus_idx(focus_idx),
        .bg_load(bg_load), .booting(booting), .music_on(m_music), .wav_next(wav_next), .wav_previous(wav_previous), .aud_room(aud_room),
        .audio_drained_async(guarded_drained), .source_drained_async(sink_drained),
        .wav_selected(wav_selected), .wav_start(wav_start), .media_flush(media_flush), .media_eof(media_eof),
        .wav_error(wav_error), .wav_error_code(wav_error_code), .wav_slot(wav_slot), .session_toggle(media_session),
        .wav_state(wav_state), .wav_total(wav_total), .wav_hdr(wav_hdr), .vid_idx(vid_idx),
        .v_clear(v_clear), .v_fmt(v_fmt), .v_has_audio(v_has_audio), .mode_video(mode_video),
        .v_valid(v_valid), .v_data(v_data), .v_ready(v_ready), .fps(fps),
        .aud_valid(a_valid), .aud_data(a_data), .aud_first(a_first), .aud_ready(a_ready), .has_audio(has_audio),
        .f_valid(f_valid), .f_data(f_data), .f_ready(f_ready), .ld_start(ld_start), .ld_done(ld_done),
        .ld_err(ld_err), .img_idle(img_idle), .img_page(img_page), .show_req(show_req), .show_page(show_page),
        .show_mode(show_mode), .trans_busy(trans_busy),
        .sd_clk(sd_clk), .sd_cmd(sd_cmd), .sd_dat(sd_dat), .status(status), .pic_idx(pic_idx));

    // ---- BMP 加载(任意分辨率 -> 640×480) ----
    wire        r_valid, r_last, r_ready;
    wire [31:0] r_data;
    wire [8:0]  r_y;
    wire [15:0] src_w, src_h;
    // 仪表盘显示当前上屏图片的源尺寸: 只在前台加载完成时锁存(后台缩略加载不改)
    reg  [15:0] disp_w, disp_h;
    always @(posedge ctrl_clk or negedge crst_n)
        if (!crst_n) begin disp_w <= 16'd0; disp_h <= 16'd0; end
        else if (ld_done && !ld_err && !bg_load) begin disp_w <= src_w; disp_h <= src_h; end
    bmp_page_loader u_ld (.clk(ctrl_clk), .rst_n(crst_n), .start(ld_start), .in_valid(f_valid), .in_data(f_data),
        .in_ready(f_ready), .row_valid(r_valid), .row_data(r_data), .row_y(r_y), .row_last(r_last),
        .row_ready(r_ready), .done(ld_done), .err(ld_err), .img_w(src_w), .img_h(src_h));

    // ---- 帧存储 + 双层转场 ----
    wire        m_init, ref_overrun, o_sof, vo_hs, vo_vs, vo_de;
    wire [15:0] vo_rgb, repeat_cnt, dma_late_cnt, underflow_cnt, seek_drop_cnt;
    wire [9:0] vo_x,vo_y;
    wire vo_boundary;
    video_mem_core #(.TRANS_FRAMES(TRANS_FRAMES)) u_vmem (
        .clk(ctrl_clk), .sdram_clk(mem_clk), .rst_n(crst_n),
        .pix_clk(pixel_clk), .pix_rst(prst), .mode_video(mode_video),
        .mode_eff(mode_eff), .v_clear(v_clear), .v_pause(video_pause), .v_paused(v_paused), .v_disp_valid(v_disp_valid),
        .zoom(zoom), .wall_cell(wall_cell), .thumb_slot(thumb_slot), .blank_start(blank_start), .blank_busy(blank_busy),
        .content_fps(fps), .in_valid(v_valid), .in_data(v_data), .in_ready(v_ready),
        .img_page(img_page), .img_valid(r_valid), .img_data(r_data), .img_y(r_y),
        .img_ready(r_ready), .img_idle(img_idle),
        .show_req(show_req), .show_page(show_page), .show_mode(show_mode), .trans_busy(trans_busy),
        .o_hs(vo_hs), .o_vs(vo_vs), .o_de(vo_de), .o_rgb565(vo_rgb), .o_sof(o_sof),
        .o_x(vo_x),.o_y(vo_y),.o_frame_boundary(vo_boundary),
        .init_done(m_init), .repeat_cnt(repeat_cnt), .shown_cnt(shown_cnt),
        .dma_late_cnt(dma_late_cnt), .underflow_cnt(underflow_cnt),
        .seek_drop_cnt(seek_drop_cnt), .ref_overrun(ref_overrun));

    // ---- 音频: 空闲源保持合法零PCM；视频伴音随首个完整视频帧上屏开播 ----
    // 暂停在帧边界与页管理同拍生效(v_paused), 已缓冲样本保留, 恢复后音画对齐。
    reg play_en;
    always @(posedge pixel_clk or posedge prst)
        if (prst) play_en <= 1'b0;
        else if (o_sof) play_en <= 1'b1;
    (* async_reg="true" *) reg [1:0] vdisp_sync;
    always @(posedge pixel_clk or posedge prst)
        if (prst) vdisp_sync <= 2'b00;
        else vdisp_sync <= {vdisp_sync[0], v_disp_valid};
    wire        pcm_valid;
    wire [15:0] pcm, aud_underrun;
    wire sink_play_enable,sink_media_enable;
    av_audio_sink u_asink (
        .clk(ctrl_clk), .rst_n(crst_n), .in_valid(a_valid), .in_data(a_data), .in_first(a_first),
        .in_ready(a_ready), .pix_clk(pixel_clk), .pix_rst(prst), .play_en(sink_media_enable&&!sink_warm_hold),
        .pcm_valid(pcm_valid), .pcm(pcm), .underrun_cnt(aud_underrun),.flush_async(media_flush),.pause_async(v_paused),.end_of_stream_async(media_eof),.drained(sink_drained),.timing_tick(sink_tick),.stream_started(sink_started),.room(aud_room));

    // 音频桥(含 mclk 域 i2s_master)用独立的像素复位副本: 与 HDMI IP/转场引擎
    // 共用一个高扇出复位网络时, 工具复制网络后跨域 hold 修复插缓冲导致增量布线冲突
    (* preserve = "true" *) reg prst_aud;
    always @(posedge pixel_clk or negedge hdmi_locked)
        if (!hdmi_locked) prst_aud <= 1'b1; else prst_aud <= rs_p[1];

    wire        au_valid, acr_valid;
    wire [23:0] au_left, au_right;
    wire [19:0] acr_cts, acr_n;
    wire tone_valid,selected_valid;
    wire [23:0] selected_left,selected_right;
    wire [3:0] audio_source_token,base_source_token;
    (* async_reg="true" *) reg[2:0] media_token0,media_token1;
    always @(posedge pixel_clk or posedge prst)
        if(prst)begin media_token0<=0;media_token1<=0;end
        else begin media_token0<={media_session,wav_selected,1'b0};media_token1<=media_token0;end
    // 同track的暂停不产生新epoch；暂停状态只控制合法零PCM。
    assign audio_source_token=media_token1[1] ? {1'b1,media_token1[2:1],1'b0} : base_source_token;
    wav_continuity_guard u_media_guard(.pixel_clk(pixel_clk),.pixel_rst(prst),.owner_identity(media_token1[2:1]),
        .session_flush(media_flush),.source_drained(sink_drained),.bpoint_valid(au_valid),.hold_file(sink_warm_hold),.tail_done(guarded_drained));
    // 使用sink同一分数节拍，避免独立tone相位使串行增益收到近邻双valid。
    // pcm_valid优先，防止EOF刚置位时覆盖刚吐出的最后一个真实文件样本。
    assign guard_zero_stream=media_token1[1]&&(sink_warm_hold||sink_drained||media_token1[0]||!sink_started);
    assign playback_frame_valid=guard_zero_stream&&!pcm_valid ? sink_tick : selected_valid;
    assign playback_frame_sample=guard_zero_stream&&!pcm_valid ? 16'sd0 : $signed(selected_left[23:8]);
    assign sink_play_enable=play_en||media_token1[1];
    assign sink_media_enable=media_token1[1]||(play_en&&vdisp_sync[1]);
    // 只保留连续音频节拍，空闲样本恒零；媒体PCM通路不变。
    audio_tone_gen u_tone(.I_clk(pixel_clk),.I_rst(prst_aud),.O_audio_valid(tone_valid),
        .O_audio_left_data(),.O_audio_right_data(),.O_tone_tick());
    t072_audio_select u_audio_select(.pixel_clk(pixel_clk),.pixel_rst(prst_aud),
        .mode_video_async(mode_video||wav_selected),.has_audio_async(has_audio),.play_en(sink_play_enable),
        .media_valid(pcm_valid),.media_pcm(pcm),.tone_valid(tone_valid),.tone_left(24'd0),.tone_right(24'd0),
        .frame_valid(selected_valid),.frame_left(selected_left),.frame_right(selected_right),
        .source_token(base_source_token),.media_selected());
    wire gain_valid,gain_busy;wire signed[15:0] gain_pcm;
    wm_audio_gain u_shared_gain(.clk(pixel_clk),.rst(prst_aud),.sample_valid(playback_frame_valid),.sample(playback_frame_sample),
        .volume_steps(volume_steps_pixel<=20 ? volume_steps_pixel : 5'd20),.valid(gain_valid),.scaled(gain_pcm),.busy(gain_busy));
    audio_i2s_bridge u_abridge (
        .I_clk_pixel(pixel_clk), .I_clk_mclk(audio_mclk), .I_rst(prst_aud),
        .I_frame_valid(gain_valid), .I_frame_left({gain_pcm,8'd0}), .I_frame_right({gain_pcm,8'd0}),
        .O_audio_valid(au_valid), .O_audio_left_data(au_left), .O_audio_right_data(au_right),
        .O_acr_valid(acr_valid), .O_acr_cts(acr_cts), .O_acr_n(acr_n));

    // 完整双向链路保持原字节/CRC/epoch；PCM来源仍为I2S桥后的B点。
    wire [8:0] spec_a,spec_b,spec_a_q,spec_b_q;
    wire [7:0] spec_data_a,spec_data_b;
    wire spec_bank_a,spec_bank_b,spec_valid_a,spec_valid_b,spec_display_bank,spec_display_valid;
    wire [1:0] spec_paths;
    wire link_error,link_observation;
    wire [15:0] composed_rgb;
    assign {c1_d3_low,c1_e3_low,c1_e4_low,c1_k1_low,c1_j1_low,c1_f4_low}=6'b0;
    demo_main_link #(.OBSERVATION_ENABLE(0)) u_c1(.enabled_ctrl(1'b1),.enabled_pixel(1'b1),
        .ctrl_clk(ctrl_clk),.pixel_clk(pixel_clk),.ctrl_rst_n(crst_n),.pixel_rst_n(!prst),
        .audio_valid(au_valid),.audio_data(au_left[23:8]),.source_token(audio_source_token),
        .frame_boundary(vo_boundary),.rx_data(c1_rx_data),.render_address(spec_a),.render_data(spec_data_a),
        .render_address_q(spec_a_q),.render_bank_q(spec_bank_a),.render_valid_q(spec_valid_a),
        .render_address_b(spec_b),.render_data_b(spec_data_b),.render_address_b_q(spec_b_q),
        .render_bank_b_q(spec_bank_b),.render_valid_b_q(spec_valid_b),.display_paths(spec_paths),
        .display_bank(spec_display_bank),.tx_data(c1_tx_data),.observation(link_observation),
        .display_status_valid(spec_display_valid),.link_status_error(link_error));
    wire [15:0] spectrum_rgb;
    t073_spectrum_overlay u_spectrum(.pixel_clk(pixel_clk),.pixel_rst(prst),.frame_boundary(vo_boundary),
        .de(vo_de),.pixel_x(vo_x),.absolute_line(vo_y),.dual_requested(m_spec==2'd2&&!booting),.single_requested(m_spec==2'd1&&!booting),
        .display_valid(spec_display_valid),.display_bank(spec_display_bank),.display_paths(spec_paths),
        .read_address(spec_a),.read_data_q(spec_data_a),.read_address_q(spec_a_q),.read_bank_q(spec_bank_a),.read_valid_q(spec_valid_a),
        .read_address_b(spec_b),.read_data_b_q(spec_data_b),.read_address_b_q(spec_b_q),.read_bank_b_q(spec_bank_b),.read_valid_b_q(spec_valid_b),
        .image_rgb565(vo_rgb),.rgb565(spectrum_rgb));

    // ---- 文字叠加: 仪表盘(INFO) + 设置页(SW1) + 播放器(SW2) ----
    reg        vclr_d, wav_start_d;
    // 已送样本字计数只用于显示, 寄存一拍切断 sink 背压到文字层计时的组合路径
    reg        wav_word_q;
    always @(posedge ctrl_clk or negedge crst_n)
        if (!crst_n) wav_word_q <= 1'b0; else wav_word_q <= a_valid && a_ready && !a_first && wav_selected;
    reg [15:0] wav_scnt;
    always @(posedge ctrl_clk or negedge crst_n)
        if (!crst_n) begin vclr_d <= 1'b1; wav_start_d <= 1'b0; end
        else begin vclr_d <= v_clear; wav_start_d <= wav_start; end
    wire [1:0] osd_msg = status[7] ? 2'd1 : status[0] ? 2'd2 : status[3] ? 2'd3 : 2'd0;
    t073_osd #(.SEC_CYCLES(SEC_CYCLES)) u_osd (
        .clk(ctrl_clk), .rst_n(crst_n),
        .status_on(m_info && !booting), .menu_on(page == 2'd3 && !booting), .player_on(pg_wav && !booting),
        .focus(m_focus), .music_on(m_music), .volume(m_volume), .trans_sel(m_trans_sel), .period_s(period_s),
        .spec_sel(m_spec),
        .vid_mode(mode_video), .msg(osd_msg), .fps(fps), .fmt565(v_fmt == 2'd1),
        .v_paused(v_paused), .v_playing(v_disp_valid), .time_clear(v_clear && !vclr_d),
        .pic_idx(wall_mode ? focus_idx : pic_idx), .vid_idx(vid_idx), .wall_on(wall_mode), .zoom(zoom),
        .src_w(disp_w), .src_h(disp_h),
        .wav_slot(wav_slot), .wav_state(wav_state),
        .wav_sample(wav_word_q), .wav_new(wav_start && !wav_start_d),
        .wav_len_valid(wav_hdr), .wav_total(wav_total), .spk_only(m_spk),
        .pclk(pixel_clk), .prst(prst), .frame_boundary(vo_boundary),
        .de(vo_de), .x(vo_x), .y(vo_y), .rgb_in(spectrum_rgb), .rgb_out(composed_rgb));

    // ---- HDMI ----
    wire video_locked;
    hdmi_out u_hdmi (
        .pixel_clk(pixel_clk), .serial_clk(serial_clk), .rst(prst), .rst_phy(prst_phy),
        .i_vs(vo_vs), .i_de(vo_de), .i_rgb565(composed_rgb), .video_locked(video_locked),
        .audio_valid(au_valid), .audio_left(spk_sync[1] ? 24'd0 : au_left), .audio_right(spk_sync[1] ? 24'd0 : au_right),
        .acr_valid(acr_valid), .acr_cts(acr_cts), .acr_n(acr_n),
        .HDMI_CLK_P(HDMI_CLK_P), .HDMI_D0_P(HDMI_D0_P), .HDMI_D1_P(HDMI_D1_P), .HDMI_D2_P(HDMI_D2_P),
        .HDMI_DDC_SCL(HDMI_DDC_SCL), .HDMI_DDC_SDA(HDMI_DDC_SDA));

    // 心跳: 像素域每 32 帧翻转
    reg [5:0] hb;
    reg       vs_d;
    always @(posedge pixel_clk or posedge prst)
        if (prst) begin hb <= 6'd0; vs_d <= 1'b1; end
        else begin vs_d <= vo_vs; if (vs_d && !vo_vs) hb <= hb + 6'd1; end

    // FIXME: repeat/late/underflow 等诊断计数未引出, 综合会裁掉; 排查时经 ChipWatcher 接出
    reg disp_err;
    reg video_underflow_p,audio_underflow_p,video_started_p;
    reg[15:0] underflow_previous;
    (* async_reg="true" *) reg[1:0] vp_fault_sync,ap_fault_sync;
    always @(posedge pixel_clk or posedge prst)begin
        if(prst)begin video_underflow_p<=0;audio_underflow_p<=0;video_started_p<=0;underflow_previous<=0;end
        else begin
            underflow_previous<=underflow_cnt;
            if(o_sof)video_started_p<=1;
            if(video_started_p&&underflow_cnt!=underflow_previous)video_underflow_p<=1;
            if(audio_source_token!=1&&sink_media_enable&&aud_underrun!=0)audio_underflow_p<=1;
        end
    end
    always @(posedge ctrl_clk or negedge crst_n)begin
        if(!crst_n)begin vp_fault_sync<=0;ap_fault_sync<=0;end
        else begin vp_fault_sync<={vp_fault_sync[0],video_underflow_p};ap_fault_sync<={ap_fault_sync[0],audio_underflow_p};end
    end
    always @(posedge ctrl_clk or negedge crst_n)
        if (!crst_n) disp_err <= 1'b0;
        else if (dma_late_cnt != 0) disp_err <= 1'b1;
    assign led = {status[7] | status[3] | status[2] | status[1] | ref_overrun | disp_err | link_error | wav_error | vp_fault_sync[1] | ap_fault_sync[1],
                  status[5] ? video_ok : status[4],
                  status[6] & m_init,
                  hb[5]^link_observation};
endmodule

// 外部参考时钟上的重启单稳态，保持复位约21ms；松键稳定后才允许下一次。
module t073_restart_guard (
    input wire clk, rst_n,
    input wire request_async, key_n_async,
    output wire system_rst_n
);
    (* async_reg = "true" *) reg [1:0] request_sync, key_sync;
    reg active, armed;
    reg [19:0] count;
    assign system_rst_n = rst_n && !active;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            request_sync <= 0; key_sync <= 2'b11;
            active <= 0; armed <= 1; count <= 0;
        end else begin
            request_sync <= {request_sync[0], request_async};
            key_sync <= {key_sync[0], key_n_async};
            if (active) begin
                count <= count + 20'd1;
                if (&count) begin active <= 0; count <= 0; end
            end else if (!armed) begin
                if (!key_sync[1] || request_sync[1]) count <= 0;
                else if (&count) begin armed <= 1; count <= 0; end
                else count <= count + 20'd1;
            end else if (request_sync[1]) begin
                active <= 1; armed <= 0; count <= 20'd0;
            end
        end
endmodule
