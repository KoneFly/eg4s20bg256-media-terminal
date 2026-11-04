// 副板现场采集与三路频谱演示顶层候选。
// 只用50MHz控制时钟；不实例化PLL、板载BUZZER或额外ADC/DAC。
`timescale 1ns/1ps
module slave_audio_demo_top (
    input wire capture_request,
    input wire signed [15:0] capture_sample,
    output wire [11:0] capture_read_address,
    output wire capture_accept,capture_done,capture_fft_valid,capture_abort,
    output wire [11:0] capture_fft_index,
    output wire signed [15:0] capture_fft_re,capture_fft_im,
    input  wire        clk_50m,
    input  wire        rst_n,
    input  wire        pcm_link_data,
    input  wire [3:0]  mic_sd,

    // 板级wrapper内部reset观察口；不映射到物理pad。
    output wire        reset_release_n,

    output wire        mic_bclk,
    output wire        mic_lrck,
    output wire        mic_capture_valid,
    output wire [15:0] mic0_pcm,
    output wire [15:0] mic1_pcm,
    output wire [15:0] mic2_pcm,
    output wire [15:0] mic3_pcm,

    output wire        mic_pair_valid,
    output wire [31:0] mic_pair_sample_index,
    output wire signed [15:0] mic_pair_raw,
    output wire signed [15:0] mic_pair_filtered,
    output wire        active_notch_enable,
    output wire [12:0] mic_pairs_since_history_reset,
    output wire        notch_busy,
    output wire        notch_overrun,

    output wire playback_block_start,playback_history_reset,playback_word_valid,
    output wire [31:0] playback_word_data,
    output wire        pcm_rx_locked,
    output wire [7:0]  pcm_transport_errors,
    output wire [15:0] pcm_transport_lost,
    output wire        pcm_rx_fault,
    output wire [15:0] pcm_accepted_blocks,
    output wire [15:0] pcm_rejected_blocks,

    output wire        fft_group_start,
    output wire        fft_group_active,
    output wire        fft_group_done,
    output wire [31:0] fft_group_epoch,
    output wire [31:0] fft_group_end_sample,
    output wire        fft_path_source_end_valid,
    output wire [31:0] fft_path_source_end_index,
    output wire        fft_fault,
    output wire [3:0]  fft_fault_reason,
    output wire [1:0]  fft_path_index,
    output wire        fft_bin_valid,
    output wire [6:0]  fft_bin_index,
    output wire [7:0]  fft_bin_data,
    output wire        fft_busy,
    output wire        fft_debug_valid,
    output wire [11:0] fft_debug_index,
    output wire signed [15:0] fft_debug_re,
    output wire signed [15:0] fft_debug_im,

    output wire        spectrum_link_data,
    output wire        spectrum_link_sync,
    output wire        spectrum_link_clk,
    output wire        spectrum_tx_fault,
    output wire [31:0] spectrum_sent_packets_total,
    output wire [31:0] spectrum_sent_groups_total,
    output wire [15:0] spectrum_group_cancel_count,
    output wire        demo_fault
);

    wire pcm_block_start;
    wire pcm_history_reset;
    wire [31:0] pcm_block_epoch;
    wire [31:0] pcm_block_first;
    wire pcm_word_valid;
    wire [31:0] pcm_word_data;

    // PCM block边界与数据统一延迟两拍，确保顶层边界清窗复位释放后，
    // scheduler先看到完整的history_reset/block_start，再接收对应word流。
    reg pcm_block_start_d0, pcm_block_start_d1;
    reg pcm_history_reset_d0, pcm_history_reset_d1;
    reg [31:0] pcm_block_epoch_d0, pcm_block_epoch_d1;
    reg [31:0] pcm_block_first_d0, pcm_block_first_d1;
    reg pcm_word_valid_d0, pcm_word_valid_d1;
    reg [31:0] pcm_word_data_d0, pcm_word_data_d1;
    reg pcm_boundary_ready;

    wire capture_valid;
    wire capture_event;
    wire [15:0] capture_mic0;
    wire [15:0] capture_mic1;
    wire [15:0] capture_mic2;
    wire [15:0] capture_mic3;
    wire mean_sample_valid;
    wire mean_sample_pending;
    wire signed [15:0] mean_sample;

    wire mic_path_rst_n;
    reg mic_reset_pulse;
    reg raw_pair_valid;
    reg signed [15:0] raw_pair_sample;
    reg [31:0] raw_pair_index;
    wire scheduler_rst_n;
    wire group_available;
    wire fft_fault_live;
    wire [3:0] fft_fault_reason_live;

    wire tx_capturing;
    wire tx_group_ready;
    wire tx_capture_available;
    wire tx_fault;
    wire [15:0] tx_sent_packets;
    wire [15:0] tx_sent_groups;
    wire [15:0] tx_capture_aborts;
    wire tx_capture_abort;

    reg [31:0] mic_sample_index;
    reg [12:0] warm_pair_count;
    reg scheduler_reset_pulse;
    reg fft_fault_sticky;
    reg [3:0] fft_fault_reason_sticky;
    reg capture_rst_meta;
    reg capture_rst_n;
    reg control_rst_meta;
    reg control_rst_n;
    wire [7:0] pcm_transport_errors_unused;
    wire [15:0] pcm_transport_lost_unused;
    wire [15:0] accepted_blocks_unused;
    wire [15:0] rejected_blocks_unused;
    wire pcm_locked_unused;
    wire pcm_fault_unused;

    assign mic_capture_valid = capture_valid;
    assign mic0_pcm = capture_mic0;
    assign mic1_pcm = capture_mic1;
    assign mic2_pcm = capture_mic2;
    assign mic3_pcm = capture_mic3;
    assign active_notch_enable = 1'b0;
    assign mic_pairs_since_history_reset = warm_pair_count;
    assign mic_pair_valid = raw_pair_valid;
    assign mic_pair_sample_index = raw_pair_index;
    assign mic_pair_raw = raw_pair_sample;
    assign mic_pair_filtered = raw_pair_sample;
    assign notch_busy = 1'b0;
    assign notch_overrun = 1'b0;
    assign fft_fault = fft_fault_live || fft_fault_sticky;
    assign fft_fault_reason = fft_fault_sticky ? fft_fault_reason_sticky : fft_fault_reason_live;
    assign spectrum_tx_fault = tx_fault;
    assign spectrum_sent_packets_total = {16'd0, tx_sent_packets};
    assign spectrum_sent_groups_total = {16'd0, tx_sent_groups};
    assign spectrum_group_cancel_count = tx_capture_aborts;
    assign demo_fault = pcm_fault_unused || (pcm_transport_errors_unused != 8'd0) ||
                        (pcm_transport_lost_unused != 16'd0) || fft_fault || tx_fault ||
                        (tx_capture_aborts != 16'd0);

    assign reset_release_n = capture_rst_n;
    assign capture_abort = !scheduler_rst_n;

    // PCM切段保持两拍边界/数据对齐；取消音色切换清窗分支。
    always @(posedge clk_50m or negedge control_rst_n) begin
        if (!control_rst_n) begin
            pcm_block_start_d0 <= 1'b0;
            pcm_block_start_d1 <= 1'b0;
            pcm_history_reset_d0 <= 1'b0;
            pcm_history_reset_d1 <= 1'b0;
            pcm_block_epoch_d0 <= 32'd0;
            pcm_block_epoch_d1 <= 32'd0;
            pcm_block_first_d0 <= 32'd0;
            pcm_block_first_d1 <= 32'd0;
            pcm_word_valid_d0 <= 1'b0;
            pcm_word_valid_d1 <= 1'b0;
            pcm_word_data_d0 <= 32'd0;
            pcm_word_data_d1 <= 32'd0;
        end else begin
            pcm_block_start_d0 <= pcm_block_start;
            pcm_block_start_d1 <= pcm_block_start_d0;
            pcm_history_reset_d0 <= pcm_history_reset;
            pcm_history_reset_d1 <= pcm_history_reset_d0;
            pcm_block_epoch_d0 <= pcm_block_epoch;
            pcm_block_epoch_d1 <= pcm_block_epoch_d0;
            pcm_block_first_d0 <= pcm_block_first;
            pcm_block_first_d1 <= pcm_block_first_d0;
            pcm_word_valid_d0 <= pcm_word_valid;
            pcm_word_valid_d1 <= pcm_word_valid_d0;
            pcm_word_data_d0 <= pcm_word_data;
            pcm_word_data_d1 <= pcm_word_data_d0;
        end
    end
    assign mic_path_rst_n = capture_rst_n && !mic_reset_pulse;
    assign scheduler_rst_n = control_rst_n && !scheduler_reset_pulse;

    // 038/062串行上行只接PCM块接收器；它内部例化冻结067 interboard_rx。
    link062_pcm_rx u_pcm_rx (
        .clk(clk_50m), .rst_n(control_rst_n), .serial_data(pcm_link_data),
        .locked(pcm_locked_unused), .transport_errors(pcm_transport_errors_unused),
        .transport_lost(pcm_transport_lost_unused),
        .block_start(pcm_block_start), .history_reset(pcm_history_reset),
        .block_epoch(pcm_block_epoch), .block_first(pcm_block_first),
        .word_valid(pcm_word_valid), .word_data(pcm_word_data),
        .fault(pcm_fault_unused), .accepted_blocks(accepted_blocks_unused),
        .rejected_blocks(rejected_blocks_unused)
    );

    // 四路I2S均保留外部可观察；融合只取已接入的MIC2/3/4 (pcm1/2/3)。
    i2s_mic4_rx_50m u_mic_capture (
        .clk_50m(clk_50m), .rst_n(capture_rst_n), .mic_sd(mic_sd),
        .mic_bclk(mic_bclk), .mic_lrck(mic_lrck), .pcm_valid(capture_valid),
        .pcm0(capture_mic0), .pcm1(capture_mic1), .pcm2(capture_mic2), .pcm3(capture_mic3),
        .pcm_capture_event(capture_event)
    );

    // 固定一拍均值流水；公共valid保证三路取自同一I2S采样时刻。
    mic_three_mean_t16 u_mic_mean (
        .clk(clk_50m), .rst_n(mic_path_rst_n),
        .sample_valid_in(capture_valid),
        .pcm1(capture_mic1), .pcm2(capture_mic2), .pcm3(capture_mic3),
        .sample_valid_out(mean_sample_valid), .sample_pending(mean_sample_pending),
        .sample_out(mean_sample)
    );

    // 实时通路采用三麦均值; RAW/POST 由同一均值供出, 沿用三路谱协议。
    always @(posedge clk_50m or negedge mic_path_rst_n)begin
        if(!mic_path_rst_n)begin raw_pair_valid<=0;raw_pair_sample<=0;raw_pair_index<=0;end
        else begin
            raw_pair_valid<=mean_sample_valid;
            if(mean_sample_valid)begin raw_pair_sample<=mean_sample;raw_pair_index<=mic_sample_index;end
        end
    end

    // 同时有效地保留PCM参考(path0)、raw mic(path1)、filtered mic(path2)。
    fft_three_path_scheduler_r06 u_fft_scheduler (
        .capture_request(capture_request),.capture_sample(capture_sample),.capture_read_address(capture_read_address),
        .capture_accept(capture_accept),.capture_done(capture_done),.capture_fft_valid(capture_fft_valid),
        .capture_fft_index(capture_fft_index),.capture_fft_re(capture_fft_re),.capture_fft_im(capture_fft_im),
        .clk(clk_50m), .rst_n(scheduler_rst_n),
        .block_start(pcm_block_start_d1), .history_reset(pcm_history_reset_d1),
        .block_epoch(pcm_block_epoch_d1), .block_first(pcm_block_first_d1),
        .word_valid(pcm_word_valid_d1 && pcm_boundary_ready), .word_data(pcm_word_data_d1),
        .mic_pair_valid(raw_pair_valid), .mic_sample_index(raw_pair_index),
        .mic_raw_sample(raw_pair_sample), .mic_filtered_sample(raw_pair_sample),
        .group_available(group_available),
        .group_start(fft_group_start), .group_active(fft_group_active),
        .group_epoch(fft_group_epoch), .group_end_sample(fft_group_end_sample),
        .path_source_end_valid(fft_path_source_end_valid), .path_source_end_index(fft_path_source_end_index),
        .path_index(fft_path_index), .ch_valid(fft_bin_valid),
        .ch_index(fft_bin_index), .ch_data(fft_bin_data),
        .fft_debug_valid(fft_debug_valid), .fft_debug_index(fft_debug_index),
        .fft_debug_re(fft_debug_re), .fft_debug_im(fft_debug_im),
        .group_done(fft_group_done), .fault(fft_fault_live), .fault_reason(fft_fault_reason_live),
        .fft_busy(fft_busy)
    );

    // TX只获准在空闲bank时启动，整个组捕获期间保留其bank。
    assign group_available = (warm_pair_count >= 13'd4096) &&
        !fft_fault_live && !tx_fault && tx_capture_available;
    assign tx_capture_abort = tx_capturing && !fft_group_active && !fft_group_done;

    multi_spectrum_group_tx_r03_bram u_spectrum_tx (
        .clk(clk_50m), .rst_n(control_rst_n),
        .group_start(fft_group_start), .group_path_count(2'd3),
        .group_epoch(fft_group_epoch), .group_end_sample(fft_group_end_sample),
        .capture_abort(tx_capture_abort),
        .spectrum_valid(fft_bin_valid), .spectrum_path(fft_path_index),
        .spectrum_index(fft_bin_index), .spectrum_data(fft_bin_data),
        .spectrum_done(fft_bin_valid && (fft_bin_index == 7'd127)),
        .capturing(tx_capturing), .capture_available(tx_capture_available), .group_ready(tx_group_ready),
        .link_data(spectrum_link_data), .link_sync(spectrum_link_sync),
        .link_clk(spectrum_link_clk), .fault(tx_fault),
        .sent_packets(tx_sent_packets), .sent_groups(tx_sent_groups),
        .capture_aborts(tx_capture_aborts)
    );

    always @(posedge clk_50m or negedge capture_rst_n) begin
        if (!capture_rst_n) begin
            mic_reset_pulse <= 1'b0;
            scheduler_reset_pulse <= 1'b0;
            mic_sample_index <= 32'd0;
            warm_pair_count <= 13'd0;
            fft_fault_sticky <= 1'b0;
            fft_fault_reason_sticky <= 4'd0;
            pcm_boundary_ready <= 1'b0;
        end else begin
            mic_reset_pulse <= 1'b0;
            scheduler_reset_pulse <= 1'b0;


            if (fft_fault_live && !fft_fault_sticky) begin
                fft_fault_sticky <= 1'b1;
                fft_fault_reason_sticky <= fft_fault_reason_live;
            end

            if (pcm_history_reset)
                pcm_boundary_ready <= 1'b0;
            else if (pcm_block_start_d1)
                pcm_boundary_ready <= 1'b1;

            if (pcm_history_reset) begin
                mic_reset_pulse <= 1'b1;
                scheduler_reset_pulse <= 1'b1;
                mic_sample_index <= 32'd0;
                warm_pair_count <= 13'd0;
            end else begin
                if (mean_sample_valid)
                    mic_sample_index <= mic_sample_index + 32'd1;
                if (raw_pair_valid && warm_pair_count < 13'd4096)
                    warm_pair_count <= warm_pair_count + 13'd1;
            end

        end
    end

    // 两条内部rail由同一个原KEY1异步assert、两级50MHz同步release。
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            capture_rst_meta <= 1'b0;
            capture_rst_n <= 1'b0;
            control_rst_meta <= 1'b0;
            control_rst_n <= 1'b0;
        end else begin
            capture_rst_meta <= 1'b1;
            capture_rst_n <= capture_rst_meta;
            control_rst_meta <= 1'b1;
            control_rst_n <= control_rst_meta;
        end
    end

    // 播放直接取接收器完整16bit提交字流，不从裁低4位的FFT历史恢复音频。
    assign playback_block_start=pcm_block_start;
    assign playback_history_reset=pcm_history_reset;
    assign playback_word_valid=pcm_word_valid;
    assign playback_word_data=pcm_word_data;
    assign pcm_rx_locked = pcm_locked_unused;
    assign pcm_transport_errors = pcm_transport_errors_unused;
    assign pcm_transport_lost = pcm_transport_lost_unused;
    assign pcm_rx_fault = pcm_fault_unused;
    assign pcm_accepted_blocks = accepted_blocks_unused;
    assign pcm_rejected_blocks = rejected_blocks_unused;

endmodule
