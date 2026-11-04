`timescale 1 ns / 10 ps
//------------------------------------------------------------------------------
// 帧结果记录 FIFO: 32bit x 64, 收包机 -> 统计域。
// 结构沿用本工程已在主线上板验证的灰码指针异步 FIFO 做法(参考 task_032
// async_pixel_fifo, 见 PROJECT_LEDGER 登记), 本包按 32bit 宽度重写。
// 与参考实现的差异: 增加读侧占用数 usedw(供"最大 FIFO 占用"实测), 写侧
// 提供 space_ok(剩余 >= PUSH_BURST) 供无背压生产者在使用前判定整条记录能否
// 完整落入, 落不下就计数丢弃(契约要求溢出必须可见, 不得静默)。
//
// 搬域之后(app_clk 同时接 wr_clk 与 rd_clk): 这根 FIFO 退化成本域同步 FIFO,
// 灰码/2FF 那套只是让占用与空满比真实值保守两拍, 不再有亚稳风险。保留原结构
// 而不重写, 是为了让"记录不会静默丢 + 溢出必须计数"这两条已经板验证过的性质
// 原样不动(字节级的真跨域已经由 ethm_bafifo 承担)。
//------------------------------------------------------------------------------
module ethm_rec_fifo (
    input  wire        wr_clk,
    input  wire        wr_rst,
    input  wire        wr_en,
    input  wire [31:0] wr_data,
    output wire        wr_full,
    output wire        wr_space_ok,

    input  wire        rd_clk,
    input  wire        rd_rst,
    input  wire        rd_en,
    output wire [31:0] rd_data,
    output wire        rd_empty,
    output wire [6:0]  rd_usedw
);
    localparam integer DEPTH      = 64;
    localparam integer PUSH_BURST = 8;
    localparam integer AW         = 6;   // log2(DEPTH)
    localparam [AW:0] SPACE_MIN   = 7'd56;   // DEPTH - PUSH_BURST = 64 - 8

    wire [AW:0] wr_gray;
    wire [AW:0] rd_gray;

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

    // ---------------- 写域 ----------------
    reg  [AW:0] wr_bin;
    assign wr_gray = f_bin2gray(wr_bin);

    reg  [AW:0] rd_gray_w1;
    reg  [AW:0] rd_gray_w2;
    always @(posedge wr_clk) begin
        if (wr_rst) begin
            rd_gray_w1 <= {(AW + 1){1'b0}};
            rd_gray_w2 <= {(AW + 1){1'b0}};
        end
        else begin
            rd_gray_w1 <= rd_gray;
            rd_gray_w2 <= rd_gray_w1;
        end
    end

    wire [AW:0] rd_bin_w = f_gray2bin(rd_gray_w2);
    wire [AW:0] occ_w    = wr_bin - rd_bin_w;

    localparam [AW:0] DEPTH_EXT = {1'b1, {AW{1'b0}}};

    assign wr_full       = (occ_w == DEPTH_EXT);
    assign wr_space_ok   = (occ_w <= SPACE_MIN);
    wire                 wr_fire = wr_en && !wr_full;

    reg [31:0] mem [0:DEPTH-1];
    always @(posedge wr_clk) begin
        if (wr_fire)
            mem[wr_bin[AW-1:0]] <= wr_data;
    end

    always @(posedge wr_clk) begin
        if (wr_rst)
            wr_bin <= {(AW + 1){1'b0}};
        else if (wr_fire)
            wr_bin <= wr_bin + {{AW{1'b0}}, 1'b1};
    end

    // ---------------- 读域 ----------------
    reg  [AW:0] rd_bin;
    assign rd_gray = f_bin2gray(rd_bin);

    reg  [AW:0] wr_gray_r1;
    reg  [AW:0] wr_gray_r2;
    always @(posedge rd_clk) begin
        if (rd_rst) begin
            wr_gray_r1 <= {(AW + 1){1'b0}};
            wr_gray_r2 <= {(AW + 1){1'b0}};
        end
        else begin
            wr_gray_r1 <= wr_gray;
            wr_gray_r2 <= wr_gray_r1;
        end
    end

    wire [AW:0] wr_bin_r = f_gray2bin(wr_gray_r2);
    wire [AW:0] used_ext = wr_bin_r - rd_bin;
    assign rd_usedw = used_ext[6:0];
    assign rd_empty = (rd_bin == wr_bin_r);
    wire            rd_fire = rd_en && !rd_empty;

    reg [31:0] rd_data_r;
    always @(posedge rd_clk) begin
        if (rd_rst) begin
            rd_bin     <= {(AW + 1){1'b0}};
            rd_data_r  <= 32'd0;
        end
        else begin
            if (rd_fire) begin
                rd_bin    <= rd_bin + {{AW{1'b0}}, 1'b1};
                rd_data_r <= mem[rd_bin[AW-1:0]];
            end
        end
    end

    assign rd_data = rd_data_r;
endmodule
