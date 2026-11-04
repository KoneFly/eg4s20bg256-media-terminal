`timescale 1ns/1ps
// 网络时钟保持125MHz双相；两个独立50MHz出口供状态更新和片上SDRAM。
module fdi_clock_tree (
    input wire reset, clk_in,
    output wire rst_out, clk_125, clk_125_90, ctrl_clk, mem_clk
);
    wire locked;
    wire ctrl_raw, mem_raw;
    pll_gen u_pll_0 (
        .refclk(clk_in), .reset(reset), .extlock(locked),
        .clk0_out(clk_125), .clk1_out(ctrl_raw), .clk2_out(),
        .clk3_out(mem_raw), .clk4_out(clk_125_90)
    );
    EG_LOGIC_BUFG u_ctrl_buf(.i(ctrl_raw), .o(ctrl_clk));
    EG_LOGIC_BUFG u_mem_buf(.i(mem_raw), .o(mem_clk));
    assign rst_out = !locked;
endmodule
