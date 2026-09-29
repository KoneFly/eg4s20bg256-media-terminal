`timescale 1ns / 1ps
// ============================================================================
// audio_frame_fifo — 32bit x 16 深双时钟异步 FIFO
// 写侧: 像素域 25.2MHz (wav_parser 帧流) / 读侧: mclk 域 12.3077MHz (i2s_master)
//
// 结构 (教科书级灰码指针异步 FIFO, 结构语义与 019 async_pixel_fifo 同源, 新写):
//   * 读写指针各带 1 位回绕扩展位 (AW+1 位), 二进制形式留在本域做存储寻址,
//     格雷码形式跨域。
//   * 指针跨域各经 2 级触发器同步。格雷码逐拍只变 1 位, 同步器采到的一致性
//     快照保证: full 判断只会偏保守 (宁早勿晚), empty 判断只会偏保守
//     (宁晚勿早), 不存在"看起来不空实际已空"的漏判。
//   * 读数据寄存输出: rd_en 被接收 (rd_fire) 后下一拍 rd_data 更新为新弹出帧;
//     无读拍时 rd_data 保持 (空时保持末值, 上游语义见 INTERFACE_SPEC F3)。
//
// 复位 (F4): wr_rst/rd_rst 高有效, 各自异步断言、各自时钟域内 2 级同步释放,
//   两域独立, 不共享释放时序。复位期间两侧指针清零、empty=1。
//   上游传入的域复位若已在各自域同步释放, 内部同步器为透传级联 (无害)。
// ============================================================================
module audio_frame_fifo (
    // 写侧 (像素域)
    input  wire        wr_clk,      // 25.2MHz
    input  wire        wr_rst,      // 高有效
    input  wire        wr_en,
    input  wire [15:0] wr_left,
    input  wire [15:0] wr_right,
    output wire        full,
    // 读侧 (mclk 域)
    input  wire        rd_clk,      // 12.3077MHz
    input  wire        rd_rst,      // 高有效
    input  wire        rd_en,
    output wire [31:0] rd_data,     // {left, right} (寄存输出)
    output wire        empty
);

    localparam integer DEPTH = 16;
    localparam integer AW   = 4;   // $clog2(DEPTH)

    // ------------------------------------------------------------------
    // 写域: 复位同步释放
    // ------------------------------------------------------------------
    reg [1:0] wr_rst_sync;
    always @(posedge wr_clk or posedge wr_rst) begin
        if (wr_rst)
            wr_rst_sync <= 2'b11;
        else
            wr_rst_sync <= {wr_rst_sync[0], 1'b0};
    end
    wire wr_rst_i = wr_rst_sync[1];

    // ------------------------------------------------------------------
    // 读域: 复位同步释放
    // ------------------------------------------------------------------
    reg [1:0] rd_rst_sync;
    always @(posedge rd_clk or posedge rd_rst) begin
        if (rd_rst)
            rd_rst_sync <= 2'b11;
        else
            rd_rst_sync <= {rd_rst_sync[0], 1'b0};
    end
    wire rd_rst_i = rd_rst_sync[1];

    // ------------------------------------------------------------------
    // 指针: 二进制 <-> 格雷码 (AW+1 位, 含回绕扩展位)
    // ------------------------------------------------------------------
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
    // 写域: 写指针 + 读指针接收同步 + 满标志
    // ------------------------------------------------------------------
    reg [AW:0] wr_bin;
    wire [AW:0] wr_gray = f_bin2gray(wr_bin);

    reg [AW:0] rd_gray_w1, rd_gray_w2;          // 读指针 2FF 同步到写域
    always @(posedge wr_clk or posedge wr_rst_i) begin
        if (wr_rst_i) begin
            rd_gray_w1 <= {(AW + 1){1'b0}};
            rd_gray_w2 <= {(AW + 1){1'b0}};
        end else begin
            rd_gray_w1 <= rd_gray;
            rd_gray_w2 <= rd_gray_w1;
        end
    end

    wire [AW:0] rd_bin_w = f_gray2bin(rd_gray_w2);
    wire [AW:0] occ_w    = wr_bin - rd_bin_w;   // 写侧可见占用数 (保守偏大)

    // DEPTH 为 2 的幂: 扩展位形式 = 1 后跟 AW 个 0
    localparam [AW:0] DEPTH_EXT = {{1'b1}, {AW{1'b0}}};

    assign full = (occ_w == DEPTH_EXT);

    wire wr_fire = wr_en && !full;

    reg [31:0] mem [0:DEPTH-1];
    always @(posedge wr_clk) begin
        if (wr_fire)
            mem[wr_bin[AW-1:0]] <= {wr_left, wr_right};
    end

    always @(posedge wr_clk or posedge wr_rst_i) begin
        if (wr_rst_i)
            wr_bin <= {(AW + 1){1'b0}};
        else if (wr_fire)
            wr_bin <= wr_bin + {{AW{1'b0}}, 1'b1};
    end

    // ------------------------------------------------------------------
    // 读域: 读指针 + 写指针接收同步 + 空标志 + 寄存读出
    // ------------------------------------------------------------------
    reg [AW:0] rd_bin;
    wire [AW:0] rd_gray = f_bin2gray(rd_bin);

    reg [AW:0] wr_gray_r1, wr_gray_r2;          // 写指针 2FF 同步到读域
    always @(posedge rd_clk or posedge rd_rst_i) begin
        if (rd_rst_i) begin
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
    always @(posedge rd_clk or posedge rd_rst_i) begin
        if (rd_rst_i) begin
            rd_bin    <= {(AW + 1){1'b0}};
            rd_data_r <= 32'd0;
        end else if (rd_fire) begin
            rd_bin    <= rd_bin + {{AW{1'b0}}, 1'b1};
            rd_data_r <= mem[rd_bin[AW-1:0]];
        end
    end

    assign rd_data = rd_data_r;

endmodule
