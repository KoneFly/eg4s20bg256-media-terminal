`timescale 1ns / 1ps
// ============================================================================
// video_wr_path — 视频字流 -> 128 字量子 -> SDRAM 帧页(ctrl 域)
//
// 2×128 字乒乓暂存(同步 RAM)。每半状态 FREE -> FULL(填满待发) -> BUSY(已授权,
// 引擎正在按 wr_pop 取数) -> FREE(该事务 wr_pop_last)。引擎按序取数, 因此
// 读指针随 wr_pop 连续递增即可, 无需在授权时重定位。
// 帧: 从页管理拿到页后接收 PAGE_WORDS 字; 最后一个量子被引擎取完即 fill_commit。
//   引擎按序执行, 之后发出的任何读都排在这些写之后, 读到的必为新数据。
// 无页可填时 in_ready=0(背压)。
// clear: 同步清空全部状态; 调用方保证释放时引擎中已无本通路的在途写事务。
// ============================================================================
module video_wr_path #(
    parameter [20:0] PAGE_WORDS = 21'd153600
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clear,

    input  wire        in_valid,
    input  wire [31:0] in_data,
    output wire        in_ready,

    output wire        fill_req,
    input  wire        fill_grant,
    input  wire [20:0] fill_base,
    output reg         fill_commit,

    output wire        w_valid,
    output wire [20:0] w_addr,
    output wire [8:0]  w_len,
    input  wire        w_grant,
    input  wire        wr_pop,
    input  wire        wr_pop_last,
    output reg  [31:0] wr_data
);
    localparam [1:0] H_FREE = 2'd0, H_FULL = 2'd1, H_BUSY = 2'd2;

    reg [31:0] stage [0:255];
    reg [1:0]  hs [0:1];
    reg        have_page;
    reg [20:0] base, in_cnt, wr_off, retired;
    reg        fill_h, send_h, ret_h;
    reg [6:0]  wptr;
    reg [7:0]  rptr;

    assign in_ready = have_page && (in_cnt != PAGE_WORDS) && (hs[fill_h] == H_FREE);
    wire   in_fire  = in_valid && in_ready;
    assign fill_req = !have_page;
    assign w_valid  = (hs[send_h] == H_FULL);
    assign w_addr   = base + wr_off;
    assign w_len    = 9'd128;

    always @(posedge clk) begin
        if (in_fire) stage[{fill_h, wptr}] <= in_data;
        if (wr_pop)  wr_data <= stage[rptr];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hs[0] <= H_FREE; hs[1] <= H_FREE;
            have_page <= 1'b0; base <= 21'd0; in_cnt <= 21'd0; wr_off <= 21'd0; retired <= 21'd0;
            fill_h <= 1'b0; send_h <= 1'b0; ret_h <= 1'b0; wptr <= 7'd0; rptr <= 8'd0;
            fill_commit <= 1'b0;
        end else if (clear) begin
            hs[0] <= H_FREE; hs[1] <= H_FREE;
            have_page <= 1'b0; in_cnt <= 21'd0; wr_off <= 21'd0; retired <= 21'd0;
            fill_h <= 1'b0; send_h <= 1'b0; ret_h <= 1'b0; wptr <= 7'd0; rptr <= 8'd0;
            fill_commit <= 1'b0;
        end else begin
            fill_commit <= 1'b0;
            if (fill_grant) begin
                have_page <= 1'b1; base <= fill_base;
                in_cnt <= 21'd0; wr_off <= 21'd0; retired <= 21'd0;
            end
            if (in_fire) begin
                in_cnt <= in_cnt + 21'd1;
                wptr   <= wptr + 7'd1;
                if (wptr == 7'd127) begin hs[fill_h] <= H_FULL; fill_h <= ~fill_h; end
            end
            if (w_grant) begin
                hs[send_h] <= H_BUSY; send_h <= ~send_h; wr_off <= wr_off + 21'd128;
            end
            if (wr_pop) rptr <= rptr + 8'd1;
            if (wr_pop_last) begin
                hs[ret_h] <= H_FREE; ret_h <= ~ret_h; retired <= retired + 21'd128;
                if (retired + 21'd128 == PAGE_WORDS) begin have_page <= 1'b0; fill_commit <= 1'b1; end
            end
        end
    end
endmodule
