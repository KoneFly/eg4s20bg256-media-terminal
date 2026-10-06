// ============================================================================
// rgb565_to_rgb888 — RGB565 → RGB888 像素位宽扩展 (Task 015)
//
// 依据 INTERFACE_SPEC.md 冻结契约:
//   * 0 拍纯组合直通: pixel_valid_out = pixel_valid, pixel_rgb888 为纯组合
//     位拼接函数, 无任何寄存器/状态 (寄存决策属于 Task 016 适配层)。
//   * 扩展规则 (TASK_BRIEF.md 冻结, 行业标准"复制高位"):
//       R8 = {R5, R5[4:2]}   G8 = {G6, G6[5:4]}   B8 = {B5, B5[4:2]}
//     端点: 0000→000000 / FFFF→FFFFFF / F800→FF0000 / 07E0→00FF00 / 001F→0000FF。
//     禁止乘除近似替代。
//   * clk/rst_n 按契约保留不消费: 本版为纯组合实现, 不存在可复位状态;
//     保留端口以维持与项目模板一致及未来流水版本兼容 (理由记录于
//     tb/handoff_packet.md, 满足 INTERFACE_SPEC.md 第 2 条)。
//   * valid=0 时输出扩展后的当前输入值, 不做清零 (契约: 无此要求, 下游
//     必须仅在 valid 时采样)。
// ============================================================================
`timescale 1ns/1ps
module rgb565_to_rgb888 (
    input  wire        clk,             // 25.2MHz（仅用于参考/未来扩展，本版组合实现不消费）
    input  wire        rst_n,           // 异步低有效（同上）
    input  wire        pixel_valid,     // 视觉像素有效（0 拍组合，跟随 DE）
    input  wire [15:0] pixel_rgb565,    // {R[4:0], G[5:0], B[4:0]}
    output wire        pixel_valid_out, // 直通 pixel_valid（组合）
    output wire [23:0] pixel_rgb888     // {R[7:0], G[7:0], B[7:0]}
);

    // 通道切片: {R[4:0], G[5:0], B[4:0]}
    wire [4:0] r5 = pixel_rgb565[15:11];
    wire [5:0] g6 = pixel_rgb565[10:5];
    wire [4:0] b5 = pixel_rgb565[4:0];

    // 复制高位扩展: 低 3/2 位重复高 3/2 位, 保证端点逐位相等 (0xFF 全饱和)。
    wire [7:0] r8 = {r5, r5[4:2]};
    wire [7:0] g8 = {g6, g6[5:4]};
    wire [7:0] b8 = {b5, b5[4:2]};

    assign pixel_valid_out = pixel_valid;
    assign pixel_rgb888    = {r8, g8, b8};

    // clk/rst_n 有意不消费: 纯组合无状态 (契约允许, 见文件头)。
    wire _unused_ok = &{1'b0, clk, rst_n};

endmodule
