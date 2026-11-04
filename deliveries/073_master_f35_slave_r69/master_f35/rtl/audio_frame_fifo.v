`timescale 1ns / 1ps
// audio_frame_fifo：音频帧异步FIFO。写侧提供成对样本，读侧按请求寄存输出，空时保持读数据。
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
    (* async_reg="true", preserve="true" *) wire wr_rst_first_stage;
`ifdef SIMULATION
    reg wr_rst_first_sim;
    always @(posedge wr_clk or posedge wr_rst)begin
        if(wr_rst)wr_rst_first_sim<=1'b1;
        else wr_rst_first_sim<=1'b0;
    end
    assign wr_rst_first_stage=wr_rst_first_sim;
`else
    wire [1:0] unused_lut,unused_fx;
    wire unused_carry,unused_second_ff;
    EG_PHY_MSLICE #(
        .INIT_LUT0(16'h0000),.INIT_LUT1(16'h0000),.MODE("LOGIC"),
        .CEMUX("1"),.SRMUX("INV"),.CLKMUX("CLK"),.SRMODE("ASYNC"),.DFFMODE("FF"),
        .REG0_SD("MI"),.REG1_SD("MI"),.REG0_REGSET("SET"),.REG1_REGSET("SET")
    ) u_wr_rst_first_ff(
        .a(2'd0),.b(2'd0),.c(2'd0),.d(2'd0),.mi(2'b00),
        .clk(wr_clk),.ce(1'b1),.sr(~wr_rst),.fci(1'b0),
        .f(unused_lut),.fx(unused_fx),.q({unused_second_ff,wr_rst_first_stage}),.fco(unused_carry),
        .dpram_mode(1'b0),.dpram_di(2'd0),.dpram_we(1'b0),.dpram_wclk(1'b0),.dpram_waddr(4'd0)
    );
`endif
    reg wr_rst_sync_second;
    always @(posedge wr_clk or posedge wr_rst)begin
        if(wr_rst)wr_rst_sync_second<=1'b1;
        else wr_rst_sync_second<=wr_rst_first_stage;
    end
    wire wr_rst_i=wr_rst_sync_second;

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
