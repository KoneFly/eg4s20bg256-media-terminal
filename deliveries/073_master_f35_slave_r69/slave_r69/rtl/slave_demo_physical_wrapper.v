// 板级端口瘦封装：只带既有KEY/link/LED与冻结的六根麦克风IO。
`timescale 1ns/1ps
module slave_demo_physical_wrapper #(
    parameter [26:0] PANEL_KEY_LONG_LAST=27'd39_999_999,
    parameter [19:0] PANEL_SWITCH_LAST=20'd999_999,
    parameter [15:0] SEG_SCAN_LAST=16'd49_999,
    parameter SEG_REVERSE_DIGITS=1'b0
) (
    input  wire       clk_50,
    input  wire       key1,
    input  wire       key2,
    input  wire       key3,key4,
    input  wire [3:0] sw,
    output wire [7:0] seg_data,
    output wire [5:0] seg_sel,
    input  wire       link_rx_data,
    input  wire [3:0] mic_sd,
    output wire       mic_bclk,
    output wire       mic_lrck,
    output wire       audio_din,
    output wire       link_tx_data,
    output wire [3:0] return_low,
    output wire [3:0] led,
    output wire uart_tx
);
    wire [31:0] diag_fault_bits;wire [15:0] diag_step,diag_warm,diag_ready,diag_crc_s,diag_crc_f;
    wire [7:0] diag_qualifiers,diag_count_s,diag_count_f;wire [47:0] diag_primary,diag_virtual;
    wire [17:0] diag_rom_max;wire signed [17:0] diag_rom_q;
    wire clk_50m;
    wire key2_press;
    wire key2_stable,key3_stable,key4_stable;
    wire key3_press,key4_press;
    wire reset_release_n;
    wire spectrum_link_sync;
    wire spectrum_link_clk;
    wire mic_capture_valid;
    wire [15:0] mic0_pcm, mic1_pcm, mic2_pcm, mic3_pcm;
    wire mic_pair_valid;
    wire [31:0] mic_pair_sample_index;
    wire signed [15:0] mic_pair_raw, mic_pair_filtered;
    wire active_notch_enable;
    wire [12:0] mic_pairs_since_history_reset;
    wire notch_busy, notch_overrun;
    wire pcm_rx_locked;
    wire [7:0] pcm_transport_errors;
    wire [15:0] pcm_transport_lost;
    wire pcm_rx_fault;
    wire [15:0] pcm_accepted_blocks, pcm_rejected_blocks;
    wire fft_group_start, fft_group_active, fft_group_done;
    wire [31:0] fft_group_epoch, fft_group_end_sample;
    wire fft_path_source_end_valid;
    wire [31:0] fft_path_source_end_index;
    wire fft_fault;
    wire [3:0] fft_fault_reason;
    wire [1:0] fft_path_index;
    wire fft_bin_valid;
    wire [6:0] fft_bin_index;
    wire [7:0] fft_bin_data;
    wire fft_busy;
    wire fft_debug_valid;
    wire [11:0] fft_debug_index;
    wire signed [15:0] fft_debug_re, fft_debug_im;
    wire spectrum_tx_fault;
    wire [31:0] spectrum_sent_packets_total, spectrum_sent_groups_total;
    wire [15:0] spectrum_group_cancel_count;
    wire demo_fault;
    wire [1:0] mode_requested;
    reg [1:0] mode_active;
    wire mode_conflict,anc_armed,anc_command,panel_anc_command,auto_mode,recapture_request;
    reg active_auto;
    wire [31:0] anc_reference_increment,anc_tracking_increment;
    wire [13:0] tracked_frequency_hz;
    wire fll_busy=1'b0; // 旧固定微追退休，仅保留台架观察口。
    reg anc_core_enable_q,anc_core_command_q,anc_core_sample_valid_q;
    wire anc_limit_reached;
    wire run_guard_fault;wire [2:0] run_guard_code;wire [13:0] run_guard_anchor_hz;
    reg signed [15:0] anc_core_error_q;
    wire anc_core_ready,anc_core_calibrating,anc_core_fault,anc_core_sample_out_valid;
    wire signed [15:0] anc_core_sample_out;
    wire anc_sample_out_valid,anc_ready,anc_calibrating,anc_fault;
    wire [1:0] anc_tone_select;
    wire [13:0] fixed_frequency_hz;
    reg anc_bclk_d,anc_lrck_d;
    reg fx_selected;
    wire playback_block_start,playback_history_reset,playback_word_valid;
    wire [31:0] playback_word_data;
    wire tf_sample_valid,tf_playing,tf_fault;
    wire signed [15:0] tf_sample;
    wire signed [15:0] anc_sample_out;
    reg [24:0] led_scan_count;
    reg [1:0] led_lane_select;
    reg lane0_nonzero_frames;
    reg lane1_nonzero_frames;
    reg lane2_nonzero_frames;
    reg lane3_nonzero_frames;
    reg selected_lane_count;

 reg fx_running,fx_restart;reg [15:0] control_id;
 reg fx_clear;
 wire fv,frontend_ready;wire signed [15:0] fe,fr;wire [1:0] filter_clipped;wire filter_overlap;
 wire core_ready,core_zero,core_done,submit,core_fault,actuator_fault,pair_overrun,core_clipped;
 wire [15:0] command_frame;wire signed [17:0] command;wire signed [15:0] fx_word;
 wire [3:0] guard_state,guard_reason,actuator_reason;
 wire [15:0] unused_native_group;wire [1:0] unused_native_phase;
 wire unused_weight_write,unused_adapt,unused_band;wire [7:0] unused_weight_address;
 wire signed [31:0] unused_weight,unused_gradient;wire [24:0] unused_gain;wire signed [15:0] unused_virtual;
 wire [47:0] unused_ep,unused_rp;wire [12:0] unused_elapsed,unused_maximum;
    (* async_reg = "true" *) reg key1_meta = 1'b1;
    (* async_reg = "true" *) reg key1_sync = 1'b1;
    reg [15:0] startup = 16'd0;
    wire board_reset_n = (&startup) && key1_sync;

    localparam [1:0] MODE_OFF=0,MODE_LIVE=1,MODE_TF=2,MODE_ANC=3;

    // 固定链命令不依赖 AUTO 捕峰资格。
    assign anc_command=panel_anc_command&&!active_auto;
    wire [13:0] base_frequency_hz=fixed_frequency_hz;
    wire [13:0] frequency_hz;
    assign anc_tracking_increment=anc_reference_increment;
    assign tracked_frequency_hz=base_frequency_hz;
    wire anc_frame_start=anc_bclk_d&&!mic_bclk&&anc_lrck_d&&!mic_lrck;
    wire audio_mode_pending=mode_requested!=mode_active||(mode_active==MODE_ANC&&auto_mode!=active_auto);
    wire anc_active=mode_active==MODE_ANC;
    wire tf_active=mode_active==MODE_TF;
    wire anc_enabled=anc_active&&!audio_mode_pending&&anc_armed&&!mode_conflict&&!active_auto;
    always @(posedge clk_50m or negedge reset_release_n)begin
        if(!reset_release_n)fx_selected<=0;
        else fx_selected<=anc_active&&!audio_mode_pending&&!mode_conflict&&active_auto;
    end
    wire anc_tx_valid=!audio_mode_pending&&
        (mode_active==MODE_LIVE ? mic_pair_valid : tf_active ? tf_sample_valid :
         fx_selected ? mic_capture_valid : anc_enabled ? anc_sample_out_valid : mic_capture_valid);
    wire signed [15:0] anc_tx_left=mode_active==MODE_LIVE ? mic_pair_raw :
        tf_active ? tf_sample : fx_selected ? fx_word : anc_enabled ? anc_sample_out : 16'sd0;
    wire signed [15:0] anc_tx_right=anc_tx_left;

    // 保留原顶层GCLK和KEY1两级同步/启动等待；不实例化PLL。
    EG_PHY_GCLK u_clock (.clki(clk_50), .clko(clk_50m));
    always @(posedge clk_50m) begin
        key1_meta <= key1;
        key1_sync <= key1_meta;
        if (!key1_sync)
            startup <= 16'd0;
        else if (!(&startup))
            startup <= startup + 16'd1;
    end

    key_press_debounce #(.CLK_FREQ_HZ(50_000_000), .DEBOUNCE_MS(20)) u_key2_debounce (
        .clk(clk_50m), .rst_n(board_reset_n), .button_in(key2),
        .press_pulse(key2_press), .button_stable_out(key2_stable)
    );

    key_press_debounce #(.CLK_FREQ_HZ(50_000_000),.DEBOUNCE_MS(20)) u_key3_debounce(
        .clk(clk_50m),.rst_n(board_reset_n),.button_in(key3),.press_pulse(key3_press),.button_stable_out(key3_stable));
    key_press_debounce #(.CLK_FREQ_HZ(50_000_000),.DEBOUNCE_MS(20)) u_key4_debounce(
        .clk(clk_50m),.rst_n(board_reset_n),.button_in(key4),.press_pulse(key4_press),.button_stable_out(key4_stable));
    slave_panel_ctrl #(.SWITCH_STABLE_LAST(PANEL_SWITCH_LAST),.KEY_LONG_LAST(PANEL_KEY_LONG_LAST)) u_panel(
        .clk(clk_50m),.rst_n(reset_release_n),.switches_async(sw),
        .key_down({!key4_stable,!key3_stable,!key2_stable}),
        .anc_ready(anc_ready),.anc_calibrating(anc_calibrating),.anc_fault(anc_fault),
        .mode_request(mode_requested),.mode_conflict(mode_conflict),.auto_mode(auto_mode),.recapture_request(recapture_request),.anc_armed(anc_armed),
        .anc_command(panel_anc_command),.tone_select(anc_tone_select),.frequency_hz(fixed_frequency_hz));
    // R66显示仅使用独立MIC2实测主峰；不参与固定档或Fx控制。
    wire display_enable=anc_active&&!audio_mode_pending&&!mode_conflict;
    wire frequency_valid,frequency_update;
    wire [9:0] measured_frequency_hz;
    wire frequency_capture_request,frequency_capture_accept,frequency_capture_done,frequency_capture_abort;
    wire [11:0] frequency_capture_address,frequency_fft_index;
    wire signed [15:0] frequency_capture_sample,frequency_fft_re,frequency_fft_im;
    wire frequency_fft_valid;
    assign frequency_hz={4'd0,measured_frequency_hz};
    mic2_frequency_display_r66 u_frequency_measure(
        .clk(clk_50m),.rst_n(reset_release_n),.enable(display_enable),
        .sample_valid(mic_capture_valid),.sample_data($signed(mic1_pcm)),
        .capture_request(frequency_capture_request),.capture_sample(frequency_capture_sample),
        .capture_accept(frequency_capture_accept),.capture_done(frequency_capture_done),.capture_abort(frequency_capture_abort),
        .capture_read_address(frequency_capture_address),.fft_valid(frequency_fft_valid),.fft_index(frequency_fft_index),
        .fft_re(frequency_fft_re),.fft_im(frequency_fft_im),
        .frequency_valid(frequency_valid),.frequency_update(frequency_update),.frequency_hz(measured_frequency_hz));
    seg6_hz_display_r66 #(.SCAN_LAST(SEG_SCAN_LAST),.REVERSE_DIGITS(SEG_REVERSE_DIGITS)) u_frequency_display(
        .clk(clk_50m),.rst_n(reset_release_n),.display_enable(display_enable),
        .frequency_valid(frequency_valid),.frequency_hz(measured_frequency_hz),.seg_data(seg_data),.seg_sel(seg_sel));

    slave_audio_demo_top u_demo (
        // 私有作业只供MIC2实时频率显示，公共三路谱数据含义保持。
        .capture_request(frequency_capture_request),.capture_sample(frequency_capture_sample),.capture_read_address(frequency_capture_address),
        .capture_accept(frequency_capture_accept),.capture_done(frequency_capture_done),.capture_fft_valid(frequency_fft_valid),.capture_abort(frequency_capture_abort),
        .capture_fft_index(frequency_fft_index),.capture_fft_re(frequency_fft_re),.capture_fft_im(frequency_fft_im),
        .clk_50m(clk_50m), .rst_n(board_reset_n),
        .reset_release_n(reset_release_n),
        .pcm_link_data(link_rx_data), .mic_sd(mic_sd),
        .mic_bclk(mic_bclk), .mic_lrck(mic_lrck),
        .mic_capture_valid(mic_capture_valid), .mic0_pcm(mic0_pcm), .mic1_pcm(mic1_pcm),
        .mic2_pcm(mic2_pcm), .mic3_pcm(mic3_pcm), .mic_pair_valid(mic_pair_valid),
        .mic_pair_sample_index(mic_pair_sample_index), .mic_pair_raw(mic_pair_raw),
        .mic_pair_filtered(mic_pair_filtered), .active_notch_enable(active_notch_enable),
        .mic_pairs_since_history_reset(mic_pairs_since_history_reset), .notch_busy(notch_busy),
        .notch_overrun(notch_overrun),
        .playback_block_start(playback_block_start),.playback_history_reset(playback_history_reset),
        .playback_word_valid(playback_word_valid),.playback_word_data(playback_word_data),
        .pcm_rx_locked(pcm_rx_locked),
        .pcm_transport_errors(pcm_transport_errors), .pcm_transport_lost(pcm_transport_lost),
        .pcm_rx_fault(pcm_rx_fault), .pcm_accepted_blocks(pcm_accepted_blocks),
        .pcm_rejected_blocks(pcm_rejected_blocks), .fft_group_start(fft_group_start),
        .fft_group_active(fft_group_active), .fft_group_done(fft_group_done),
        .fft_group_epoch(fft_group_epoch), .fft_group_end_sample(fft_group_end_sample),
        .fft_path_source_end_valid(fft_path_source_end_valid), .fft_path_source_end_index(fft_path_source_end_index),
        .fft_fault(fft_fault), .fft_fault_reason(fft_fault_reason), .fft_path_index(fft_path_index),
        .fft_bin_valid(fft_bin_valid), .fft_bin_index(fft_bin_index), .fft_bin_data(fft_bin_data),
        .fft_busy(fft_busy), .fft_debug_valid(fft_debug_valid), .fft_debug_index(fft_debug_index),
        .fft_debug_re(fft_debug_re), .fft_debug_im(fft_debug_im),
        .spectrum_link_data(link_tx_data), .spectrum_link_sync(spectrum_link_sync),
        .spectrum_link_clk(spectrum_link_clk), .spectrum_tx_fault(spectrum_tx_fault),
        .spectrum_sent_packets_total(spectrum_sent_packets_total),
        .spectrum_sent_groups_total(spectrum_sent_groups_total),
        .spectrum_group_cancel_count(spectrum_group_cancel_count), .demo_fault(demo_fault)
    );

    // 控制事务同步延后一拍；保持使能、命令和同一ADC样本对应，输出资格仍即时关闭。
    always @(posedge clk_50m or negedge reset_release_n)begin
        if(!reset_release_n)begin anc_core_enable_q<=0;anc_core_command_q<=0;anc_core_sample_valid_q<=0;anc_core_error_q<=0;end
        else begin anc_core_enable_q<=anc_enabled;anc_core_command_q<=anc_command;anc_core_sample_valid_q<=mic_capture_valid;anc_core_error_q<=$signed(mic0_pcm);end
    end
    assign anc_sample_out=anc_enabled&&!anc_command&&!anc_core_command_q&&!run_guard_fault ? anc_core_sample_out : 16'sd0;
    assign anc_sample_out_valid=anc_enabled&&!anc_command&&!anc_core_command_q&&anc_core_sample_out_valid;
    assign anc_ready=fx_selected?fx_running&&guard_state==4:anc_enabled&&anc_core_ready;
    assign anc_calibrating=fx_selected?fx_running&&(guard_state==1||guard_state==2||guard_state==3||guard_state==5):anc_enabled&&anc_core_calibrating;
    assign anc_fault=fx_selected?fx_running&&(core_fault||guard_state==6||guard_state==7||actuator_fault):anc_enabled&&anc_core_fault;
    // 非ANC左右均实时RAW；ANC左右均y[n]，原I2S位序器不改。
    anc_weak_path_frequency u_anc (
        .clk(clk_50m), .rst_n(reset_release_n), .enable(anc_core_enable_q),
        .command(anc_core_command_q), .tone_select(anc_tone_select),
        .override_enable(1'b0),.override_increment(32'd0),
        .tracking_increment(anc_tracking_increment),.reference_increment(anc_reference_increment),
        .weight_c_state(),.weight_s_state(),.adaptation_done(),.limit_reached(anc_limit_reached),.sample_valid(anc_core_sample_valid_q),
        .error_sample(anc_core_error_q),
        .basis_sine(),.basis_cosine(),.basis_valid(),
        .sample_out_valid(anc_core_sample_out_valid), .sample_out(anc_core_sample_out),
        .ready(anc_core_ready), .calibrating(anc_core_calibrating), .fault(anc_core_fault)
    );

    // 固定档按预设参数运行; 实时通路直接使用 MIC1/MIC2。
    anc_run_guard_r56 u_run_guard(.clk(clk_50m),.rst_n(reset_release_n),.clear(!anc_enabled||anc_command||anc_core_command_q),
        .run(anc_ready),.sample_valid(mic_capture_valid),.auto_mode(1'b0),.tone_select(anc_tone_select),
        .center_increment(anc_reference_increment),.configured_increment(anc_reference_increment),
        .tracked_increment(anc_tracking_increment),.center_hz(base_frequency_hz),.tracked_hz(tracked_frequency_hz),
        .fault(run_guard_fault),.fault_code(run_guard_code),.anchor_hz(run_guard_anchor_hz));

    // R64等价 Fx 子系统：核心、滤波、队列算术及时间戳不变。
 always @(posedge clk_50m or negedge reset_release_n)begin
  if(!reset_release_n)fx_clear<=1;
  else fx_clear<=!fx_selected||!anc_armed||fx_restart;
 end
 always @(posedge clk_50m or negedge reset_release_n)begin
  if(!reset_release_n)begin fx_running<=0;fx_restart<=0;end
  else begin
   fx_restart<=0;
   if(!fx_selected||!anc_armed)fx_running<=0;
   else if(panel_anc_command||recapture_request)begin fx_running<=!fx_running;fx_restart<=1;end
  end
 end
 anc_ram_decimator_r61 frontend(.clk(clk_50m),.rst_n(reset_release_n),.start(fx_clear),.enable(fx_selected&&fx_running),.pcm_valid(mic_capture_valid),.mic0(mic0_pcm),.mic1(mic1_pcm),.ready(frontend_ready),.valid(fv),.sample0(fe),.sample1(fr),.clipped(filter_clipped),.overlap(filter_overlap));
 always @(posedge clk_50m or negedge reset_release_n)begin if(!reset_release_n)control_id<=0;else if(fx_clear)control_id<=0;else if(fv)control_id<=control_id+16'd1;end
 wire native_clip=mic_capture_valid&&($signed(mic0_pcm)>30000||$signed(mic0_pcm)< -30000||$signed(mic1_pcm)>30000||$signed(mic1_pcm)< -30000);
 wire fx_native_fault=native_clip||pair_overrun||(!fx_clear&&(actuator_fault||filter_overlap||(fv&&filter_clipped!=0)));
 anc_fxn_core_r61 core(.clk(clk_50m),.rst_n(reset_release_n),.clear(fx_clear),.mode_enabled(fx_selected&&anc_armed&&fx_running),.stop(1'b0),.model_valid(1'b1),.model_epoch(16'd66),.native_fault(fx_native_fault),
 .sample_valid(fv&&fx_selected&&fx_running&&!fx_clear),.frame_id(control_id),.error_pcm(fe),.reference_pcm(fr),.ready(core_ready),.force_zero(core_zero),.sample_done(core_done),.command_submit(submit),.command_frame(command_frame),.command(command),.guard_state(guard_state),.guard_reason(guard_reason),
 .debug_weight_write(unused_weight_write),.debug_weight_address(unused_weight_address),.debug_weight(unused_weight),.debug_adapt(unused_adapt),.debug_gain(unused_gain),.debug_virtual(unused_virtual),.debug_band(unused_band),.debug_clipped(core_clipped),.debug_gradient(unused_gradient),.debug_error_power(unused_ep),.debug_reference_power(unused_rp),.elapsed_clocks(unused_elapsed),.maximum_clocks(unused_maximum),.kernel_fault(core_fault),.diagnostic_fault_bits(diag_fault_bits),.diagnostic_step(diag_step),
 .diagnostic_qualifiers(diag_qualifiers),.diagnostic_warm(diag_warm),.diagnostic_ready(diag_ready),
 .diagnostic_primary(diag_primary),.diagnostic_virtual(diag_virtual),
 .diagnostic_crc_s(diag_crc_s),.diagnostic_crc_f(diag_crc_f),.diagnostic_count_s(diag_count_s),.diagnostic_count_f(diag_count_f),
 .diagnostic_rom_max(diag_rom_max),.diagnostic_rom_q(diag_rom_q));
 anc_native_actuator_r61 actuator(.clk(clk_50m),.rst_n(reset_release_n),.clear(fx_clear||!frontend_ready),.native_valid(mic_capture_valid&&frontend_ready),.force_zero(core_zero||!fx_running||!fx_selected),.submit(submit),.frame_id(command_frame),.command(command),.native_word(fx_word),.native_group(unused_native_group),.native_phase(unused_native_phase),.fault(actuator_fault),.reason(actuator_reason));

    tf_pcm_player u_tf_player(
        .clk(clk_50m),.rst_n(reset_release_n),
        .selected(tf_active&&!anc_active&&!audio_mode_pending),.frame_tick(mic_capture_valid),
        .block_start(playback_block_start),.history_reset(playback_history_reset),
        .word_valid(playback_word_valid),.word_data(playback_word_data),
        .input_fault(pcm_rx_fault||pcm_transport_errors!=0||pcm_transport_lost!=0),
        .sample_valid(tf_sample_valid),.sample_data(tf_sample),.playing(tf_playing),.fault(tf_fault),
        .underflow(),.overflow(),.level());

    // 只在原I2S R->L边界提交新模式；切离ANC先关使能，旧pair保持完整。
    always @(posedge clk_50m or negedge reset_release_n)begin
        if(!reset_release_n)begin mode_active<=MODE_OFF;active_auto<=0;anc_bclk_d<=0;anc_lrck_d<=1;end
        else begin
            anc_bclk_d<=mic_bclk;anc_lrck_d<=mic_lrck;
            if(anc_frame_start)begin mode_active<=mode_requested;active_auto<=auto_mode;end
        end
    end

    audio_i2s_stereo_tx_r12 u_audio_output (
        .clk_50m(clk_50m), .rst_n(reset_release_n),
        .mic_bclk(mic_bclk), .mic_lrck(mic_lrck),
        .mic_pair_valid(anc_tx_valid), .mic_pair_raw(anc_tx_left),
        .mic_pair_filtered(anc_tx_right),
        .audio_din(audio_din), .pair_overrun(pair_overrun)
    );

    // 保留四麦与链路诊断；音色控制寄存器已移除。
    always @(posedge clk_50m or negedge reset_release_n) begin
        if (!reset_release_n) begin
            led_scan_count <= 25'd0;
            led_lane_select <= 2'd0;
            lane0_nonzero_frames <= 1'b0;
            lane1_nonzero_frames <= 1'b0;
            lane2_nonzero_frames <= 1'b0;
            lane3_nonzero_frames <= 1'b0;
        end else begin
            if (led_scan_count == 25'd24_999_999) begin
                led_scan_count <= 25'd0;
                led_lane_select <= led_lane_select + 2'd1;
            end else begin
                led_scan_count <= led_scan_count + 25'd1;
            end
            if (mic_capture_valid) begin
                if (mic0_pcm != 16'd0) lane0_nonzero_frames <= ~lane0_nonzero_frames;
                if (mic1_pcm != 16'd0) lane1_nonzero_frames <= ~lane1_nonzero_frames;
                if (mic2_pcm != 16'd0) lane2_nonzero_frames <= ~lane2_nonzero_frames;
                if (mic3_pcm != 16'd0) lane3_nonzero_frames <= ~lane3_nonzero_frames;
            end
        end
    end

    assign return_low = 4'b0000;

    always @* begin
        case (led_lane_select)
            2'd0: selected_lane_count = lane0_nonzero_frames;
            2'd1: selected_lane_count = lane1_nonzero_frames;
            2'd2: selected_lane_count = lane2_nonzero_frames;
            default: selected_lane_count = lane3_nonzero_frames;
        endcase
    end

    // 四麦轮询与链路活动保留; 不改变故障/PCM/FFT 消费路径。
    assign led = anc_active ?
                  {demo_fault | anc_fault | tf_fault | mode_conflict | run_guard_fault, anc_calibrating, anc_ready, anc_armed} :
                  {demo_fault | tf_fault | mode_conflict, tf_active, pcm_rx_locked,
                  tf_active ? tf_playing : (selected_lane_count ^ spectrum_sent_packets_total[0] ^ spectrum_sent_groups_total[0])};

 // R68只读观察；快测只记录故障、阶段、资格和双麦瞬时PCM。
 wire [7:0] diag_native_flags={1'b0,actuator_fault,pair_overrun,
     (!fx_clear&&filter_overlap),(!fx_clear&&fv&&filter_clipped[1]),(!fx_clear&&fv&&filter_clipped[0]),
     (mic_capture_valid&&($signed(mic1_pcm)>30000||$signed(mic1_pcm)< -30000)),
     (mic_capture_valid&&($signed(mic0_pcm)>30000||$signed(mic0_pcm)< -30000))};
 wire [127:0] diag_live={mic1_pcm,mic0_pcm,diag_qualifiers,diag_native_flags,diag_step,diag_fault_bits,
     guard_reason,guard_state,4'd0,led,
     mode_conflict,audio_mode_pending,fx_selected,fx_running,anc_armed,fx_clear,anc_ready,anc_calibrating,4'd0,sw};
 wire [127:0] diag_first;wire diag_first_valid;
 anc_first_fault_snapshot_r68 first_fault_recorder(.clk(clk_50m),.rst_n(reset_release_n),
  .enabled(fx_selected&&anc_armed&&fx_running),.fault_bits(diag_fault_bits),.live_payload(diag_live),
  .first_payload(diag_first),.first_valid(diag_first_valid));
 anc_uart_snapshot_r68 diagnostic_uart(.clk(clk_50m),.rst_n(reset_release_n),.live_payload(diag_live),
  .first_payload(diag_first),.first_valid(diag_first_valid),.tx(uart_tx),.window_tick());
endmodule
