`timescale 1ns/1ps
// 整包CRC确认后再提交PCM；CRC不通过的数据永远不进入环形窗。
module v8_pcm_commit (
    input wire clk,rst,ms_tick,rx_valid,
    input wire [7:0] rx_data,input wire [15:0] rx_length,
    output reg sample_valid,output reg [15:0] sample_data,
    output reg stream_reset,output reg [31:0] stream_epoch,
    output reg [63:0] stream_first,
    output reg [15:0] accepted,bad_packets,gaps,drops
);
    reg capture,rx_bank,commit_bank,committing,read_phase;
    reg [8:0] count;
    reg [15:0] length_hold;
    reg header_bad;
    reg [31:0] packet_epoch,packet_seq,packet_crc;
    reg [63:0] packet_first;
    reg [7:0] low_byte;
    reg [6:0] commit_index;
    reg [15:0] stage_q;
    reg [15:0] stage[0:255];
    wire [31:0] crc;
    reg have_peer,have_retired,peer_known;
    reg [31:0] peer_epoch,retired_epoch,expected_seq;
    reg [63:0] expected_first;
    reg [9:0] silent_ms;
    wire old_session=have_retired && packet_epoch==retired_epoch;
    // 连续窗失效不抹掉序号历史，避免CRC错误/超时后旧包重新成为有效起点。
    wire same_session=peer_known && packet_epoch==peer_epoch;
    wire old_sequence=same_session && $signed(packet_seq-expected_seq)<0;
    wire old_epoch=peer_known && packet_epoch[31:16]==peer_epoch[31:16]
                  && packet_epoch[15:0]<peer_epoch[15:0];
    wire discontinuity=!have_peer || packet_epoch!=peer_epoch
                     || packet_seq!=expected_seq || packet_first!=expected_first;
    ethm_crc32_ref u_crc(.clk(clk),.rst(rst),.load_init(!rx_valid && !capture),
        .byte_valid(rx_valid && (!capture || count<288)),.byte_in(rx_data),.crc(crc));
    // 两个128样本staging银行；读端同步，提交时每两拍输出一笔。
    always @(posedge clk) begin
        if(rx_valid && capture && count>=32 && count<288 && count[0])
            stage[{rx_bank,count[7:1]-7'd16}] <= {rx_data,low_byte};
        stage_q<=stage[{commit_bank,commit_index}];
    end
    always @(posedge clk) begin
        if(rst) begin
            capture<=0;rx_bank<=0;commit_bank<=0;committing<=0;read_phase<=0;
            count<=0;length_hold<=0;header_bad<=0;packet_epoch<=0;packet_seq<=0;
            packet_crc<=0;packet_first<=0;low_byte<=0;commit_index<=0;
            sample_valid<=0;sample_data<=0;stream_reset<=0;stream_epoch<=0;stream_first<=0;
            have_peer<=0;have_retired<=0;peer_known<=0;peer_epoch<=0;retired_epoch<=0;
            expected_seq<=0;expected_first<=0;silent_ms<=0;
            accepted<=0;bad_packets<=0;gaps<=0;drops<=0;
        end else begin
            sample_valid<=0;stream_reset<=0;
            if(ms_tick && have_peer) begin
                if(silent_ms==499) begin
                    have_peer<=0;stream_reset<=1;silent_ms<=0;
                end else silent_ms<=silent_ms+1'b1;
            end
            if(committing) begin
                read_phase<=!read_phase;
                if(read_phase) begin
                    sample_valid<=1;sample_data<=stage_q;
                    if(commit_index==127) begin committing<=0;read_phase<=0;end
                    else commit_index<=commit_index+1'b1;
                end
            end
            if(rx_valid) begin
                if(!capture) begin
                    capture<=1;count<=1;length_hold<=rx_length;
                    header_bad<=(rx_data!=8'h43);packet_crc<=0;
                end else begin
                    if(count<293) count<=count+1'b1;
                    case(count)
                        1: if(rx_data!=8'h50) header_bad<=1;
                        2: if(rx_data!=8'h36) header_bad<=1;
                        3: if(rx_data!=8'h4d) header_bad<=1;
                        4,5,7: if(rx_data!=1) header_bad<=1;
                        6,25,28,29,30,31: if(rx_data!=0) header_bad<=1;
                        24: if(rx_data!=128) header_bad<=1;
                        default: ;
                    endcase
                    if(count>=8 && count<12) packet_epoch[(count-8)*8 +:8]<=rx_data;
                    if(count>=12 && count<16) packet_seq[(count-12)*8 +:8]<=rx_data;
                    if(count>=16 && count<24) packet_first[(count-16)*8 +:8]<=rx_data;
                    if(count>=288 && count<292) packet_crc[(count-288)*8 +:8]<=rx_data;
                    if(!count[0]) low_byte<=rx_data;
                end
            end else if(capture) begin
                capture<=0;
                if(count!=292 || length_hold!=292 || header_bad || packet_crc!=~crc) begin
                    bad_packets<=bad_packets+1'b1;have_peer<=0;stream_reset<=1;
                    committing<=0;sample_valid<=0;read_phase<=0;
                end else if(old_session || old_epoch || old_sequence) begin
                    drops<=drops+1'b1;
                end else if(committing) begin
                    drops<=drops+1'b1;have_peer<=0;stream_reset<=1;
                    committing<=0;sample_valid<=0;read_phase<=0;
                end else begin
                    if(discontinuity) begin
                        stream_reset<=1;stream_epoch<=packet_epoch;stream_first<=packet_first;
                        if(have_peer) gaps<=gaps+1'b1;
                    end
                    if(peer_known && packet_epoch!=peer_epoch) begin
                        retired_epoch<=peer_epoch;have_retired<=1;
                    end
                    peer_epoch<=packet_epoch;peer_known<=1;have_peer<=1;expected_seq<=packet_seq+1'b1;
                    expected_first<=packet_first+64'd128;silent_ms<=0;
                    commit_bank<=rx_bank;rx_bank<=!rx_bank;commit_index<=0;
                    committing<=1;read_phase<=0;accepted<=accepted+1'b1;
                end
            end
        end
    end
endmodule
