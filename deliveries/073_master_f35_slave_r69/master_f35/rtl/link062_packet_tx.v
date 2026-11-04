`timescale 1ns/1ps
// 单待发包预演与原038 snapshot握手；预演和当前帧发送重叠。
module link062_packet_tx(
    input wire clk, input wire rst_n,
    input wire valid, output wire ready,
    input wire [95:0] data, input wire [1:0] kind, input wire [4:0] tag,
    output wire link_data, output wire link_sync, output wire link_clk,
    output reg fault, output reg [15:0] sent_packets
);
    `include "link062_crc.vh"
    function automatic [7:0] crc8_byte(input [7:0] crc, input [7:0] byte_value);
        reg [7:0] value;
        integer k;
        begin
            value=crc^byte_value;
            for(k=0;k<8;k=k+1) value=value[7] ? (value<<1)^8'h07 : value<<1;
            crc8_byte=value;
        end
    endfunction
    function automatic [7:0] seed_crc(input [2:0] candidate);
        begin
            case(candidate)
                0:seed_crc=8'h00; 1:seed_crc=8'h2f; 2:seed_crc=8'h5e; 3:seed_crc=8'h71;
                4:seed_crc=8'hbc; 5:seed_crc=8'h93; 6:seed_crc=8'he2; 7:seed_crc=8'hcd;
            endcase
        end
    endfunction
    localparam [2:0] IDLE=0,SCAN=1,REQUEST=2,WAIT_SNAPSHOT=3;
    reg [2:0] state,seed;
    reg [159:0] base_frame;
    reg [95:0] raw_data,tx_energy;
    reg [1:0] tx_kind;
    reg [7:0] tx_param;
    reg energy_valid,cmd_valid,frame_ref,heartbeat,await_low;
    reg [7:0] position;
    reg [6:0] lfsr;
    reg [4:0] run;
    reg last_bit;
    reg [159:0] input_frame,candidate_frame;
    reg [7:0] crc;
    integer i;
    always @* begin
        input_frame=160'd0;
        input_frame[15:0]=16'h5aa5;
        input_frame[31:16]=sent_packets;
        input_frame[39:32]={6'd0,~heartbeat,1'b1};
        input_frame[47:40]={1'b1,kind,3'd0,2'd0};
        input_frame[55:48]={tag,3'd0};
        for(i=0;i<8;i=i+1) input_frame[56+8*i+:8]=data[12*i+:8];
        for(i=0;i<4;i=i+1)
            input_frame[120+8*i+:8]={data[24*i+20+:4],data[24*i+8+:4]};
        crc=8'd0;
        for(i=0;i<17;i=i+1) crc=crc8_byte(crc,input_frame[16+8*i+:8]);
        input_frame[159:152]=crc;
        candidate_frame=base_frame;
        for(i=0;i<13;i=i+1)
            candidate_frame[48+8*i+:8]=base_frame[48+8*i+:8]^{5'd0,seed};
        candidate_frame[159:152]=base_frame[159:152]^seed_crc(seed);
    end
    wire scan_bit=candidate_frame[position]^(position>=8'd16 ? lfsr[6] : 1'b0);
    wire bad_run=(run==5'd23)&&(scan_bit==last_bit);
    assign ready=(state==IDLE)&&!fault;
    interboard_tx u_transport(.clk(clk),.rst_n(rst_n),.energy(tx_energy),
        .energy_valid(energy_valid),.asset_id(tx_kind),.effect_mode(3'd0),
        .param(tx_param),.cmd_valid(cmd_valid),.frame_ref(frame_ref),
        .frame_id(sent_packets),.link_clk(link_clk),.link_sync(link_sync),.link_data(link_data));
    always @(posedge clk) begin
        if(!rst_n) begin
            state<=IDLE;seed<=0;base_frame<=0;raw_data<=0;tx_energy<=0;tx_kind<=0;tx_param<=0;
            energy_valid<=0;cmd_valid<=0;frame_ref<=0;heartbeat<=0;await_low<=0;
            position<=0;lfsr<=7'h7f;run<=0;last_bit<=0;fault<=0;sent_packets<=0;
        end else begin
            energy_valid<=0;cmd_valid<=0;frame_ref<=0;
            case(state)
                IDLE:if(valid&&!fault) begin
                    base_frame<=input_frame;raw_data<=data;tx_kind<=kind;tx_param<={tag,3'd0};
                    seed<=0;position<=0;lfsr<=7'h7f;run<=0;state<=SCAN;
                end
                SCAN:begin
                    if(bad_run) begin
                        if(seed==3'd7) begin fault<=1;state<=IDLE;end
                        else begin seed<=seed+3'd1;position<=0;lfsr<=7'h7f;run<=0;end
                    end else begin
                        run<=(run!=0&&scan_bit==last_bit) ? run+5'd1 : 5'd1;
                        last_bit<=scan_bit;
                        if(position>=8'd16) lfsr<={lfsr[5:0],lfsr[6]^lfsr[5]};
                        if(position==8'd159) begin
                            tx_energy<=seed_transform(raw_data,seed);
                            tx_param[2:0]<=seed;energy_valid<=1;cmd_valid<=1;state<=REQUEST;
                        end else position<=position+8'd1;
                    end
                end
                REQUEST:begin frame_ref<=1;await_low<=link_sync;state<=WAIT_SNAPSHOT;end
                WAIT_SNAPSHOT:begin
                    if(await_low&&!link_sync) await_low<=0;
                    if(!await_low&&link_sync) begin
                        heartbeat<=~heartbeat;sent_packets<=sent_packets+16'd1;state<=IDLE;
                    end
                end
                default:begin fault<=1;state<=IDLE;end
            endcase
        end
    end
endmodule
