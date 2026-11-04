`timescale 1ns/1ps
module v8_fft_dataplane (
    input wire clk,rst,ms_tick,rx_valid,input wire [7:0] rx_data,input wire [15:0] rx_length,
    input wire udp_ready,udp_ack,input wire [2:0] page,
    output wire request,valid,output wire [7:0] data,output wire [15:0] length,
    output wire [31:0] tx_frames,output wire prepared,active,fault,
    output reg [15:0] diagnostic
);
    wire sample_valid,stream_reset,ch_valid,frame_done,busy;
    wire [15:0] sample_data,accepted,bad,gaps,drops,windows,missed,tx_dropped;
    wire [31:0] stream_epoch,frame_epoch;
    wire [63:0] stream_first,frame_first;
    wire [6:0] ch_index;
    wire [7:0] ch_data;
    v8_pcm_commit u_commit(.clk(clk),.rst(rst),.ms_tick(ms_tick),.rx_valid(rx_valid),
        .rx_data(rx_data),.rx_length(rx_length),.sample_valid(sample_valid),.sample_data(sample_data),
        .stream_reset(stream_reset),.stream_epoch(stream_epoch),.stream_first(stream_first),
        .accepted(accepted),.bad_packets(bad),.gaps(gaps),.drops(drops));
    v8_fft_window u_window(.clk(clk),.rst(rst),.stream_reset(stream_reset),
        .sample_valid(sample_valid),.sample_data(sample_data),.stream_epoch(stream_epoch),.stream_first(stream_first),
        .ch_valid(ch_valid),.ch_index(ch_index),.ch_data(ch_data),.frame_done(frame_done),
        .frame_epoch(frame_epoch),.frame_first(frame_first),.windows(windows),.missed(missed),.busy(busy));
    v8_spectrum_tx u_tx(.clk(clk),.rst(rst),.ch_valid(ch_valid),.ch_index(ch_index),.ch_data(ch_data),
        .frame_done(frame_done),.frame_epoch(frame_epoch),.frame_first(frame_first),
        .udp_ready(udp_ready),.udp_ack(udp_ack),.request(request),.valid(valid),.data(data),.length(length),
        .sent_frames(tx_frames),.dropped(tx_dropped),.prepared(prepared),.active(active));
    assign fault=(bad!=0)||(drops!=0)||(missed!=0)||(tx_dropped!=0);
    always @(*) case(page)
        0:diagnostic=accepted;
        1:diagnostic=windows;
        2:diagnostic=tx_frames[15:0];
        3:diagnostic=gaps;
        4:diagnostic=bad;
        5:diagnostic=drops;
        6:diagnostic=missed | tx_dropped; // 仅零/非零判据；不是相加计数。
        default:diagnostic=16'd5301;
    endcase
endmodule
