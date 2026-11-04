`timescale 1ns / 1ps
// ============================================================================
// fdi_async_pixel_fifo — 1024×32 双时钟异步 FIFO (ctrl_clk 50MHz 写 / pixel_clk
// 25.2MHz 读), 本项目第一条 ctrl↔pixel 跨域数据通路的核心.
//
// 结构: 标准灰码指针异步 FIFO.
//   * 读写指针各带 1 位回绕扩展位 (AW+1 位), 二进制形式留在本域做存储寻址
//     与占用数计算, 格雷码形式跨域.
//   * 指针跨域各经 2 级触发器同步. 格雷码逐拍只变 1 位, 同步器采到的一致性
//     快照保证: 满判断只会偏保守 (写侧看到的读指针落后), 空判断只会偏保守
//     (读侧看到的写指针落后), 不存在"看起来不空实际已空"的漏判.
//   * almost_full 按写侧可见占用数计算: 占用 > DEPTH-AFULL_MARGIN 时置位.
//     读指针同步滞后使该判断只提前不滞后 (保守方向), 写侧以 !almost_full
//     为唯一写门控即可保证不满.
//   * full 同样同步于 wr_clk, 作为存储保护的最后一级门控 (写侧契约上由
//     almost_full 门控, full 仅兜底).
//   * 读数据为寄存输出: rd_en 当拍被接收 (rd_fire) 后, 下一拍 rd_data 有效;
//     无读拍时 rd_data 保持不变. 上游以"发 rd_en 后下一拍取样"使用.
//
// 复位协议: 两侧复位各自异步断言、各自时钟域内经 2 级同步释放 (wr_rst_n_i /
// rd_rst_n_i), 分属两个时钟域, 不共享释放时序. 指针与同步器由各自域复位清零;
// 两侧释放完成后互见指针均为 0, 数据流动从头开始.
//
// 参数: DEPTH 必须为 2 的幂; AFULL_MARGIN 为 almost_full 距满的裕量, 同时
// 吸收读指针 2FF 同步滞后期间读侧继续取走的数据量 (滞后方向为保守, 不影响
// 安全性, 只影响 almost_full 提前量).
// ============================================================================
module fdi_async_pixel_fifo #(
    parameter integer DEPTH        = 1024,  // 必须为2的幂
    parameter integer AFULL_MARGIN = 36     // almost_full 距满的裕量
)(
    input  wire        wr_clk,      // ctrl_clk 50MHz
    input  wire        wr_rst_n,    // 异步低有效
    input  wire        wr_en,
    input  wire [31:0] wr_data,
    output wire        full,
    output wire        almost_full, // 剩余空间 < AFULL_MARGIN
    input  wire        rd_clk,      // pixel_clk 25.2MHz
    input  wire        rd_rst_n,    // 异步低有效
    input  wire        rd_en,
    output wire [31:0] rd_data,     // 寄存输出: rd_en后1拍有效
    output wire        empty,
    output reg         prefilled   // 写侧至少640词预填后保持
);

    localparam integer AW = $clog2(DEPTH);

    // 跨域指针格雷码 (各自本域寄存器值, 供对方域 2FF 同步采样)
    wire [AW:0] wr_gray;
    wire [AW:0] rd_gray;

    // 二进制 -> 格雷码 / 格雷码 -> 二进制 (AW+1 位, 含回绕扩展位)
    function [AW:0] f_bin2gray;
        input [AW:0] b;
        begin
            f_bin2gray = b ^ (b >> 1);
        end
    endfunction

    function [AW:0] f_gray2bin;
        input [AW:0] g;
        reg   [AW:0] b;
        integer j;
        begin
            b[AW] = g[AW];
            for (j = AW - 1; j >= 0; j = j - 1)
                b[j] = b[j + 1] ^ g[j];
            f_gray2bin = b;
        end
    endfunction

    // ------------------------------------------------------------------
    // 写域: 复位同步释放 + 写指针 + 读指针接收同步 + 满标志
    // ------------------------------------------------------------------
    reg  [1:0]  wr_rst_sync;
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n)
            wr_rst_sync <= 2'b00;
        else
            wr_rst_sync <= {wr_rst_sync[0], 1'b1};
    end
    wire wr_rst_n_i = wr_rst_sync[1];

    reg  [AW:0] wr_bin;
    assign wr_gray = f_bin2gray(wr_bin);

    (* ASYNC_REG="TRUE" *) reg [AW:0] rd_gray_w1, rd_gray_w2; // 读指针 2FF
    always @(posedge wr_clk or negedge wr_rst_n_i) begin
        if (!wr_rst_n_i) begin
            rd_gray_w1 <= {(AW + 1){1'b0}};
            rd_gray_w2 <= {(AW + 1){1'b0}};
        end else begin
            rd_gray_w1 <= rd_gray;
            rd_gray_w2 <= rd_gray_w1;
        end
    end

    wire [AW:0] rd_bin_w  = f_gray2bin(rd_gray_w2);
    wire [AW:0] occ_w     = wr_bin - rd_bin_w;  // 写侧可见占用数(保守偏大)

    // DEPTH 为 2 的幂: 扩展位形式 = 1 后跟 AW 个 0
    localparam [AW:0] DEPTH_EXT = {{1'b1}, {AW{1'b0}}};

    assign full        = (occ_w == DEPTH_EXT);
    localparam integer AFULL_COUNT = DEPTH - AFULL_MARGIN;
    localparam integer BOOT_COUNT = 640;
    localparam [AW:0] AFULL_LEVEL = AFULL_COUNT[AW:0];
    assign almost_full = (occ_w > AFULL_LEVEL);
    always @(posedge wr_clk or negedge wr_rst_n_i) begin
        if (!wr_rst_n_i) prefilled <= 1'b0;
        else if (occ_w >= BOOT_COUNT[AW:0]) prefilled <= 1'b1;
    end

    wire wr_fire = wr_en && !full;

    (* ram_style="bram_32k" *) reg [31:0] mem [0:DEPTH-1];
    always @(posedge wr_clk) begin
        if (wr_fire)
            mem[wr_bin[AW-1:0]] <= wr_data;
    end

    always @(posedge wr_clk or negedge wr_rst_n_i) begin
        if (!wr_rst_n_i)
            wr_bin <= {(AW + 1){1'b0}};
        else if (wr_fire)
            wr_bin <= wr_bin + {{AW{1'b0}}, 1'b1};
    end

    // ------------------------------------------------------------------
    // 读域: 复位同步释放 + 读指针 + 写指针接收同步 + 空标志 + 寄存读出
    // ------------------------------------------------------------------
    reg  [1:0]  rd_rst_sync;
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n)
            rd_rst_sync <= 2'b00;
        else
            rd_rst_sync <= {rd_rst_sync[0], 1'b1};
    end
    wire rd_rst_n_i = rd_rst_sync[1];

    reg  [AW:0] rd_bin;
    assign rd_gray = f_bin2gray(rd_bin);

    (* ASYNC_REG="TRUE" *) reg [AW:0] wr_gray_r1, wr_gray_r2; // 写指针 2FF
    always @(posedge rd_clk or negedge rd_rst_n_i) begin
        if (!rd_rst_n_i) begin
            wr_gray_r1 <= {(AW + 1){1'b0}};
            wr_gray_r2 <= {(AW + 1){1'b0}};
        end else begin
            wr_gray_r1 <= wr_gray;
            wr_gray_r2 <= wr_gray_r1;
        end
    end

    wire [AW:0] wr_bin_r = f_gray2bin(wr_gray_r2);
    assign empty = (rd_bin == wr_bin_r);

    wire rd_fire = rd_en && !empty;

    reg [31:0] rd_data_r;
    always @(posedge rd_clk or negedge rd_rst_n_i) begin
        if (!rd_rst_n_i) begin
            rd_bin    <= {(AW + 1){1'b0}};
            rd_data_r <= 32'd0;
        end else if (rd_fire) begin
            rd_bin    <= rd_bin + {{AW{1'b0}}, 1'b1};
            rd_data_r <= mem[rd_bin[AW-1:0]];
        end
    end

    assign rd_data = rd_data_r;

endmodule
