`timescale 1ns/1ps
// 8192样本历史与FFT工作RAM分离；冻结N=4096、hop=800。
module v8_fft_window (
    input wire clk,rst,stream_reset,sample_valid,input wire [15:0] sample_data,
    input wire [31:0] stream_epoch,input wire [63:0] stream_first,
    output wire ch_valid,output wire [6:0] ch_index,output wire [7:0] ch_data,
    output wire frame_done,output reg [31:0] frame_epoch,output reg [63:0] frame_first,
    output reg [15:0] windows,missed,output wire busy
);
    (* ram_style="bram_32k" *) reg [15:0] ring[0:8191];
    reg [12:0] wr_ptr,rd_ptr,filled;
    reg [9:0] hop_count;
    reg [63:0] position;
    reg [31:0] active_epoch;
    reg [15:0] ring_q;
    reg [2:0] load_state;
    reg [11:0] sent;
    reg fft_start;
    wire fft_busy;
    wire core_rst=rst || stream_reset;
    wire due=sample_valid && ((filled==4095) || (filled==4096 && hop_count==799));
    assign busy=fft_busy || load_state!=0;
    always @(posedge clk) begin
        if(sample_valid && !core_rst) ring[wr_ptr]<=sample_data;
        ring_q<=ring[rd_ptr];
    end
    pcf_fft_frontend u_fft(.clk(clk),.rst_n(!core_rst),.frame_start(fft_start),
        .s_valid(load_state==3),.s_data(ring_q),.busy(fft_busy),
        .ch_valid(ch_valid),.ch_index(ch_index),.ch_data(ch_data),.frame_done(frame_done),
        .debug_valid(),.debug_index(),.debug_re(),.debug_im());
    always @(posedge clk) begin
        if(rst) begin
            wr_ptr<=0;rd_ptr<=0;filled<=0;hop_count<=0;position<=0;active_epoch<=0;
            load_state<=0;sent<=0;fft_start<=0;frame_epoch<=0;frame_first<=0;windows<=0;missed<=0;
        end else if(stream_reset) begin
            wr_ptr<=0;rd_ptr<=0;filled<=0;hop_count<=0;position<=stream_first;active_epoch<=stream_epoch;
            load_state<=0;sent<=0;fft_start<=0;
        end else begin
            fft_start<=0;
            if(frame_done) windows<=windows+1'b1;
            if(sample_valid) begin
                wr_ptr<=wr_ptr+1'b1;position<=position+1'b1;
                if(filled<4096) filled<=filled+1'b1;
                if(due) hop_count<=0;
                else if(filled==4096) hop_count<=hop_count+1'b1;
            end
            if(due) begin
                if(!busy) begin
                    rd_ptr<=wr_ptr+13'd1-13'd4096;frame_first<=position-64'd4095;
                    frame_epoch<=active_epoch;fft_start<=1;load_state<=1;sent<=0;
                end else missed<=missed+1'b1;
            end
            case(load_state)
                1: load_state<=2;
                2: begin load_state<=3;rd_ptr<=rd_ptr+1'b1;end
                3: begin
                    rd_ptr<=rd_ptr+1'b1;
                    if(sent==4095) load_state<=0;else sent<=sent+1'b1;
                end
                default: ;
            endcase
        end
    end
endmodule
