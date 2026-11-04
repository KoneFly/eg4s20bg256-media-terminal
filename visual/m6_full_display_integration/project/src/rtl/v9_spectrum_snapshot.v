`timescale 1ns/1ps
// 三银行：接收暂存/最新完整包/显示快照始终互斥；CRC错误不污染显示。
module v9_spectrum_snapshot (
    input wire clk,rst,ms_tick,rx_valid,input wire [7:0] rx_data,
    input wire [15:0] rx_length,input wire [31:0] expected_epoch,
    input wire pixel_clk,pixel_rst,frame_request,input wire [6:0] energy_addr,
    output wire [7:0] energy_data,output reg snapshot_done,
    output reg [15:0] good,bad,old_packets,gaps,replaced,
    output reg online
);
    reg capture,header_bad,pending_valid,have_first;
    reg [8:0] count;
    reg [15:0] length_hold;
    reg [31:0] packet_epoch,packet_seq,packet_crc,epoch_seen,last_seq;
    reg [63:0] packet_first,last_first;
    reg [1:0] stage_bank,pending_bank,front_bank;
    reg [9:0] silent_ms;
    wire [31:0] crc;
    reg [7:0] mem[0:511];
    reg [7:0] pixel_q;
    reg request_toggle;
    (* ASYNC_REG="TRUE" *) reg request_meta,request_sync;
    reg ack_toggle,ack_pending;
    reg [2:0] held_descriptor;
    (* ASYNC_REG="TRUE" *) reg ack_meta,ack_sync;
    (* ASYNC_REG="TRUE" *) reg [2:0] descriptor_meta,descriptor_sync;
    reg ack_seen,pixel_wait,capture_delay;
    reg [2:0] pixel_descriptor;
    wire take=(request_sync!=ack_toggle) && !ack_pending;
    wire packet_end=capture && !rx_valid;
    wire structurally_good=count==292 && length_hold==292 && !header_bad && packet_crc==~crc;
    wire fresh=packet_epoch==expected_epoch && (!have_first || packet_first>last_first);
    wire publish=packet_end && structurally_good && fresh && epoch_seen==expected_epoch;
    assign energy_data=pixel_descriptor[2] ? 8'd0 : pixel_q;
    ethm_crc32_ref u_crc(.clk(clk),.rst(rst),.load_init(!rx_valid && !capture),
        .byte_valid(rx_valid && (!capture || count<288)),.byte_in(rx_data),.crc(crc));
    always @(posedge clk) begin
        if(rx_valid && capture && count>=32 && count<288 && !count[0])
            mem[{stage_bank,count[7:1]-7'd16}]<=rx_data;
    end
    always @(posedge pixel_clk) pixel_q<=mem[{pixel_descriptor[1:0],energy_addr}];
    // 两级同步后再等一拍采样描述符；发送方在ACK前至少一拍固定描述符。
    always @(posedge pixel_clk or posedge pixel_rst) begin
        if(pixel_rst) begin
            request_toggle<=0;ack_meta<=0;ack_sync<=0;ack_seen<=0;
            descriptor_meta<=3'b110;descriptor_sync<=3'b110;pixel_descriptor<=3'b110;
            pixel_wait<=0;capture_delay<=0;snapshot_done<=0;
        end else begin
            ack_meta<=ack_toggle;ack_sync<=ack_meta;
            descriptor_meta<=held_descriptor;descriptor_sync<=descriptor_meta;
            snapshot_done<=0;
            if(frame_request && !pixel_wait) begin request_toggle<=!request_toggle;pixel_wait<=1;end
            if(pixel_wait && ack_sync!=ack_seen) begin ack_seen<=ack_sync;capture_delay<=1;end
            if(capture_delay) begin
                pixel_descriptor<=descriptor_sync;capture_delay<=0;pixel_wait<=0;snapshot_done<=1;
            end
        end
    end
    always @(posedge clk) begin
        if(rst) begin
            capture<=0;header_bad<=0;pending_valid<=0;have_first<=0;count<=0;length_hold<=0;
            packet_epoch<=0;packet_seq<=0;packet_crc<=0;packet_first<=0;
            epoch_seen<=0;last_seq<=0;last_first<=0;stage_bank<=0;pending_bank<=1;front_bank<=2;
            request_meta<=0;request_sync<=0;ack_toggle<=0;ack_pending<=0;held_descriptor<=3'b110;
            good<=0;bad<=0;old_packets<=0;gaps<=0;replaced<=0;online<=0;silent_ms<=0;
        end else begin
            request_meta<=request_toggle;request_sync<=request_meta;
            if(ack_pending) begin ack_toggle<=request_sync;ack_pending<=0;end
            if(ms_tick && online) begin
                if(silent_ms==499) begin online<=0;pending_valid<=0;end
                else silent_ms<=silent_ms+1'b1;
            end
            if(expected_epoch!=epoch_seen) begin
                epoch_seen<=expected_epoch;have_first<=0;pending_valid<=0;online<=0;
            end
            if(take) begin
                ack_pending<=1;
                if(pending_valid && epoch_seen==expected_epoch) begin
                    held_descriptor<={1'b0,pending_bank};front_bank<=pending_bank;
                    pending_bank<=front_bank;pending_valid<=0;
                end else held_descriptor<={(!online || epoch_seen!=expected_epoch),front_bank};
            end
            if(publish) begin
                good<=good+1'b1;online<=1;silent_ms<=0;pending_valid<=1;have_first<=1;
                if(have_first && (packet_first!=last_first+64'd800 || packet_seq!=last_seq+1'b1)) gaps<=gaps+1'b1;
                last_first<=packet_first;last_seq<=packet_seq;
                pending_bank<=stage_bank;
                if(take && pending_valid) stage_bank<=front_bank;
                else begin
                    stage_bank<=pending_bank;
                    if(pending_valid) replaced<=replaced+1'b1;
                end
            end
            if(packet_end && !structurally_good) bad<=bad+1'b1;
            else if(packet_end && structurally_good && !fresh) old_packets<=old_packets+1'b1;
            if(rx_valid) begin
                if(!capture) begin
                    capture<=1;count<=1;length_hold<=rx_length;header_bad<=(rx_data!=8'h43);packet_crc<=0;
                end else begin
                    if(count<293)count<=count+1'b1;
                    case(count)
                        1:if(rx_data!=8'h50)header_bad<=1;
                        2:if(rx_data!=8'h36)header_bad<=1;
                        3:if(rx_data!=8'h4d)header_bad<=1;
                        4,7:if(rx_data!=1)header_bad<=1;
                        5:if(rx_data!=2)header_bad<=1;
                        6,25,26,27,28,29,30,31:if(rx_data!=0)header_bad<=1;
                        24:if(rx_data!=128)header_bad<=1;
                        default:;
                    endcase
                    if(count>=32 && count<288 && count[0] && rx_data!=0)header_bad<=1;
                    if(count>=8 && count<12)packet_epoch[(count-8)*8 +:8]<=rx_data;
                    if(count>=12 && count<16)packet_seq[(count-12)*8 +:8]<=rx_data;
                    if(count>=16 && count<24)packet_first[(count-16)*8 +:8]<=rx_data;
                    if(count>=288 && count<292)packet_crc[(count-288)*8 +:8]<=rx_data;
                end
            end else if(capture)capture<=0;
        end
    end
endmodule
