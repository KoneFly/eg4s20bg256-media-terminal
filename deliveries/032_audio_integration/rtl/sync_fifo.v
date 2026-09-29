`timescale 1ns / 1ps
// ============================================================================
// sync_fifo — 通用同步 FIFO (valid/ready 语义 + 状态标志)
// 宽度 WIDTH, 深度 DEPTH (2 的幂)。
// ============================================================================
module sync_fifo #(
    parameter integer WIDTH = 32,
    parameter integer DEPTH = 32
)(
    input  wire              clk,
    input  wire              rst_n,
    // 写
    input  wire              wr_en,
    input  wire [WIDTH-1:0]  din,
    // 读
    input  wire              rd_en,
    output wire [WIDTH-1:0]  dout,
    // 状态
    output wire              full,
    output wire              empty,
    output wire              near_full,       // 剩余 <= 2 空位
    output wire [$clog2(DEPTH+1)-1:0] count    // 已占用条目数
);
    localparam integer AW = $clog2(DEPTH);
    reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [AW:0] wr_ptr, rd_ptr;

    wire full_w  = (wr_ptr[AW] != rd_ptr[AW]) &&
                   (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]);
    wire empty_w = (wr_ptr == rd_ptr);
    wire [AW:0] cnt = wr_ptr - rd_ptr;

    assign full      = full_w;
    assign empty     = empty_w;
    assign count     = cnt;
    assign dout      = mem[rd_ptr[AW-1:0]];
    assign near_full = (cnt >= (DEPTH-2));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= {(AW+1){1'b0}};
            rd_ptr <= {(AW+1){1'b0}};
        end else begin
            if (wr_en && !full_w) begin
                mem[wr_ptr[AW-1:0]] <= din;
                wr_ptr <= wr_ptr + 1'b1;
            end
            if (rd_en && !empty_w)
                rd_ptr <= rd_ptr + 1'b1;
        end
    end

endmodule