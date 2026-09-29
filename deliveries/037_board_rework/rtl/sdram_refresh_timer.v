`timescale 1ns / 1ps
// ============================================================================
// sdram_refresh_timer — 片上SDRAM 自动刷新定时器
//
// 刷新周期推导(片上SDRAM真实Die EM638325, Rev.3.2 Table 16):
//   tREFI = 15.625us (4096次刷新/64ms) -> @125MHz(8ns) = 1953.125, 取 1953 拍
//   (官方Anlogic公式 64ms/2^ROW_WIDTH=31.25us 偏宽松; 本设计按数据手册
//   直接值, 过刷新安全, 无副作用)
//
// 输出为电平请求, 直到控制器给出 ref_ack 才清零并重新计数,
// 保证控制器忙于读写事务时刷新请求不丢失。
// ============================================================================
module sdram_refresh_timer #(
    parameter integer REF_INTERVAL_CYCLES = 1953  // tREFI 15.625us @125MHz (EM638325)
)(
    input  wire clk,
    input  wire rst_n,
    output reg  refresh_req,   // 电平请求, 置位后保持到 ref_ack
    input  wire ref_ack        // 控制器完成一次 AUTO REFRESH 的确认脉冲
);

    reg [12:0] cnt;            // 3906 < 2^13

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt         <= 13'd0;
            refresh_req <= 1'b0;
        end else if (ref_ack) begin
            cnt         <= 13'd1;
            refresh_req <= 1'b0;
        end else if (refresh_req) begin
            cnt         <= cnt;                       // 等待服务期间冻结计数
        end else if (cnt >= REF_INTERVAL_CYCLES - 1) begin
            refresh_req <= 1'b1;
        end else begin
            cnt         <= cnt + 13'd1;
        end
    end

endmodule