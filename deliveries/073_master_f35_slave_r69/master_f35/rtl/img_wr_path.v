`timescale 1ns / 1ps
// ============================================================================
// img_wr_path — 按行号寻址的图片行写入 + 图墙缩略图(ctrl 域)
//
// 输入为 bmp_page_loader 的行字流: 每行 320 字 {P1,P0}, 行号 row_y 随行给出,
// 行到达顺序任意(正高度 BMP 为倒序)。每行拆成两个 160 字写事务, 写到
// page_base + row_y*320 + 半行偏移。2×160 字乒乓暂存, 与 video_wr_path 相同的
// FREE->FULL->BUSY->FREE 半区状态; 引擎按序取数(wr_pop 后一拍给数据)。
// 缩略图(thumb_en): 偶数行的每个源字取低像素 P0(水平/垂直各 ÷2), 两两拼成
//   缩略字存入独立暂存; 该半行主事务之后紧跟一个 80 字事务, 写到图墙页
//   thumb_base + (thumb_y0 + row_y/2)*320 + thumb_x0 + 半行*80。
//   引擎按序执行, 主事务与缩略事务对同一半区连续取数。
// idle: 两半均空闲(用于判定一张图已全部落入 SDRAM)。
// ============================================================================
module img_wr_path (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [20:0] page_base,
    input  wire        thumb_en,
    input  wire [20:0] thumb_base,           // 图墙页基址 + 格左上角字偏移

    input  wire        in_valid,
    input  wire [31:0] in_data,
    input  wire [8:0]  in_y,
    output wire        in_ready,

    output wire        w_valid,
    output wire [20:0] w_addr,
    output wire [8:0]  w_len,
    input  wire        w_grant,
    input  wire        wr_pop,
    input  wire        wr_pop_last,
    output wire [31:0] wr_data,
    output wire        idle
);
    localparam [1:0] H_FREE = 2'd0, H_FULL = 2'd1, H_FULLT = 2'd2, H_BUSY = 2'd3;

    reg [31:0] stage [0:511];         // 两半, 每半 256 项用前 160 项
    reg [31:0] tstage [0:255];        // 缩略: 两半, 每半 128 项用前 80 项
    reg [1:0]  hs [0:1];
    reg [20:0] ha [0:1];              // 每半主事务目标字地址
    reg [20:0] ta [0:1];              // 每半缩略事务目标字地址
    reg        ht [0:1];              // 该半带缩略事务
    reg        fill_h, send_h, ret_h, ret_main;
    reg [7:0]  wptr;                  // 0..159
    reg        half2;                 // 正在填本行的第二半
    reg [8:0]  rptr;
    reg        rd_thumb, rd_thumb_d;
    reg [31:0] sq, tq;
    // 两块暂存各自独立同步读(保证都推断为块 RAM), 取数后一拍按来源选择
    assign wr_data = rd_thumb_d ? tq : sq;
    reg [15:0] tlo;

    assign in_ready = (hs[fill_h] == H_FREE);
    wire   in_fire  = in_valid && in_ready;
    assign w_valid  = (hs[send_h] == H_FULL) || (hs[send_h] == H_FULLT);
    assign w_addr   = (hs[send_h] == H_FULLT) ? ta[send_h] : ha[send_h];
    assign w_len    = (hs[send_h] == H_FULLT) ? 9'd80 : 9'd160;
    assign idle     = (hs[0] == H_FREE) && (hs[1] == H_FREE);

    // 行号 × 320 = (y<<8) + (y<<6); 缩略行 y/2 × 320 = (y>>1)<<8 + (y>>1)<<6
    wire [20:0] row_addr = page_base + {4'd0, in_y, 8'd0} + {6'd0, in_y, 6'd0};
    wire [7:0]  ty       = in_y[8:1];
    wire [20:0] trow     = thumb_base + {5'd0, ty, 8'd0} + {7'd0, ty, 6'd0};
    wire        t_row    = thumb_en && !in_y[0];

    always @(posedge clk) begin
        if (in_fire) stage[{fill_h, wptr}] <= in_data;
        if (in_fire && wptr[0]) tstage[{fill_h, wptr[7:1]}] <= {in_data[15:0], tlo};
        if (in_fire && !wptr[0]) tlo <= in_data[15:0];
        if (wr_pop) begin sq <= stage[rptr]; tq <= tstage[{rptr[8], rptr[6:0]}]; rd_thumb_d <= rd_thumb; end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hs[0] <= H_FREE; hs[1] <= H_FREE; ha[0] <= 21'd0; ha[1] <= 21'd0; ta[0] <= 21'd0; ta[1] <= 21'd0;
            ht[0] <= 1'b0; ht[1] <= 1'b0;
            fill_h <= 1'b0; send_h <= 1'b0; ret_h <= 1'b0; ret_main <= 1'b0;
            wptr <= 8'd0; half2 <= 1'b0; rptr <= 9'd0; rd_thumb <= 1'b0;
        end else begin
            if (in_fire) begin
                if (wptr == 8'd0) begin
                    ha[fill_h] <= row_addr + (half2 ? 21'd160 : 21'd0);
                    ta[fill_h] <= trow + (half2 ? 21'd80 : 21'd0);
                    ht[fill_h] <= t_row;
                end
                if (wptr == 8'd159) begin
                    wptr <= 8'd0; hs[fill_h] <= H_FULL; fill_h <= ~fill_h; half2 <= ~half2;
                end else wptr <= wptr + 8'd1;
            end
            // 主事务授权后若带缩略则同半区再发一个缩略事务, 之后才轮到另一半
            if (w_grant) begin
                if (hs[send_h] == H_FULL && ht[send_h]) hs[send_h] <= H_FULLT;
                else begin hs[send_h] <= H_BUSY; send_h <= ~send_h; end
            end
            // 读指针只随 wr_pop 推进: 主 160 字后, 带缩略则续读本半缩略 80 字, 再跳另一半
            if (wr_pop) begin
                if (!rd_thumb && rptr[7:0] == 8'd159) begin
                    if (ht[rptr[8]]) begin rd_thumb <= 1'b1; rptr <= {rptr[8], 8'd0}; end
                    else rptr <= {~rptr[8], 8'd0};
                end else if (rd_thumb && rptr[6:0] == 7'd79) begin
                    rd_thumb <= 1'b0; rptr <= {~rptr[8], 8'd0};
                end else rptr <= rptr + 9'd1;
            end
            if (wr_pop_last) begin
                if (ht[ret_h] && !ret_main) ret_main <= 1'b1;
                else begin hs[ret_h] <= H_FREE; ret_h <= ~ret_h; ret_main <= 1'b0; end
            end
        end
    end
endmodule
