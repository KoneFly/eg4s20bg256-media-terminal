`timescale 1ns / 1ps
// 读数选择放在输出寄存器之前，恢复16路OREG形态。
// 上电/KEY1后自检只依赖板载时钟，不依赖UDP、PHY或PLL锁定。
module v7_dled_output #(
    parameter [26:0] SELFTEST_CYCLES=27'd100000000,
    parameter [26:0] QUARTER_CYCLES=27'd25000000
) (
    input wire clk, input wire rst_n, input wire app_reset,
    input wire diag_mode, input wire [15:0] normal_value, input wire [15:0] diag_value,
    output reg [15:0] value
);
    reg [26:0] boot_count;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            boot_count <= 0;
            value <= 16'ha55a;
        end else begin
            if (boot_count < SELFTEST_CYCLES) begin
                boot_count <= boot_count + 27'd1;
                if (boot_count < QUARTER_CYCLES) value <= 16'ha55a;
                else if (boot_count < QUARTER_CYCLES*27'd2) value <= 16'h5aa5;
                else if (boot_count < QUARTER_CYCLES*27'd3) value <= 16'hffff;
                else value <= 16'h0000;
            end else if (app_reset) value <= 16'he001;
            else if (diag_mode) value <= diag_value;
            else value <= normal_value;
        end
    end
endmodule
