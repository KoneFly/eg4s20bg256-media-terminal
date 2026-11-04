`timescale 1ns / 1ps
// ============================================================================
// sd_phy — SD 六线引脚级(50MHz 系统时钟)
//   SDCLK: ODDR 由 {h1,h2} 生成, h1 为系统时钟高电平半拍的输出电平;
//   CMD  : 负沿寄存输出 + 输出使能, 在 SDCLK 上升沿前半个系统周期变化;
//   CMD/DAT 输入: 系统时钟上升沿寄存一级(落 IOL 输入寄存器)。
//   DAT[3:0] 只读, 主机从不驱动(D3 不作 SPI 片选, 依赖外部上拉)。
// ============================================================================
module sd_phy (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       clk_h1,
    input  wire       clk_h2,
    input  wire       clk_inv,      // 交换 ODDR 两半拍(边沿映射的板级配置位)
    input  wire       cmd_o,
    input  wire       cmd_oe,
    output reg        cmd_i,
    output reg  [3:0] dat_i,

    output wire       sd_clk,
    inout  wire       sd_cmd,
    input  wire [3:0] sd_dat
);
    // FIXME: d0/d1 与高/低半周期的对应关系仍需按官方功能模型复核
    EG_LOGIC_ODDR #(.ASYNCRST("ENABLE")) u_clk_oddr (
        .q(sd_clk), .clk(clk), .d0(clk_inv ? clk_h2 : clk_h1), .d1(clk_inv ? clk_h1 : clk_h2), .rst(~rst_n));

    reg cmd_q, cmd_oe_q;
    always @(negedge clk or negedge rst_n)
        if (!rst_n) begin cmd_q <= 1'b1; cmd_oe_q <= 1'b0; end
        else begin cmd_q <= cmd_o; cmd_oe_q <= cmd_oe; end
    assign sd_cmd = cmd_oe_q ? cmd_q : 1'bz;

    always @(posedge clk) begin
        cmd_i <= sd_cmd;
        dat_i <= sd_dat;
    end
endmodule
