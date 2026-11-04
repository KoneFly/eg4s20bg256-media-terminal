`timescale 1ns / 1ps
// 仿真用 ODDR 行为模型: 上升沿寄存 d0/d1, 时钟高电平期输出 d0、低电平期输出 d1。
// FIXME: 与真实原语的边沿映射未经官方功能模型核对(U03)
module EG_LOGIC_ODDR (q, clk, d1, d0, rst);
    output q;
    input  clk, d1, d0, rst;
    parameter ASYNCRST = "ENABLE";
    reg r0 = 1'b0, r1 = 1'b0;
    always @(posedge clk or posedge rst)
        if (rst) begin r0 <= 1'b0; r1 <= 1'b0; end
        else begin r0 <= d0; r1 <= d1; end
    assign #1 q = clk ? r0 : r1;
endmodule
