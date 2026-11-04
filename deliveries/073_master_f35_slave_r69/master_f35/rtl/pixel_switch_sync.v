`timescale 1ns/1ps
// 首级显式逻辑片，次级普通触发器；异步输入始终经过两个同域寄存级。
module pixel_switch_sync(
    input wire clk,rst,async_input,
    output reg sync_output
);
    (* async_reg="true", preserve="true" *) wire first_stage;
`ifdef SIMULATION
    reg first_sim;
    always @(posedge clk or posedge rst)begin
        if(rst)first_sim<=1'b0;else first_sim<=async_input;
    end
    assign first_stage=first_sim;
`else
    wire [1:0] unused_lut,unused_fx;
    wire unused_carry,unused_second_ff;
    EG_PHY_MSLICE #(
        .INIT_LUT0(16'h0000),.INIT_LUT1(16'h0000),.MODE("LOGIC"),
        .CEMUX("1"),.SRMUX("INV"),.CLKMUX("CLK"),.SRMODE("ASYNC"),.DFFMODE("FF"),
        .REG0_SD("MI"),.REG1_SD("MI"),.REG0_REGSET("RESET"),.REG1_REGSET("RESET")
    ) u_first_ff(
        .a(2'd0),.b(2'd0),.c(2'd0),.d(2'd0),.mi({1'b0,async_input}),
        .clk(clk),.ce(1'b1),.sr(~rst),.fci(1'b0),
        .f(unused_lut),.fx(unused_fx),.q({unused_second_ff,first_stage}),.fco(unused_carry),
        .dpram_mode(1'b0),.dpram_di(2'd0),.dpram_we(1'b0),.dpram_wclk(1'b0),.dpram_waddr(4'd0)
    );
`endif
    always @(posedge clk or posedge rst)begin
        if(rst)sync_output<=1'b0;else sync_output<=first_stage;
    end
endmodule
