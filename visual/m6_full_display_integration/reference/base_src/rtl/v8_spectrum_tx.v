`timescale 1ns/1ps
// 保留292B/CP6M契约，type2载荷为128路零扩展的16bit能量。
module v8_spectrum_tx (
    input wire clk,rst,ch_valid,frame_done,input wire [6:0] ch_index,input wire [7:0] ch_data,
    input wire [31:0] frame_epoch,input wire [63:0] frame_first,
    input wire udp_ready,udp_ack,
    output wire request,valid,output wire [7:0] data,output wire [15:0] length,
    output reg [31:0] sent_frames,output reg [15:0] dropped,
    output wire prepared,active
);
    reg [7:0] energy[0:127];
    reg [7:0] packet[0:511];
    reg packet_ready,building;
    reg [8:0] build_index;
    reg [31:0] epoch_hold,seq_hold,sequence_next;
    reg [63:0] first_hold;
    reg [7:0] byte_value,payload_byte;
    wire [8:0] prefetch;
    wire done;
    wire [31:0] crc;
    assign prepared=packet_ready;
    ethm_crc32_ref u_crc(.clk(clk),.rst(rst),.load_init(!building),
        .byte_valid(building && build_index<288),.byte_in(byte_value),.crc(crc));
    always @(*) begin
        byte_value=0;
        case(build_index)
            0:byte_value=8'h43;1:byte_value=8'h50;2:byte_value=8'h36;3:byte_value=8'h4d;
            4:byte_value=1;5:byte_value=2;7:byte_value=1;24:byte_value=128;
            default:begin
                if(build_index>=8 && build_index<12) byte_value=epoch_hold[(build_index-8)*8 +:8];
                else if(build_index>=12 && build_index<16) byte_value=seq_hold[(build_index-12)*8 +:8];
                else if(build_index>=16 && build_index<24) byte_value=first_hold[(build_index-16)*8 +:8];
                else if(build_index>=32 && build_index<288)
                    byte_value=build_index[0] ? 8'd0 : energy[build_index[7:1]-7'd16];
                else if(build_index>=288) byte_value=~crc[(build_index-288)*8 +:8];
            end
        endcase
    end
    always @(posedge clk) begin
        if(ch_valid) energy[ch_index]<=ch_data;
        if(building) packet[build_index]<=byte_value;
        payload_byte<=packet[prefetch];
    end
    v7_udp_cam_ctrl_pcm u_ctrl(.clk(clk),.rst_n(!rst),.packet_ready(packet_ready),
        .udp_tx_ready(udp_ready),.app_tx_ack(udp_ack),.payload_byte(payload_byte),
        .payload_index(),.payload_prefetch_index(prefetch),.packet_done(done),
        .app_tx_data_request(request),.app_tx_data_valid(valid),.app_tx_data(data),
        .udp_data_length(length),.busy(active));
    always @(posedge clk) begin
        if(rst) begin
            packet_ready<=0;building<=0;build_index<=0;epoch_hold<=0;seq_hold<=0;
            sequence_next<=0;first_hold<=0;sent_frames<=0;dropped<=0;
        end else begin
            if(done) begin packet_ready<=0;sent_frames<=sent_frames+1'b1;end
            if(frame_done) begin
                sequence_next<=sequence_next+1'b1;
                if(!packet_ready && !building) begin
                    building<=1;build_index<=0;epoch_hold<=frame_epoch;
                    seq_hold<=sequence_next;first_hold<=frame_first;
                end else dropped<=dropped+1'b1;
            end
            if(building) begin
                if(build_index==291) begin building<=0;packet_ready<=1;end
                else build_index<=build_index+1'b1;
            end
        end
    end
endmodule
