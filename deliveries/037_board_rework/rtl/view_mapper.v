`timescale 1ns / 1ps
// ============================================================================
// view_mapper — 显示坐标 → (槽号, 源坐标) 映射器 (纯组合; ctrl 域使用)
//
// 输入是一个"格"矩形 rect(x, y, w, h) 与两个独立的 2 的幂参数:
//   block_log2  抽稀块边长 B = 2^block_log2(块内像素共用块左上角的源样本)
//   scale_log2  格放大倍率 = 2^scale_log2(格宽 × 倍率 = 源图宽 640)
// 统一闭式(全部为减法 + 移位, 零乘除):
//   source_x = ((px - rect_x) >> block_log2) << (block_log2 + scale_log2)
//   source_y = ((py - rect_y) >> block_log2) << (block_log2 + scale_log2)
// "(v >> B) << B" 保留块状像素感, 不得化简为 v —— 块状才体现分辨率差异。
//
// view_mode:
//   0 = 图墙: 以 rect 为一格铺 2×2 四格(第 c 列 / r 行格原点 = rect 原点 + (c·w, r·h)),
//       格 {r, c} 读槽 {r, c}(四格四槽两两不同); 每格内侧 SEP_PX 像素宽的环带为
//       分隔带(不读 SDRAM), 焦点格的环带改作焦点边框。
//   1/2/3 = 单格满屏(÷1/÷2/÷4 由顶层经 block_log2 给出), 读 focus_slot。
//   rect 之外的像素不读 SDRAM(背景)。
//
// 输出语义(顶层据此着色):
//   rd_en     = 1: 该像素取缓存图像 (rd_slot, rd_x, rd_y); 为 0 时不得产生任何读请求;
//   pad_en    = 1: 格内图像区但该槽未就绪(slot_ready=0) ⇒ 占位色;
//   border_en = 1: 焦点格的分隔带 ⇒ 焦点边框色。
//   三者两两互斥; 全 0 = 背景/分隔带(黑)。
//
// 取值约束(由顶层保证, 本模块不检查): rect_w/rect_h ≥ 2·SEP_PX;
//   图墙 2·rect_w ≤ 4096, 源坐标 < 1024(640×480 源图下恒成立)。
// ============================================================================
module view_mapper #(
    parameter integer SEP_PX = 2
)(
    input  wire        in_de,
    input  wire [11:0] pixel_x,
    input  wire [11:0] pixel_y,
    input  wire [1:0]  view_mode,
    input  wire [1:0]  focus_slot,
    input  wire [3:0]  slot_ready,

    input  wire [11:0] rect_x,
    input  wire [11:0] rect_y,
    input  wire [11:0] rect_w,
    input  wire [11:0] rect_h,
    input  wire [3:0]  block_log2,
    input  wire [3:0]  scale_log2,

    output reg         rd_en,
    output reg  [1:0]  rd_slot,
    output reg  [9:0]  rd_x,
    output reg  [9:0]  rd_y,
    output reg         border_en,
    output reg         pad_en
);

    localparam [11:0] SEP12 = SEP_PX[11:0];

    wire wall = (view_mode == 2'd0);

    // 相对 rect 原点的偏移(13 位带符号借位: 最高位 = 像素在原点左/上方)
    wire [12:0] dx = {1'b0, pixel_x} - {1'b0, rect_x};
    wire [12:0] dy = {1'b0, pixel_y} - {1'b0, rect_y};
    wire        left_of = dx[12];
    wire        above   = dy[12];

    // 图墙列/行: 偏移 ≥ 一格宽/高即第 1 列/行(只铺 2×2, 无除法)
    wire        col = wall && !left_of && (dx[11:0] >= rect_w);
    wire        row = wall && !above   && (dy[11:0] >= rect_h);
    wire [11:0] lx  = dx[11:0] - (col ? rect_w : 12'd0);
    wire [11:0] ly  = dy[11:0] - (row ? rect_h : 12'd0);

    wire in_rect = in_de && !left_of && !above && (lx < rect_w) && (ly < rect_h);
    wire sep    = wall && ((lx < SEP12) || (lx >= rect_w - SEP12) ||
                           (ly < SEP12) || (ly >= rect_h - SEP12));

    wire [1:0] slot  = wall ? {row, col} : focus_slot;
    wire       ready = slot_ready[slot];

    // (v >> B) << B = 清掉低 B 位; 再左移 scale 位
    wire [11:0] blk_mask = ~((12'd1 << block_log2) - 12'd1);
    wire [11:0] sx = (lx & blk_mask) << scale_log2;
    wire [11:0] sy = (ly & blk_mask) << scale_log2;

    always @* begin
        rd_slot   = slot;
        rd_x      = sx[9:0];
        rd_y      = sy[9:0];
        rd_en     = in_rect && !sep && ready;
        pad_en    = in_rect && !sep && !ready;
        border_en = in_rect && sep && (slot == focus_slot);
    end

endmodule
