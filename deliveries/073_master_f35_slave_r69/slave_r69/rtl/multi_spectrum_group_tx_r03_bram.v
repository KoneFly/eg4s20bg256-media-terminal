`timescale 1ns/1ps
// 双bank多谱组发送器：独立捕获端口可与前一完整组的038串行发送重叠。
// 共享单时钟、单写口/单同步读口RAM；宏类型只请求bram，未做综合映射签核。
module multi_spectrum_group_tx_r03_bram(
    input wire clk,
    input wire rst_n,
    input wire group_start,
    input wire [1:0] group_path_count,
    input wire [31:0] group_epoch,
    input wire [31:0] group_end_sample,
    input wire capture_abort,
    input wire spectrum_valid,
    input wire [1:0] spectrum_path,
    input wire [6:0] spectrum_index,
    input wire [7:0] spectrum_data,
    input wire spectrum_done,
    output reg capturing,
    output wire capture_available,
    output wire group_ready,
    output wire link_data,
    output wire link_sync,
    output wire link_clk,
    output wire fault,
    output wire [15:0] sent_packets,
    output reg [15:0] sent_groups,
    output reg [15:0] capture_aborts
);
    `include "multi_spectrum_crc_r03.vh"

    localparam [3:0] ST_IDLE=4'd0,ST_READ_ADDR=4'd1,ST_READ_WAIT=4'd2,
        ST_READ_FILL=4'd3,ST_ISSUE=4'd4,ST_WAIT_LOW=4'd5,
        ST_WAIT_HIGH=4'd6,ST_ADVANCE=4'd7;

    reg [3:0] tx_state;
    reg tx_active,tx_bank,tail_packet;
    reg [5:0] packet_index;
    reg [3:0] byte_index;
    reg [1:0] packet_kind;
    reg [4:0] packet_tag;
    reg [95:0] packet_data;
    reg packet_valid;
    reg local_fault;

    reg capture_bank;
    reg [1:0] capture_path_count,capture_path;
    reg [7:0] bins_seen;
    reg [8:0] capture_bytes;
    reg [15:0] crc_running,crc_n1_checkpoint,crc_n2_checkpoint;
    reg [31:0] capture_epoch,capture_end_sample,capture_sequence;
    reg [31:0] next_sequence;

    reg [1:0] bank_path_count [0:1];
    reg [31:0] bank_epoch [0:1];
    reg [31:0] bank_end_sample [0:1];
    reg [31:0] bank_sequence [0:1];
    reg [15:0] bank_crc [0:1];
    reg [5:0] bank_packet_count [0:1];
    reg [1:0] bank_valid;

    (* ram_style="bram" *) reg [7:0] spectrum_mem [0:1023];
    reg [95:0] tx_payload;
    reg [15:0] tx_crc;
    reg [31:0] tx_epoch,tx_end_sample;
    reg [1:0] tx_path_count;
    reg [5:0] tx_packet_count;

    wire bank0_free=!bank_valid[0];
    wire bank1_free=!bank_valid[1];
    wire selected_capture_bank=bank0_free ? 1'b0 : 1'b1;
    wire packet_ready,packet_fault;
    assign capture_available=!capturing&&(bank0_free||bank1_free)&&!local_fault;
    assign group_ready=|bank_valid;
    assign fault=local_fault|packet_fault;
    link062_packet_tx u_packet(
        .clk(clk),.rst_n(rst_n),.valid(packet_valid),.ready(packet_ready),
        .data(packet_data),.kind(packet_kind),.tag(packet_tag),
        .link_data(link_data),.link_sync(link_sync),.link_clk(link_clk),
        .fault(packet_fault),.sent_packets(sent_packets));

    wire [15:0] crc_next=crc16_byte(crc_running,spectrum_data);
    wire final_bin_now=spectrum_valid&&(spectrum_path==capture_path)&&
                       (spectrum_index==7'd127)&&(bins_seen==8'd127);
    wire complete_frame=(bins_seen==8'd128)||final_bin_now;
    wire capture_write_ok=capturing&&!capture_abort&&spectrum_valid&&
        (spectrum_path==capture_path)&&({1'b0,spectrum_index}==bins_seen)&&
        (spectrum_path<capture_path_count)&&(bins_seen<8'd128)&&capture_bytes<9'd384;
    wire [9:0] capture_base=capture_bank ? 10'd384 : 10'd0;
    wire [9:0] capture_address=capture_base+{1'b0,capture_path,7'd0}+{3'd0,spectrum_index};
    wire [8:0] byte_address=packet_index*9'd12+{5'd0,byte_index};
    wire [8:0] tx_total_bytes=tx_path_count*9'd128;
    wire [9:0] tx_base=tx_bank ? 10'd384 : 10'd0;
    wire [9:0] tx_read_address_next=tx_base+{1'b0,byte_address};
    reg [9:0] tx_read_address;
    reg [7:0] spectrum_read_q;
    wire [7:0] read_data=(byte_address<tx_total_bytes)?spectrum_read_q:8'd0;
    wire [7:0] tx_meta_path_count={6'd0,tx_path_count};
    wire tx_group_done=(tx_state==ST_ADVANCE)&&tail_packet;
    wire [31:0] sequence_delta=bank_sequence[0]-bank_sequence[1];
    wire select_bank0=bank_valid[0]&&(!bank_valid[1]||sequence_delta[31]);

    wire [15:0] finalized_crc = capture_path_count==2'd1 ?
        ((spectrum_valid&&capture_bytes==9'd127)?crc_next:crc_n1_checkpoint) :
        capture_path_count==2'd2 ?
        ((spectrum_valid&&capture_bytes==9'd255)?crc_next:crc_n2_checkpoint) :
        ((spectrum_valid&&capture_bytes==9'd383)?crc_next:crc_running);

    // 独立单写口过程；阵列与读数据寄存器不复位。
    always @(posedge clk) begin
        if(capture_write_ok)
            spectrum_mem[capture_address]<=spectrum_data;
    end

    // RAM模板要求无条件同步读。地址由READ_ADDR状态按包字节按需预取；
    // 既有WAIT/FILL拍保持不变，FILL仍消费前一拍的RAM Q。
    always @(posedge clk) begin
        spectrum_read_q<=spectrum_mem[tx_read_address];
    end

    always @(posedge clk) begin
        if(!rst_n) begin
            tx_state<=ST_IDLE;tx_active<=1'b0;tx_bank<=1'b0;tail_packet<=1'b0;
            packet_index<=6'd0;byte_index<=4'd0;packet_kind<=2'd0;packet_tag<=5'd0;
            packet_data<=96'd0;packet_valid<=1'b0;local_fault<=1'b0;
            capturing<=1'b0;capture_bank<=1'b0;capture_path_count<=2'd0;capture_path<=2'd0;
            bins_seen<=8'd0;capture_bytes<=9'd0;crc_running<=16'hffff;
            crc_n1_checkpoint<=16'hffff;crc_n2_checkpoint<=16'hffff;
            capture_epoch<=32'd0;capture_end_sample<=32'd0;capture_sequence<=32'd0;
            next_sequence<=32'd0;bank_valid<=2'b00;
            bank_path_count[0]<=2'd0;bank_path_count[1]<=2'd0;
            bank_epoch[0]<=32'd0;bank_epoch[1]<=32'd0;
            bank_end_sample[0]<=32'd0;bank_end_sample[1]<=32'd0;
            bank_sequence[0]<=32'd0;bank_sequence[1]<=32'd0;
            bank_crc[0]<=16'hffff;bank_crc[1]<=16'hffff;
            bank_packet_count[0]<=6'd0;bank_packet_count[1]<=6'd0;
            tx_payload<=96'd0;tx_crc<=16'hffff;tx_epoch<=32'd0;tx_end_sample<=32'd0;
            tx_path_count<=2'd0;tx_packet_count<=6'd0;tx_read_address<=10'd0;
            sent_groups<=16'd0;capture_aborts<=16'd0;
        end else begin
            packet_valid<=1'b0;

            if(group_start) begin
                if(!capture_available||group_path_count==0) begin
                    local_fault<=1'b1;
                end else begin
                    capturing<=1'b1;capture_bank<=selected_capture_bank;
                    capture_path_count<=group_path_count;capture_path<=2'd0;bins_seen<=8'd0;
                    capture_bytes<=9'd0;crc_running<=16'hffff;
                    crc_n1_checkpoint<=16'hffff;crc_n2_checkpoint<=16'hffff;
                    capture_epoch<=group_epoch;capture_end_sample<=group_end_sample;
                    capture_sequence<=next_sequence;
                end
            end

            if(capture_abort&&capturing) begin
                // Drop only the incomplete capture bank. Queued/transmitting banks survive.
                capturing<=1'b0;bins_seen<=8'd0;capture_bytes<=9'd0;
                capture_aborts<=capture_aborts+16'd1;
            end else begin
                if(spectrum_valid) begin
                    if(!capture_write_ok) begin
                        local_fault<=1'b1;capturing<=1'b0;bins_seen<=8'd0;
                    end else begin
                        crc_running<=crc_next;
                        if(capture_bytes==9'd127)crc_n1_checkpoint<=crc_next;
                        if(capture_bytes==9'd255)crc_n2_checkpoint<=crc_next;
                        capture_bytes<=capture_bytes+9'd1;
                        bins_seen<=bins_seen+8'd1;
                    end
                end

                if(spectrum_done) begin
                    if(!capturing||!complete_frame||capture_abort) begin
                        local_fault<=1'b1;capturing<=1'b0;bins_seen<=8'd0;
                    end else if(capture_path+2'd1==capture_path_count) begin
                        if(capture_bytes+(spectrum_valid?9'd1:9'd0)!=capture_path_count*9'd128) begin
                            local_fault<=1'b1;capturing<=1'b0;
                        end else begin
                            capturing<=1'b0;
                            bank_path_count[capture_bank]<=capture_path_count;
                            bank_epoch[capture_bank]<=capture_epoch;
                            bank_end_sample[capture_bank]<=capture_end_sample;
                            bank_crc[capture_bank]<=finalized_crc;
                            bank_sequence[capture_bank]<=capture_sequence;
                            bank_packet_count[capture_bank]<=capture_path_count==2'd3 ? 6'd32 : capture_path_count*6'd11;
                            bank_valid[capture_bank]<=1'b1;
                            next_sequence<=next_sequence+32'd1;
                        end
                    end else begin
                        capture_path<=capture_path+2'd1;bins_seen<=8'd0;
                    end
                end
            end

            case(tx_state)
                ST_IDLE: if(!tx_active&&(bank_valid[0]||bank_valid[1])) begin
                    tx_bank<=select_bank0?1'b0:1'b1;tx_active<=1'b1;
                    tx_path_count<=bank_path_count[select_bank0?1'b0:1'b1];
                    tx_crc<=bank_crc[select_bank0?1'b0:1'b1];
                    tx_epoch<=bank_epoch[select_bank0?1'b0:1'b1];
                    tx_end_sample<=bank_end_sample[select_bank0?1'b0:1'b1];
                    tx_packet_count<=bank_packet_count[select_bank0?1'b0:1'b1];
                    packet_index<=6'd0;byte_index<=4'd0;packet_data<=96'd0;
                    packet_kind<=2'd2;packet_tag<=5'd0;tail_packet<=1'b0;
                    tx_state<=ST_READ_ADDR;
                end
                ST_READ_ADDR:begin tx_read_address<=tx_read_address_next;tx_state<=ST_READ_WAIT;end
                ST_READ_WAIT:tx_state<=ST_READ_FILL;
                ST_READ_FILL:begin
                    packet_data[byte_index*8+:8]<=read_data;
                    if(byte_index==4'd11)tx_state<=ST_ISSUE;
                    else begin byte_index<=byte_index+4'd1;tx_state<=ST_READ_ADDR;end
                end
                ST_ISSUE:if(packet_ready)begin packet_valid<=1'b1;tx_state<=ST_WAIT_LOW;end
                ST_WAIT_LOW:if(!packet_ready)tx_state<=ST_WAIT_HIGH;
                ST_WAIT_HIGH:if(packet_ready)tx_state<=ST_ADVANCE;
                ST_ADVANCE:begin
                    if(tail_packet)begin
                        bank_valid[tx_bank]<=1'b0;tx_active<=1'b0;tail_packet<=1'b0;
                        sent_groups<=sent_groups+16'd1;tx_state<=ST_IDLE;
                    end else if(packet_index+6'd1==tx_packet_count)begin
                        packet_kind<=2'd3;packet_tag<=5'd1;
                        packet_data<={tx_meta_path_count,8'd128,tx_crc,tx_end_sample,tx_epoch};
                        tail_packet<=1'b1;tx_state<=ST_ISSUE;
                    end else begin
                        packet_index<=packet_index+6'd1;byte_index<=4'd0;packet_data<=96'd0;
                        packet_kind<=2'd2;packet_tag<=packet_index[4:0]+5'd1;tx_state<=ST_READ_ADDR;
                    end
                end
                default:begin tx_state<=ST_IDLE;local_fault<=1'b1;tx_active<=1'b0;end
            endcase
        end
    end

// synthesis translate_off
`ifdef TX_SIM_ASSERT
    always @(posedge clk) if(rst_n&&capturing&&tx_active&&(capture_bank==tx_bank))
        $fatal(1,"R03 bank ownership collision");
`endif
// synthesis translate_on
endmodule
