`timescale 1ps / 1ps
// 仿真替身: PLL 按标称频率独立产生时钟(像素/音频与 ctrl 不同源, 覆盖跨域);
// pll_rst_n 拉低时失锁, 释放后延时重新锁定(与实板 KEY1 全局复位经 PLL 失锁传播一致)。
// HDMI 发送端只做端口终结(加密 IP 不参与功能仿真, 像素/音频在 DUT 内部观测)。
module sdram_clk_gen_50m (
    input  wire ref_clk, input wire pll_rst_n,
    output wire ctrl_clk, output wire mem_clk, output reg pll_locked
);
    assign ctrl_clk = ref_clk;
    assign mem_clk  = ~ref_clk;
    initial pll_locked = 1'b0;
    always @(negedge pll_rst_n) pll_locked = 1'b0;
    always @(posedge pll_rst_n) begin #1000000; if (pll_rst_n) pll_locked = 1'b1; end
endmodule

module hdmi_pll (
    input  wire ref_clk, input wire pll_rst_n,
    output reg pixel_clk, output wire serial_clk, output reg audio_mclk, output reg pll_locked
);
    initial begin pixel_clk = 1'b0; forever #19841 pixel_clk = ~pixel_clk; end     // 25.2MHz
    initial begin audio_mclk = 1'b0; forever #40625 audio_mclk = ~audio_mclk; end   // 12.3077MHz
    assign serial_clk = 1'b0;
    initial pll_locked = 1'b0;
    always @(negedge pll_rst_n) pll_locked = 1'b0;
    always @(posedge pll_rst_n) begin #1300000; if (pll_rst_n) pll_locked = 1'b1; end
endmodule

module hdmi_out (
    input  wire        pixel_clk, serial_clk, rst, rst_phy, i_vs, i_de,
    input  wire [15:0] i_rgb565,
    output wire        video_locked,
    input  wire        audio_valid,
    input  wire [23:0] audio_left, audio_right,
    input  wire        acr_valid,
    input  wire [19:0] acr_cts, acr_n,
    output wire        HDMI_CLK_P, HDMI_D0_P, HDMI_D1_P, HDMI_D2_P, HDMI_DDC_SCL,
    inout  wire        HDMI_DDC_SDA
);
    assign video_locked = 1'b1;
    assign {HDMI_CLK_P, HDMI_D0_P, HDMI_D1_P, HDMI_D2_P, HDMI_DDC_SCL} = 5'b0;
endmodule
