`timescale 1ns/1ps
// demo_main_link：双向PCM与多谱链路。可选LED观测由参数控制；协议侧CRC/epoch/end校验、发布控制和绘制接口保留。未使用的像素域观测影子可被综合裁剪。
module demo_main_link #(parameter integer OBSERVATION_ENABLE = 1)(
    input wire enabled_ctrl,enabled_pixel,
    input wire ctrl_clk,pixel_clk,ctrl_rst_n,pixel_rst_n,audio_valid,
    input wire [15:0] audio_data,input wire [3:0] source_token,input wire frame_boundary,rx_data,
    input wire [8:0] render_address,
    output wire [7:0] render_data,
    output wire [8:0] render_address_q,
    output wire render_bank_q,render_valid_q,
    input wire [8:0] render_address_b,
    output wire [7:0] render_data_b,
    output wire [8:0] render_address_b_q,
    output wire render_bank_b_q,render_valid_b_q,
    output wire [1:0] display_paths,
    output wire display_bank,
    output wire tx_data,observation,display_status_valid,link_status_error
);
    wire sample_ready,sample_valid,cut,fault;
    wire [15:0] sample_data,overflows,sent,partial,accepted,rejected,dropped,lost;
    wire [7:0] errors,write_data,read_data;
    wire locked,write_valid,publish,bank_free,bank_reset,display_valid;
    wire [8:0] write_address,read_address;
    wire [1:0] publish_paths;
    wire [15:0] metadata_rejections;
    wire [31:0] epoch,end_sample;
    // 元数据RTL接口保持；关闭观察后，未连接的像素域影子可被综合裁剪。协议侧校验与发布控制继续工作。
    (* keep="true" *) wire [31:0] display_epoch,display_end;
    c1_audio_cdc u_cdc(.pixel_clk(pixel_clk),.ctrl_clk(ctrl_clk),.pixel_rst_n(pixel_rst_n),.ctrl_rst_n(ctrl_rst_n),
        .audio_valid(audio_valid&&enabled_pixel),.audio_data(audio_data),.source_token(source_token^{4{!enabled_ctrl}}),.sample_ready(sample_ready),
        .sample_valid(sample_valid),.sample_data(sample_data),.discontinuity(cut),.overflow_count(overflows));
    wm_c1_pcm_tx u_tx(.clk(ctrl_clk),.rst_n(ctrl_rst_n),.flush(!enabled_ctrl),.discontinuity(cut),.sample_valid(sample_valid),.sample_data(sample_data),
        .sample_ready(sample_ready),.serial_data(tx_data),.fault(fault),.sent_blocks(sent),.discarded_partial(partial));
    demo_spectrum_rx u_rx(.clk(ctrl_clk),.rst_n(ctrl_rst_n),.serial_data(enabled_ctrl ? rx_data : 1'b1),.bank_free(bank_free),.bank_reset(bank_reset),
        .write_valid(write_valid),.write_address(write_address),.write_data(write_data),.publish(publish),.publish_epoch(epoch),
        .publish_end(end_sample),.publish_paths(publish_paths),.accepted(accepted),.rejected(rejected),.dropped(dropped),.metadata_rejections(metadata_rejections),.locked(locked),.transport_errors(errors),.transport_lost(lost));
    multi_snapshot_table u_table(.ctrl_clk(ctrl_clk),.pixel_clk(pixel_clk),.ctrl_rst_n(ctrl_rst_n&&enabled_ctrl),.pixel_rst_n(pixel_rst_n&&enabled_pixel),
        .frame_boundary(frame_boundary),.write_valid(write_valid),.write_address(write_address),.write_data(write_data),
        .publish(publish),.publish_paths(publish_paths),.publish_epoch(epoch),.publish_end(end_sample),.bank_free(bank_free),.bank_reset(bank_reset),
        .read_address(read_address),.read_data(read_data),
        .render_address(render_address),.render_data(render_data),.render_address_q(render_address_q),
        .render_bank_q(render_bank_q),.render_valid_q(render_valid_q),
        .render_address_b(render_address_b),.render_data_b(render_data_b),.render_address_b_q(render_address_b_q),
        .render_bank_b_q(render_bank_b_q),.render_valid_b_q(render_valid_b_q),
        .display_paths(display_paths),.display_valid(display_valid),.display_epoch(display_epoch),.display_end(display_end),.display_bank(display_bank));
    assign display_status_valid=display_valid&&enabled_pixel;
    assign link_status_error=fault || errors!=8'd0 || lost!=16'd0 || metadata_rejections!=16'd0;
    generate if (OBSERVATION_ENABLE != 0) begin : g_observation
    wire observer_bit;
    multi_snapshot_observer u_observer(.clk(pixel_clk),.rst_n(pixel_rst_n),.level(read_data),.valid(display_valid),.bank(display_bank),
        .epoch(display_epoch),.end_sample(display_end),.paths(display_paths),.address(read_address),.serial_bit(observer_bit));
    reg [121:0] diagnostics;
    reg [6:0] diagnostic_index;
    reg diagnostic_bit;
    reg [3:0] overflow_index;
    (* preserve="true" *) reg [1:0] diagnostic_sync;
    assign observation=observer_bit^diagnostic_sync[1]^overflows[overflow_index];
    always @(posedge ctrl_clk or negedge ctrl_rst_n) begin
        if(!ctrl_rst_n) begin diagnostics<=0;diagnostic_index<=0;diagnostic_bit<=0;end
        else begin
            diagnostics<={metadata_rejections,sent,partial,accepted,rejected,dropped,lost,errors,locked,fault};
            diagnostic_bit<=diagnostics[diagnostic_index];
            diagnostic_index<=diagnostic_index==7'd121 ? 7'd0 : diagnostic_index+7'd1;
        end
    end
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if(!pixel_rst_n) begin diagnostic_sync<=0;overflow_index<=0;end
        else begin diagnostic_sync<={diagnostic_sync[0],diagnostic_bit};overflow_index<=overflow_index+4'd1;end
    end
    end else begin : g_no_observation
        assign read_address = 9'd0;
        assign observation = 1'b0;
    end endgenerate
endmodule
