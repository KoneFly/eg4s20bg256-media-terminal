`timescale 1ns / 1ps
// async_word_fifo：异步字FIFO。格雷码指针经两级同步跨域，读口寄存；存储资源类型由实例参数选择。
module async_word_fifo #(
    parameter integer DW    = 33,
    parameter integer DEPTH = 1024,
    parameter         RAM32 = 1      // 1: 引导到 ERAM32K; 0: 交给工具(ERAM9K)
)(
    input  wire          wr_clk,
    input  wire          wr_rst_n,
    input  wire          wr_en,
    input  wire [DW-1:0] wr_data,
    output wire          full,
    output wire [$clog2(DEPTH):0] wr_level,
    input  wire          rd_clk,
    input  wire          rd_rst_n,
    input  wire          rd_en,
    output reg  [DW-1:0] rd_data,
    output wire          empty
);
    localparam integer AW = $clog2(DEPTH);

    function [AW:0] b2g(input [AW:0] b);
        b2g = b ^ (b >> 1);
    endfunction

    function [AW:0] g2b(input [AW:0] g);
        integer j;
        begin
            g2b[AW] = g[AW];
            for (j = AW - 1; j >= 0; j = j - 1) g2b[j] = g2b[j + 1] ^ g[j];
        end
    endfunction

    reg [1:0] wrs, rds;
    always @(posedge wr_clk or negedge wr_rst_n)
        if (!wr_rst_n) wrs <= 2'b00; else wrs <= {wrs[0], 1'b1};
    always @(posedge rd_clk or negedge rd_rst_n)
        if (!rd_rst_n) rds <= 2'b00; else rds <= {rds[0], 1'b1};
    wire wr_rst_i = wrs[1];
    wire rd_rst_i = rds[1];

    reg [AW:0] wr_bin, rd_bin;
    reg [AW:0] wr_gray, rd_gray;
    reg [AW:0] rg1, rg2, wg1, wg2;

    always @(posedge wr_clk or negedge wr_rst_i)
        if (!wr_rst_i) begin rg1 <= 0; rg2 <= 0; end
        else begin rg1 <= rd_gray; rg2 <= rg1; end
    always @(posedge rd_clk or negedge rd_rst_i)
        if (!rd_rst_i) begin wg1 <= 0; wg2 <= 0; end
        else begin wg1 <= wr_gray; wg2 <= wg1; end

    assign wr_level = wr_bin - g2b(rg2);
    assign full     = (wr_level == DEPTH);
    assign empty    = (rd_bin == g2b(wg2));

    wire wr_fire = wr_en && !full;
    wire rd_fire = rd_en && !empty;

    // ERAM32K 全片仅 16 块(已被缩放行缓冲占 8 块), 由实例按需选择落池
    generate if (RAM32) begin : G32
        (* ram_style = "bram_32k" *) reg [DW-1:0] mem [0:DEPTH-1];
        always @(posedge wr_clk) if (wr_fire) mem[wr_bin[AW-1:0]] <= wr_data;
        always @(posedge rd_clk) if (rd_fire) rd_data <= mem[rd_bin[AW-1:0]];
    end else begin : G9
        reg [DW-1:0] mem [0:DEPTH-1];
        always @(posedge wr_clk) if (wr_fire) mem[wr_bin[AW-1:0]] <= wr_data;
        always @(posedge rd_clk) if (rd_fire) rd_data <= mem[rd_bin[AW-1:0]];
    end endgenerate

    always @(posedge wr_clk or negedge wr_rst_i)
        if (!wr_rst_i) begin wr_bin <= 0; wr_gray <= 0; end
        else if (wr_fire) begin
            wr_bin  <= wr_bin + 1'b1;
            wr_gray <= b2g(wr_bin + 1'b1);
        end


    always @(posedge rd_clk or negedge rd_rst_i)
        if (!rd_rst_i) begin rd_bin <= 0; rd_gray <= 0; end
        else if (rd_fire) begin
            rd_bin  <= rd_bin + 1'b1;
            rd_gray <= b2g(rd_bin + 1'b1);
        end
endmodule
