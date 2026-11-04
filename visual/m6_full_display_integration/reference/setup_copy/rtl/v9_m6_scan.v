`timescale 1ns/1ps
// 复用S2底部128柱；输入提前两行，双行RAM吸收S2行延迟及末帧flush。
module v9_m6_scan (
    input wire clk,rst,snapshot_done,input wire [7:0] energy_data,
    output reg frame_request,output reg [6:0] energy_addr,
    output wire video_de,video_vs,output wire [15:0] video_rgb,
    output reg [15:0] display_frames
);
    reg [9:0] h,v;
    reg initialized;
    reg [2:0] state;
    reg [5:0] init_index;
    reg [7:0] even_energy;
    reg write_pulse;
    reg [7:0] write_addr;
    reg [31:0] write_data;
    localparam INIT=0,REQUEST=1,ACK=2,PRIME=3,READ=4,WAIT_READ=5,IDLE=6;
    wire input_de=initialized && h>=144 && h<784 && v>=33 && v<513;
    wire output_de=initialized && h>=144 && h<784 && v>=35 && v<515;
    wire [7:0] misc_addr;
    reg [31:0] misc_data;
    wire [15:0] rendered;
    wire rendered_valid;
    wire wr_en=(state==INIT) || write_pulse;
    wire [7:0] wr_addr=(state==INIT) ? {2'b01,init_index} : write_addr;
    wire [31:0] wr_data=(state==INIT) ? 32'd0 : write_data;
    always @(posedge clk) misc_data<=(misc_addr==137) ? 32'h00ffff00 : 32'd0;
    pcb_pixel_renderer u_renderer(.clk(clk),.rst_n(!rst),.in_valid(input_de),
        .in_label(16'd0),.in_image(16'd0),.ov_on(1'b0),.st_trace_addr(),.st_trace_rdata(128'd0),
        .st_misc_addr(misc_addr),.st_misc_rdata(misc_data),.wr_clk(clk),.wr_en(wr_en),
        .wr_sel(1'b1),.wr_addr(wr_addr),.wr_data(wr_data),.wr_lane(2'd0),
        .pixel_rgb565(rendered),.pixel_valid(rendered_valid));
    (* ram_style="bram_32k" *) reg [15:0] lines[0:2047];
    reg [9:0] wx;
    reg [8:0] wy;
    reg [15:0] read_pixel;
    // 提前一拍读RAM，DE/VS与已验HDMI源保持相同相位，不额外推迟有效区。
    wire [9:0] read_x=h-10'd143;
    wire [10:0] read_addr={!v[0],read_x}; // (v-35) mod 2
    wire [10:0] line_write_addr={wy[0],wx};
    always @(posedge clk) begin
        if(rendered_valid)lines[line_write_addr]<=rendered;
        read_pixel<=lines[read_addr];
    end
    assign video_rgb=read_pixel;
    assign video_de=output_de;
    assign video_vs=v>=2;
    always @(posedge clk) begin
        if(rst) begin
            h<=0;v<=0;initialized<=0;state<=INIT;init_index<=0;
            frame_request<=0;energy_addr<=0;even_energy<=0;write_pulse<=0;write_addr<=0;write_data<=0;
            wx<=0;wy<=0;display_frames<=0;
        end else begin
            frame_request<=0;write_pulse<=0;
            if(h==799) begin h<=0;if(v==524)v<=0;else v<=v+1'b1;end
            else h<=h+1'b1;
            if(v==515 && h==0)display_frames<=display_frames+1'b1;
            if(rendered_valid) begin
                if(wx==639) begin wx<=0;if(wy==479)wy<=0;else wy<=wy+1'b1;end
                else wx<=wx+1'b1;
            end
            case(state)
                INIT:if(init_index==63)begin initialized<=1;state<=REQUEST;end else init_index<=init_index+1'b1;
                REQUEST:begin frame_request<=1;state<=ACK;end
                ACK:if(snapshot_done)begin energy_addr<=0;state<=PRIME;end
                PRIME:state<=READ;
                READ:begin
                    if(!energy_addr[0])even_energy<=energy_data;
                    else begin
                        write_pulse<=1;write_addr<={2'b01,energy_addr[6:1]};
                        write_data<={energy_data,energy_data,even_energy,even_energy};
                    end
                    if(energy_addr==127)state<=IDLE;
                    else begin energy_addr<=energy_addr+1'b1;state<=WAIT_READ;end
                end
                WAIT_READ:state<=READ;
                IDLE:if(v==515 && h==0)state<=REQUEST;
                default:state<=INIT;
            endcase
        end
    end
endmodule
