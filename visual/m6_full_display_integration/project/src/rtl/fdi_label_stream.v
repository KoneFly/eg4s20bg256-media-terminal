`timescale 1ns/1ps
// 单项行缓存：填好一行后按扫描顺序写FIFO，整行发布完毕才复用。
// SDRAM存储底行优先；每帧用减320字维护行首，地址路径无乘法器。
module fdi_label_stream (
    input wire clk, rst_n, label_ready,
    output wire rd_req_valid,
    output wire [20:0] rd_req_addr,
    input wire rd_req_ready, rd_beat_valid,
    input wire [31:0] rd_beat_data,
    input wire [20:0] rd_beat_addr,
    input wire rd_done,
    input wire pixel_clk, pixel_rst, pixel_take,
    output wire [31:0] pixel_data,
    output reg pixel_valid,
    output wire pixel_ready,
    output wire [7:0] error_code
);
    localparam [3:0] WAIT_LABEL=0, ROM_WAIT=1, SPAN_LOAD=2,
        BURST_REQUEST=3, BURST_WAIT=4, PRIME=5, EVEN_PIXEL=6,
        ODD_PIXEL=7, NEXT_ROW=8, FAILED=9;
    localparam [20:0] TOP_ROW = 21'h656c0; // 0x40000+479*320
    reg [3:0] state;
    reg [8:0] row_y;
    reg [20:0] row_base;
    reg [9:0] span_first, span_last, pixel_x;
    reg [8:0] burst_word, last_word, line_read_word;
    reg [20:0] burst_addr;
    reg [3:0] beat_count;
    reg [17:0] timeout_count;
    reg [7:0] ctrl_error;
    `include "fdi_row_span_rom.vh"
    reg [19:0] span_q;
    always @(posedge clk) span_q <= fdi_row_span(row_y);

    (* ram_style="bram_32k" *) reg [31:0] line_mem [0:511];
    reg [31:0] line_q;
    reg [15:0] held_high;
    wire [8:0] line_write_word = burst_word + {6'd0,beat_count[2:0]};
    wire [20:0] expected_beat_addr = burst_addr + {17'd0,beat_count};
    always @(posedge clk) begin
        if (state==BURST_WAIT && rd_beat_valid && beat_count<8)
            line_mem[line_write_word] <= rd_beat_data;
        line_q <= line_mem[line_read_word];
    end

    wire fifo_full, fifo_almost_full, fifo_empty, fifo_prefilled;
    wire publish_pixel = (state==EVEN_PIXEL || state==ODD_PIXEL)
        && !fifo_almost_full && !fifo_full && ctrl_error==0;
    wire blank_label = row_y>=451 || pixel_x<span_first || pixel_x>span_last;
    wire [15:0] label_half = state==EVEN_PIXEL ? line_q[15:0] : held_high;
    wire [31:0] fifo_word = {blank_label ? 16'd0 : label_half,16'd0};
    fdi_async_pixel_fifo #(.DEPTH(1024),.AFULL_MARGIN(36)) u_fifo (
        .wr_clk(clk),.wr_rst_n(rst_n),.wr_en(publish_pixel),.wr_data(fifo_word),
        .full(fifo_full),.almost_full(fifo_almost_full),.prefilled(fifo_prefilled),
        .rd_clk(pixel_clk),.rd_rst_n(!pixel_rst),.rd_en(pixel_take && pixel_ready),
        .rd_data(pixel_data),.empty(fifo_empty)
    );
    (* ASYNC_REG="TRUE" *) reg start_meta, start_sync;
    (* ASYNC_REG="TRUE" *) reg ctrl_fault_meta, ctrl_fault_sync;
    reg pixel_fault;
    always @(posedge pixel_clk or posedge pixel_rst) begin
        if (pixel_rst) begin
            start_meta<=0; start_sync<=0; ctrl_fault_meta<=0; ctrl_fault_sync<=0;
            pixel_fault<=0; pixel_valid<=0;
        end else begin
            start_meta<=fifo_prefilled; start_sync<=start_meta;
            ctrl_fault_meta<=(ctrl_error!=0); ctrl_fault_sync<=ctrl_fault_meta;
            pixel_valid<=pixel_take && pixel_ready && !fifo_empty;
            if (pixel_take && (!pixel_ready || fifo_empty)) pixel_fault<=1;
        end
    end
    assign pixel_ready = start_sync && !pixel_fault && !ctrl_fault_sync;
    (* ASYNC_REG="TRUE" *) reg pixel_fault_meta, pixel_fault_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin pixel_fault_meta<=0; pixel_fault_sync<=0; end
        else begin pixel_fault_meta<=pixel_fault; pixel_fault_sync<=pixel_fault_meta; end
    end
    assign error_code = ctrl_error!=0 ? ctrl_error : (pixel_fault_sync ? 8'h31 : 8'd0);
    assign rd_req_valid = state==BURST_REQUEST && label_ready && ctrl_error==0;
    assign rd_req_addr = burst_addr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=WAIT_LABEL; row_y<=0; row_base<=TOP_ROW; span_first<=0; span_last<=0;
            pixel_x<=0; burst_word<=0; last_word<=0; line_read_word<=0; held_high<=0;
            burst_addr<=0; beat_count<=0; timeout_count<=0; ctrl_error<=0;
        end else begin
            case (state)
            WAIT_LABEL: if (label_ready) state<=ROM_WAIT;
            ROM_WAIT: state<=SPAN_LOAD;
            SPAN_LOAD: begin
                pixel_x<=0; line_read_word<=0;
                span_first<=span_q[19:10]; span_last<=span_q[9:0];
                if (row_y>=451) begin
                    span_first<=640; span_last<=0; state<=PRIME;
                end else if (span_q[19:10]>=640 || span_q[9:0]>=640
                    || span_q[19:10]>span_q[9:0]) begin
                    ctrl_error<=8'h32; state<=FAILED;
                end else begin
                    burst_word<={span_q[19:14],3'b000};
                    last_word<={span_q[9:4],3'b111};
                    burst_addr<=row_base+{12'd0,span_q[19:14],3'b000};
                    state<=BURST_REQUEST;
                end
            end
            BURST_REQUEST: if (rd_req_valid && rd_req_ready) begin
                beat_count<=0; timeout_count<=0; state<=BURST_WAIT;
            end
            BURST_WAIT: begin
                timeout_count<=timeout_count+1'b1;
                if (rd_beat_valid) begin
                    if (beat_count>=8 || rd_beat_addr!=expected_beat_addr) begin
                        ctrl_error<=8'h33; state<=FAILED;
                    end else beat_count<=beat_count+1'b1;
                end
                if (rd_done) begin
                    if ((beat_count==8 && !rd_beat_valid)
                        || (beat_count==7 && rd_beat_valid && rd_beat_addr==expected_beat_addr)) begin
                        if (burst_word==last_word-9'd7) state<=PRIME;
                        else begin
                            burst_word<=burst_word+9'd8;
                            burst_addr<=burst_addr+21'd8;
                            state<=BURST_REQUEST;
                        end
                    end else begin ctrl_error<=8'h34; state<=FAILED; end
                end else if (&timeout_count) begin ctrl_error<=8'h35; state<=FAILED; end
            end
            PRIME: state<=EVEN_PIXEL;
            EVEN_PIXEL: if (publish_pixel) begin
                held_high<=line_q[31:16]; line_read_word<=line_read_word+9'd1;
                pixel_x<=pixel_x+10'd1; state<=ODD_PIXEL;
            end
            ODD_PIXEL: if (publish_pixel) begin
                pixel_x<=pixel_x+10'd1;
                if (pixel_x==639) state<=NEXT_ROW;
                else state<=EVEN_PIXEL;
            end
            NEXT_ROW: begin
                if (row_y==479) begin row_y<=0; row_base<=TOP_ROW; end
                else begin row_y<=row_y+9'd1; row_base<=row_base-21'd320; end
                state<=ROM_WAIT;
            end
            FAILED: begin end
            default: begin ctrl_error<=8'h36; state<=FAILED; end
            endcase
        end
    end
endmodule
