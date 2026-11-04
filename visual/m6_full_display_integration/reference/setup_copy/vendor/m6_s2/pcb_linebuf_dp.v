`timescale 1ns/1ps
// ============================================================================
// pcb_linebuf_dp —— 640×16 单时钟简单双口行缓存（1 写口 + 1 同步读口）。
//
// 用途（3 实例）：膨胀列窗 2 条行缓存（light8|dark8 打包）、叠加底图 1 行延迟。
// 写口与读口地址由流水线错拍给出（读 addr=x 在第 3 级、写 addr=x 在第 4 级末沿），
// 同地址读写天然错开一拍，读永远得到旧值 —— 与 JS 行为一致。
// 存储内容不属于复位域（帧首 y<2 的抑制逻辑保证旧行不泄漏，见顶层）。
// ============================================================================
module pcb_linebuf_dp (
    input  wire        clk,
    input  wire [9:0]  rd_addr,
    output reg  [15:0] rd_data,
    input  wire        we,
    input  wire [9:0]  wr_addr,
    input  wire [15:0] wr_data
);

    reg [15:0] mem [0:639];

    always @(posedge clk) begin
        rd_data <= mem[rd_addr];
        if (we)
            mem[wr_addr] <= wr_data;
    end

endmodule
