`timescale 1ns/1ps
// 单颗冻结FFT前端的三路4096点分时调度器。
// 输入历史独立连续性管理；PCM每个32位word按低16位、再高16位解释。
module fft_three_path_scheduler_r06 (
    // 私有MIC1作业只在整组三路之间运行；公共三路元数据和样本保持。
    input wire capture_request,
    input wire signed [15:0] capture_sample,
    output wire [11:0] capture_read_address,
    output reg capture_accept,capture_done,
    output wire capture_fft_valid,
    output wire [11:0] capture_fft_index,
    output wire signed [15:0] capture_fft_re,capture_fft_im,
    input  wire        clk,
    input  wire        rst_n,

    input  wire        block_start,
    input  wire        history_reset,
    input  wire [31:0] block_epoch,
    input  wire [31:0] block_first,
    input  wire        word_valid,
    input  wire [31:0] word_data,

    input  wire        mic_pair_valid,
    input  wire [31:0] mic_sample_index,
    input  wire [15:0] mic_raw_sample,
    input  wire [15:0] mic_filtered_sample,

    input  wire        group_available,
    output reg         group_start,
    output reg         group_active,
    output reg  [31:0] group_epoch,
    output reg  [31:0] group_end_sample,
    output reg         path_source_end_valid,
    output reg  [31:0] path_source_end_index,
    output wire [1:0]  path_index,
    output wire        ch_valid,
    output wire [6:0]  ch_index,
    output wire [7:0]  ch_data,
    output wire        fft_debug_valid,
    output wire [11:0] fft_debug_index,
    output wire signed [15:0] fft_debug_re,
    output wire signed [15:0] fft_debug_im,
    output reg         group_done,
    output reg         fault,
    output reg  [3:0]  fault_reason,
    output wire        fft_busy
);
    localparam [2:0] ST_WAIT       = 3'd0;
    localparam [2:0] ST_START      = 3'd1;
    localparam [2:0] ST_PRIME      = 3'd2;
    localparam [2:0] ST_FEED_USE   = 3'd3;
    localparam [2:0] ST_WAIT_DONE  = 3'd5;

    localparam [13:0] HISTORY_SAMPLES = 14'd8192;
    localparam [13:0] WINDOW_SAMPLES  = 14'd4096;
    localparam [31:0] HOP_SAMPLES     = 32'd800;

    // 三路history都是4096×24的同步单读口字RAM；mic一字按偶/奇sample打包。
    (* ram_style = "bram_32k" *) reg [23:0] pcm_history [0:4095];
    (* ram_style = "bram_32k" *) reg [23:0] raw_history [0:4095];
    (* ram_style = "bram_32k" *) reg [23:0] filtered_history [0:4095];

    reg [13:0] pcm_count;
    reg [13:0] mic_count;
    reg        pcm_history_valid;
    reg        mic_history_valid;
    reg [31:0] pcm_next_index;
    reg [31:0] mic_next_index;
    reg [31:0] pcm_due_end;
    reg [31:0] mic_due_end;
    reg [31:0] pcm_epoch;

    reg [2:0] state;
    reg [1:0] path_select;
    reg [11:0] feed_index;
    reg [11:0] expected_channel;
    reg [7:0] core_reset_hold;
    reg       frame_start;
    reg [31:0] frozen_pcm_start;
    reg [31:0] frozen_mic_start;
    // ST_START到帧时装载；ST_FEED_USE消费样本时同步滚动。
    reg [31:0] mic_current_sample_index;
    reg [31:0] frozen_pcm_end;
    reg [31:0] frozen_mic_end;
    reg [11:0] frozen_pcm_word_start;
    reg [12:0] debug_count;

    reg [11:0] pcm_read_address;
    reg [11:0] mic_read_address;
    reg [23:0] pcm_q;
    reg [23:0] raw_q;
    reg [23:0] filtered_q;
    reg        mic_pending_even_valid;
    reg [11:0] mic_pending_even_address;
    reg [31:0] mic_pending_even_index;
    reg [11:0] mic_pending_raw_even;
    reg [11:0] mic_pending_filtered_even;

    wire [31:0] pcm_latest = pcm_next_index - 32'd1;
    wire [31:0] mic_latest = mic_next_index - 32'd1;
    wire [31:0] pcm_due_lag = pcm_latest - pcm_due_end;
    wire [31:0] mic_due_lag = mic_latest - mic_due_end;
    wire pcm_due_reached = !pcm_due_lag[31];
    wire mic_due_reached = !mic_due_lag[31];
    wire pcm_window_ready = pcm_history_valid && (pcm_count >= WINDOW_SAMPLES) && pcm_due_reached;
    wire mic_window_ready = mic_history_valid && (mic_count >= WINDOW_SAMPLES) && mic_due_reached;
    wire pcm_window_stale = pcm_window_ready && (pcm_due_lag > 32'd4096);
    wire mic_window_stale = mic_window_ready && (mic_due_lag > 32'd4096);

    wire pcm_block_discontinuity = block_start && pcm_history_valid && !history_reset &&
                                   (block_first != pcm_next_index);
    wire mic_index_discontinuity = mic_pair_valid && mic_history_valid &&
                                   (mic_sample_index != mic_next_index);
    wire pcm_active_overrun = group_active && word_valid &&
                              ((pcm_next_index + 32'd1 - frozen_pcm_start) >= 32'd8192);
    wire mic_active_overrun = group_active && mic_pair_valid &&
                              ((mic_sample_index - frozen_mic_start) >= 32'd8192);
    wire group_abort_event = group_active &&
        (history_reset || pcm_block_discontinuity || mic_index_discontinuity ||
         pcm_active_overrun || mic_active_overrun);

    wire [11:0] feed_index_next = feed_index + 12'd1;
    wire [12:0] feed_prefetch_offset = {1'b0, feed_index} + 13'd2;
    wire [11:0] feed_prefetch_halfwords = feed_prefetch_offset[12:1];
    wire [11:0] pcm_read_word_prefetch = frozen_pcm_word_start + feed_prefetch_halfwords;
    wire [11:0] mic_read_word_next = frozen_mic_start[12:1] +
        feed_prefetch_halfwords + {11'd0, (frozen_mic_start[0] & feed_prefetch_offset[0])};
    wire [11:0] pcm_read_word_first = frozen_pcm_word_start;
    wire [12:0] mic_start_low = mic_due_end[12:0] - 13'd4095;

    wire mic_pending_even_match = !mic_current_sample_index[0] && mic_pending_even_valid &&
                                  mic_pending_even_address == mic_current_sample_index[12:1] &&
                                  mic_pending_even_index == mic_current_sample_index;
    wire unused_trimmed_input_low_bits = ^{word_data[19:16], word_data[3:0],
                                           mic_raw_sample[3:0], mic_filtered_sample[3:0], mic_start_low[0]};
    wire [11:0] pcm_start_word_index = pcm_due_end[12:1] - 12'd2047;
    wire [11:0] mic_start_pair_index = mic_start_low[12:1];
    wire [11:0] mic_read_word_first = mic_start_pair_index + {11'd0, frozen_mic_start[0]};
    wire signed [15:0] core_sample_data = (path_select == 2'd0) ?
        (feed_index[0] ? $signed({pcm_q[23:12], 4'b0000}) :
                          $signed({pcm_q[11:0], 4'b0000})) :
        (path_select == 2'd1 ?
            $signed({(mic_pending_even_match ? mic_pending_raw_even :
                     (mic_current_sample_index[0] ? raw_q[23:12] : raw_q[11:0])), 4'b0000}) :
            $signed({(mic_pending_even_match ? mic_pending_filtered_even :
                     (mic_current_sample_index[0] ? filtered_q[23:12] : filtered_q[11:0])), 4'b0000}));
    wire core_rst_n = rst_n && (core_reset_hold == 0);
    wire core_ch_valid;
    wire [6:0] core_ch_index;
    wire [7:0] core_ch_data;
    wire core_frame_done;
    wire core_debug_valid;
    wire [11:0] core_debug_index;
    wire signed [15:0] core_debug_re, core_debug_im;
    wire core_s_valid = (state == ST_FEED_USE);
    wire core_busy;
    reg signed [15:0] core_sample_data_q;
    reg core_s_valid_q;
    localparam [2:0] CP_IDLE=0,CP_START=1,CP_PRIME=2,CP_FEED=3,CP_WAIT=4;
    reg [2:0] capture_state;
    reg [11:0] capture_feed_index;
    reg capture_frame_start,capture_valid_q;
    reg signed [15:0] capture_data_q;
    wire capture_active=capture_state!=CP_IDLE;
    assign capture_read_address=capture_state==CP_FEED ? capture_feed_index+12'd1 : 12'd0;
    assign capture_fft_valid=core_debug_valid&&capture_active;
    assign capture_fft_index=core_debug_index;
    assign capture_fft_re=core_debug_re,capture_fft_im=core_debug_im;
    always @(posedge clk)begin
        capture_data_q<=capture_sample;
        capture_valid_q<=rst_n&&(capture_state==CP_FEED);
        if(!rst_n)begin
            capture_state<=CP_IDLE;capture_feed_index<=0;capture_accept<=0;capture_done<=0;capture_frame_start<=0;
        end else begin
            capture_accept<=0;capture_done<=0;capture_frame_start<=0;
            case(capture_state)
                CP_IDLE:if(capture_request&&state==ST_WAIT&&!core_busy&&core_reset_hold==0)begin
                    capture_state<=CP_START;capture_accept<=1;
                end
                CP_START:begin capture_frame_start<=1;capture_feed_index<=0;capture_state<=CP_PRIME;end
                CP_PRIME:capture_state<=CP_FEED;
                CP_FEED:if(capture_feed_index==4095)capture_state<=CP_WAIT;
                        else capture_feed_index<=capture_feed_index+12'd1;
                CP_WAIT:if(core_frame_done)begin capture_done<=1;capture_state<=CP_IDLE;end
                default:capture_state<=CP_IDLE;
            endcase
        end
    end

    assign path_index = path_select;
    assign ch_valid = core_ch_valid && group_active && (state == ST_WAIT_DONE);
    assign ch_index = core_ch_index;
    assign ch_data = core_ch_data;
    assign fft_debug_valid = core_debug_valid && group_active;
    assign fft_debug_index = core_debug_index;
    assign fft_debug_re = core_debug_re;
    assign fft_debug_im = core_debug_im;
    assign fft_busy = (state != ST_WAIT) || (core_reset_hold != 0) || core_busy;

    // 样本与valid同拍寄存，切断history选择到FFT乘法器的组合路径。
    // 仅复位valid，无效样本不参与FFT；帧末样本在ST_WAIT_DONE中继续送入。
    always @(posedge clk) begin
        core_sample_data_q <= core_sample_data;
        if (!core_rst_n)
            core_s_valid_q <= 1'b0;
        else
            core_s_valid_q <= core_s_valid;
    end

    pcf_fft_frontend u_fft (
        .clk(clk), .rst_n(core_rst_n), .frame_start(capture_active ? capture_frame_start : frame_start),
        .s_valid(capture_active ? capture_valid_q : core_s_valid_q), .s_data(capture_active ? capture_data_q : core_sample_data_q), .busy(core_busy),
        .ch_valid(core_ch_valid), .ch_index(core_ch_index), .ch_data(core_ch_data),
        .frame_done(core_frame_done), .debug_valid(core_debug_valid),
        .debug_index(core_debug_index), .debug_re(core_debug_re), .debug_im(core_debug_im)
    );

    // BRAM模板：三个q每拍无条件同步读；读地址寄存器由FSM显式保持/推进。
    // 写口仅在word_valid/奇sample时写，不复位数据阵列。
    always @(posedge clk) begin
        pcm_q <= pcm_history[pcm_read_address];
        raw_q <= raw_history[mic_read_address];
        filtered_q <= filtered_history[mic_read_address];
        if (rst_n) begin
            if (word_valid && pcm_history_valid && !block_start && !history_reset &&
                (pcm_next_index[0] == 1'b0))
                pcm_history[pcm_next_index[12:1]] <= {word_data[31:20], word_data[15:4]};
            if (mic_pair_valid && mic_sample_index[0]) begin
                if (mic_pending_even_valid && mic_pending_even_address == mic_sample_index[12:1]) begin
                    raw_history[mic_sample_index[12:1]] <= {mic_raw_sample[15:4], mic_pending_raw_even};
                    filtered_history[mic_sample_index[12:1]] <=
                        {mic_filtered_sample[15:4], mic_pending_filtered_even};
                end else begin
                    raw_history[mic_sample_index[12:1]] <= {mic_raw_sample[15:4], 12'd0};
                    filtered_history[mic_sample_index[12:1]] <= {mic_filtered_sample[15:4], 12'd0};
                end
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            pcm_count <= 14'd0;
            mic_count <= 14'd0;
            pcm_history_valid <= 1'b0;
            mic_history_valid <= 1'b0;
            pcm_next_index <= 32'd0;
            mic_next_index <= 32'd0;
            pcm_due_end <= 32'd0;
            mic_due_end <= 32'd0;
            pcm_epoch <= 32'd0;
            state <= ST_WAIT;
            path_select <= 2'd0;
            feed_index <= 12'd0;
            expected_channel <= 12'd0;
            debug_count <= 13'd0;
            core_reset_hold <= 8'd16;
            frame_start <= 1'b0;
            frozen_pcm_start <= 32'd0;
            frozen_mic_start <= 32'd0;
            mic_current_sample_index <= 32'd0;
            frozen_pcm_end <= 32'd0;
            frozen_mic_end <= 32'd0;
            frozen_pcm_word_start <= 12'd0;
            pcm_read_address <= 12'd0;
            mic_read_address <= 12'd0;
            mic_pending_even_valid <= 1'b0;
            mic_pending_even_address <= 12'd0;
            mic_pending_even_index <= 32'd0;
            mic_pending_raw_even <= 12'd0;
            mic_pending_filtered_even <= 12'd0;
            group_start <= 1'b0;
            group_active <= 1'b0;
            group_epoch <= 32'd0;
            group_end_sample <= 32'd0;
            group_done <= 1'b0;
            fault <= 1'b0;
            fault_reason <= 4'd0;
        end else begin
            group_start <= 1'b0;
            group_done <= 1'b0;
            frame_start <= 1'b0;
            if (mic_pair_valid) begin
                if (!mic_sample_index[0]) begin
                    mic_pending_even_valid <= 1'b1;
                    mic_pending_even_address <= mic_sample_index[12:1];
                    mic_pending_even_index <= mic_sample_index;
                    mic_pending_raw_even <= mic_raw_sample[15:4];
                    mic_pending_filtered_even <= mic_filtered_sample[15:4];
                end
            end
            if (core_reset_hold != 0)
                core_reset_hold <= core_reset_hold - 8'd1;

            // PCM block边界提供epoch和绝对样本索引；history_reset开始新连续历史。
            if (history_reset) begin
                pcm_count <= 14'd0;
                if (block_start && !block_first[0]) begin
                    pcm_history_valid <= 1'b1;
                    pcm_next_index <= block_first;
                    pcm_due_end <= block_first + 32'd4095;
                    pcm_epoch <= block_epoch;
                end else begin
                    pcm_history_valid <= 1'b0;
                end
                if (group_active) begin
                    mic_history_valid <= 1'b0;
                    mic_count <= 14'd0;
                end
            end else if (block_start) begin
                pcm_epoch <= block_epoch;
                if (!block_first[0] && !pcm_history_valid) begin
                    pcm_history_valid <= 1'b1;
                    pcm_count <= 14'd0;
                    pcm_next_index <= block_first;
                    pcm_due_end <= block_first + 32'd4095;
                end else if (pcm_block_discontinuity) begin
                    pcm_history_valid <= 1'b1;
                    pcm_count <= 14'd0;
                    pcm_next_index <= block_first;
                    pcm_due_end <= block_first + 32'd4095;
                    mic_history_valid <= 1'b0;
                    mic_count <= 14'd0;
                    fault <= 1'b1;
                    if (!fault) fault_reason <= 4'd1;
                end else if (block_first[0]) begin
                    pcm_history_valid <= 1'b0;
                    pcm_count <= 14'd0;
                    fault <= 1'b1;
                    if (!fault) fault_reason <= 4'd2;
                end
            end

            if (word_valid && !block_start && !history_reset) begin
                if (!pcm_history_valid || pcm_next_index[0]) begin
                    fault <= 1'b1;
                    if (!fault) fault_reason <= 4'd2;
                    pcm_history_valid <= 1'b0;
                    pcm_count <= 14'd0;
                end else begin
                    pcm_next_index <= pcm_next_index + 32'd2;
                    if (pcm_count < HISTORY_SAMPLES)
                        pcm_count <= (pcm_count + 14'd2 > HISTORY_SAMPLES) ? HISTORY_SAMPLES :
                                     pcm_count + 14'd2;
                end
            end

            if (mic_pair_valid) begin
                if (!mic_history_valid) begin
                    mic_history_valid <= 1'b1;
                    mic_count <= 14'd1;
                    mic_next_index <= mic_sample_index + 32'd1;
                    mic_due_end <= mic_sample_index + 32'd4095;
                end else if (mic_index_discontinuity) begin
                    mic_history_valid <= 1'b1;
                    mic_count <= 14'd1;
                    mic_next_index <= mic_sample_index + 32'd1;
                    mic_due_end <= mic_sample_index + 32'd4095;
                    fault <= 1'b1;
                    if (!fault) fault_reason <= 4'd3;
                end else begin
                    mic_next_index <= mic_sample_index + 32'd1;
                    if (mic_count < HISTORY_SAMPLES)
                        mic_count <= mic_count + 14'd1;
                end
            end

            // 窗口超出8192环保存范围时拒绝陈旧数据，清空连续性资格等待重新积满。
            if ((state == ST_WAIT) && (pcm_window_stale || mic_window_stale)) begin
                fault <= 1'b1;
                if (!fault) fault_reason <= 4'd4;
                if (pcm_window_stale) begin pcm_history_valid <= 1'b0; pcm_count <= 14'd0; end
                if (mic_window_stale) begin mic_history_valid <= 1'b0; mic_count <= 14'd0; end
            end

            case (state)
                ST_WAIT: begin
                    if (!capture_active && !capture_request && group_available && !core_busy && (core_reset_hold == 0) &&
                        pcm_window_ready && mic_window_ready &&
                        !pcm_window_stale && !mic_window_stale) begin
                        frozen_pcm_end <= pcm_due_end;
                        frozen_mic_end <= mic_due_end;
                        frozen_pcm_start <= pcm_due_end - 32'd4095;
                        frozen_mic_start <= mic_due_end - 32'd4095;
                        frozen_pcm_word_start <= pcm_start_word_index;
                        pcm_read_address <= pcm_start_word_index;
                        mic_read_address <= mic_start_pair_index;
                        group_epoch <= pcm_epoch;
                        // 遵循062传输元数据：end是窗口末点之后的exclusive索引。
                        group_end_sample <= pcm_due_end + 32'd1;
                        path_select <= 2'd0;
                        expected_channel <= 12'd0;
                        debug_count <= 13'd0;
                        group_start <= 1'b1;
                        group_active <= 1'b1;
                        state <= ST_START;
                    end
                end
                ST_START: begin
                    if (!core_busy && (core_reset_hold == 0)) begin
                        frame_start <= 1'b1;
                        feed_index <= 12'd0;
                        mic_current_sample_index <= frozen_mic_start;
                        state <= ST_PRIME;
                    end
                end
                ST_PRIME: begin
                    pcm_read_address <= pcm_read_word_first;
                    mic_read_address <= mic_read_word_first;
                    state <= ST_FEED_USE;
                end
                ST_FEED_USE: begin
                    if (feed_index == 12'd4095) begin
                        state <= ST_WAIT_DONE;
                    end else begin
                        feed_index <= feed_index_next;
                        mic_current_sample_index <= mic_current_sample_index + 32'd1;
                        pcm_read_address <= pcm_read_word_prefetch;
                        mic_read_address <= mic_read_word_next;
                        state <= ST_FEED_USE;
                    end
                end
                ST_WAIT_DONE: begin
                    if (core_debug_valid) begin
                        if (core_debug_index != debug_count[11:0]) begin
                            fault <= 1'b1;
                            if (!fault) fault_reason <= 4'd5;
                        end
                        debug_count <= debug_count + 13'd1;
                    end
                    if (core_ch_valid) begin
                        if (core_ch_index != expected_channel[6:0]) begin
                            fault <= 1'b1;
                            if (!fault) fault_reason <= 4'd5;
                        end
                        expected_channel <= expected_channel + 12'd1;
                    end
                    if (core_frame_done) begin
                        if (!core_ch_valid || core_ch_index != 7'd127 || expected_channel != 12'd127 ||
                            debug_count != 13'd4096) begin
                            fault <= 1'b1;
                            if (!fault) fault_reason <= 4'd5;
                        end
                        if (path_select != 2'd2) begin
                            path_select <= path_select + 2'd1;
                            expected_channel <= 12'd0;
                            debug_count <= 13'd0;
                            mic_read_address <= mic_start_pair_index;
                            state <= ST_START;
                        end else begin
                            group_done <= 1'b1;
                            group_active <= 1'b0;
                            pcm_due_end <= pcm_due_end + HOP_SAMPLES;
                            mic_due_end <= mic_due_end + HOP_SAMPLES;
                            state <= ST_WAIT;
                        end
                    end
                end
                default: begin
                    state <= ST_WAIT;
                    fault <= 1'b1;
                    if (!fault) fault_reason <= 4'd6;
                end
            endcase

            // 任一路断流、失步、覆盖环形历史时丢弃整组，不发布部分路径。
            if (group_abort_event) begin
                group_active <= 1'b0;
                group_start <= 1'b0;
                state <= ST_WAIT;
                path_select <= 2'd0;
                frame_start <= 1'b0;
                core_reset_hold <= 8'd2;
                pcm_history_valid <= 1'b0;
                mic_history_valid <= 1'b0;
                mic_pending_even_valid <= 1'b0;
                pcm_count <= 14'd0;
                mic_count <= 14'd0;
                fault <= 1'b1;
                if (!fault) begin
                    if (history_reset) fault_reason <= 4'd7;
                    else if (pcm_active_overrun || mic_active_overrun) fault_reason <= 4'd8;
                    else if (pcm_block_discontinuity) fault_reason <= 4'd1;
                    else fault_reason <= 4'd3;
                end
            end
        end
    end

    // 当前path的源索引端点；raw与filtered共享同一个mic_sample_index区间。
    always @* begin
        case (path_select)
            2'd0: path_source_end_index = frozen_pcm_end;
            default: path_source_end_index = frozen_mic_end;
        endcase
        path_source_end_valid = (state == ST_START);
    end
endmodule
