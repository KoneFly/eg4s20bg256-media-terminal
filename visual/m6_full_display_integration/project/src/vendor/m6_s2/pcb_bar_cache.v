`timescale 1ns/1ps
// ============================================================================
// pcb_bar_cache —— T2 音柱字（misc 64..127）的写侧镜像缓存。
//
// 用途：底部柱形图（procedural 平面）需要按 x/5 通道反查 barH/barPeak，而冻结
// 契约的 st_misc 读口每拍只能服务一个地址（逐类变址读已占满）。故把写口落在
// misc 64..127 的字镜像进本缓存，像素域经独立读口取用，消除端口冲突。
// 内容与 T2 对应字恒等（同一写口同步写入），不属复位域。
// ============================================================================
module pcb_bar_cache (
    input  wire        clk,
    input  wire [5:0]  rd_addr,      // = 通道 col[6:1]（字 = misc[64+col>>1]）
    output reg  [31:0] rd_data,
    // 写侧（wr_clk 域；地址范围译码在顶层完成）
    input  wire        wr_clk,
    input  wire        we,
    input  wire [5:0]  wr_addr,
    input  wire [31:0] wr_data
);

    reg [31:0] mem [0:63];

    always @(posedge wr_clk) begin
        if (we)
            mem[wr_addr] <= wr_data;
    end

    always @(posedge clk) begin
        rd_data <= mem[rd_addr];
    end

endmodule
