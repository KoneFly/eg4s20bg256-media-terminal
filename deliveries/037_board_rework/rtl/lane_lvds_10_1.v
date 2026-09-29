`timescale 1ns / 1ps
// ============================================================================
// lane_lvds_10_1 — 10:1 TMDS 串化器 (EG4)
//
// 功能: 像素时钟域 10-bit 并行数据 -> 串行时钟域逐位串行输出。
//   serial_clk = 5x pixel_clk, 输出经 ODDR 双沿采样, 等效 10x pixel 数据率。
//
// 时序: 像素时钟域翻转 S_odd_even(每像素周期一次), 串行时钟域检测翻转沿
//   产生装载脉冲(每 5 个串行时钟周期一次), 装载 10-bit 并行数据后移位
//   寄存器每串行周期输出 2-bit, 5 拍内发完 10-bit, 恰好一个像素周期。
//   ODDR 上升沿输出当前 2-bit 组的低位、下降沿输出高位。
// ============================================================================
module lane_lvds_10_1 #(
    parameter DEVICE = "EG"
)(
    input  wire      I_pixel_clk,
    input  wire      I_serial_clk,
    input  wire      I_rst,
    input  wire [9:0] I_data_in,
    output wire      O_serial_out
);

    reg      S_odd_even;
    reg      S_odd_even_1d;
    reg      S_odd_even_2d;
    reg      S_load_en;
    reg      S_load_en_1d;
    reg      S_load_en_2d;
    reg [9:0] S_shift_data;
    reg [1:0] S_oddr_data;

    // 像素时钟域: 每像素周期翻转一次, 提供装载节拍
    always @(posedge I_pixel_clk or posedge I_rst) begin
        if (I_rst)
            S_odd_even <= 1'b0;
        else
            S_odd_even <= ~S_odd_even;
    end

    // 串行时钟域: 两级同步后异或检测翻转沿
    always @(posedge I_serial_clk) begin
        S_odd_even_1d <= S_odd_even;
        S_odd_even_2d <= S_odd_even_1d;
    end

    always @(posedge I_serial_clk) begin
        S_load_en    <= S_odd_even_1d ^ S_odd_even_2d;
        S_load_en_1d <= S_load_en;
        S_load_en_2d <= S_load_en_1d;
    end

    // 装载并行数据, 之后每串行周期左移 2 位
    always @(posedge I_serial_clk or posedge I_rst) begin
        if (I_rst)
            S_shift_data <= 10'd0;
        else if (S_load_en_2d)
            S_shift_data <= I_data_in;
        else
            S_shift_data <= S_shift_data << 2;
    end

    always @(posedge I_serial_clk) begin
        S_oddr_data <= S_shift_data[9:8];
    end

    generate
        if (DEVICE == "EG") begin : g_oddr
            EG_LOGIC_ODDR U_ODDR (
                .clk (I_serial_clk),
                .rst (I_rst),
                .d1  (S_oddr_data[0]),
                .d0  (S_oddr_data[1]),
                .q   (O_serial_out)
            );
        end
    endgenerate

endmodule