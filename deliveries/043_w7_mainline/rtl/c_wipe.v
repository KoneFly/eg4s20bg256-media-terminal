`timescale 1ns / 1ps
// ============================================================================
// c_wipe — C 类二级图墙内换图/换档转场合成器 (纯组合; ctrl 域)
//
// 设计: doc/P2B_PLAN.md §9; [task_043 C 类 2026-09-27]
//   C 类 = 二级图墙"内"的过渡, 不进 nn_scaler / line_supply bank, 走直通档。
//   铁律: 每个显示像素映射到唯一 (slot, 源x, 源y) ⇒ FE 逐像素取数守恒,
//         与 P1 多档机制(÷1/÷2/÷4 本就每帧源行数不同)完全兼容, 无结构性瓶颈。
//
// 两个子型(anim_c_sel):
//   C1 异图擦除(整张滑入滑出, 2026-09-27 主人裁定) (B2短按/轮播=下一张, C1长按=上一张):
//     边界 pos = k×16 (30 帧扫满 480/640)。新图作为完整一张从进入边滑入(内容
//     不变形), 旧图原位不动、被覆盖区域裁掉, 边界处硬拼接。方向性直观:
//       new_low(dir0上→下/dir2左→右): 新图占 [0,pos), src=disp;
//       !new_low(dir1下→上/dir3右→左): 新图占 [FULL-pos,FULL), src=disp-(FULL-pos);
//       旧图侧 src=disp(原位)。
//     纯加减, 无乘法/除法(早先"压缩推拉"版的组合除法曾致 SWNS=-34.8ns, 已废弃)。
//   C2 同图异档类溶解 (view_tick 纯换档, ÷1→÷2→÷4 高→低):
//     Bayer 4×4 像素级阈值抖动, 阈值 < k×16/30 的像素取新档(更低分辨率),
//     其余取旧档。随 k 增大新档像素占比 0→100%, 形成无方向颗粒溶解。
//     旧/新档均为同一 focus_slot, 仅 block_log2 不同(各档源行数不同属正常)。
//
// 端口语义:
//   输入显示坐标 (px,py) + 进度 k + 子型/方向/档位/槽; 输出该显示像素的
//   唯一源 (slot,x,y)。源坐标恒 < 1024(640×480 源图, 由闭式保证)。
//   rd_en 恒 1(二级图墙内满屏都有源; 槽未就绪由顶层 slot_ready 在外层判占位)。
//
// 方向编码 anim_c_dir (C1):
//   0=由上到下(下一张默认) 1=由下到上(上一张默认) 2=由左到右 3=由右到左
//   (左/右向为预留变体, 触发映射由顶层决定; 本模块全部支持)。
// ============================================================================
module c_wipe (
    input  wire [11:0] px,           // 显示像素坐标 (0..639 / 0..479)
    input  wire [11:0] py,
    // [C2 时长加倍] k 扩 6 位: C1 仍 1..29(pos=k×16); C2 1..58, 溶解阈值用 k>>2
    //   (60 帧 → 0..14, 慢一倍更细腻); C1 路径只用低 5 位语义, k≤29 恒 bit5=0。
    input  wire [5:0]  k,            // 动画进度 (C1≤29 / C2≤58)
    input  wire        anim_c_sel,   // 0=C1 异图擦除  1=C2 同图异档溶解
    input  wire [1:0]  anim_c_dir,   // C1 方向 (见上)
    input  wire [1:0]  c_src_slot,   // C1 旧图槽 / C2 当前槽(不变)
    input  wire [1:0]  c_dst_slot,   // C1 新图槽
    input  wire [3:0]  c_old_blk,    // C2 旧档 block_log2 (0/1/2)
    input  wire [3:0]  c_new_blk,    // C2 新档 block_log2

    output reg         rd_en,
    output reg  [1:0]  rd_slot,
    output reg  [9:0]  rd_x,
    output reg  [9:0]  rd_y
);

    // ------------------------------------------------------------------
    // 进度 → 边界位置 (C1 用; k=1..29 → pos=16..464; 满屏 480/640 在 k=30=提交帧
    //   由正常通路渲染, 故 k≤29 时 pos 恒在 (0,FULL) 开区间内, extent 均 >0。
    //   C1 的 k 恒 ≤29, bit5=0, k<<4 ≤ 464 不溢出; C2 不用 pos)
    // ------------------------------------------------------------------
    wire [11:0] pos = {6'd0, k} << 4;        // k×16 (C1 专用, k≤29)

    // 方向是否为纵向(行擦除): 0/1=纵, 2/3=横
    wire dir_vert = (anim_c_dir[1] == 1'b0);
    // 新图是否占据"低坐标侧"(上/左): 方向 0(上→下)与 2(左→右) 新图在低侧
    wire new_low  = (anim_c_dir == 2'd0) || (anim_c_dir == 2'd2);

    // 沿擦除轴的显示坐标与该轴满屏尺寸
    wire [11:0] disp = dir_vert ? py : px;    // 行擦除看 y, 列擦除看 x
    wire [11:0] FULL = dir_vert ? 12'd480 : 12'd640;

    // ------------------------------------------------------------------
    // [C1 整张滑入滑出 2026-09-27 主人裁定] 新图作为完整一张从进入边滑入(内容
    //   不变形), 旧图原位不动、被新图覆盖的区域裁掉, 边界处硬拼接。方向性直观:
    //   新图从哪边进入, 内容就从哪边开始向对边铺满。无压缩 ⇒ 无 step 乘法。
    //   new_low(dir0上→下/dir2左→右): 新图占低坐标侧 [0,pos), src=disp(顶/左行贴边);
    //                                     旧图占 [pos,FULL), src=disp(原位, 顶部被盖)。
    //   !new_low(dir1下→上/dir3右→左): 新图占高坐标侧 [FULL-pos,FULL),
    //                                     src=disp-(FULL-pos)(从进入边起算);
    //                                     旧图占 [0,FULL-pos), src=disp(原位, 底部被盖)。
    // ------------------------------------------------------------------
    // 当前像素是否落在"新图侧"
    wire in_new = new_low ? (disp < pos) : (disp >= (FULL - pos));

    // 新图侧源坐标: 从进入边起算(区域内偏移); 旧图侧源坐标 = disp(原位)
    wire [11:0] c1_src_new = new_low ? disp : (disp - (FULL - pos));
    wire [11:0] c1_src_old = disp;

    // C1 源坐标: 沿擦除轴取新/旧侧源, 垂直轴恒等(纯滑入; 3D 斜向位移已回退 ——
    //   上板实测斜向交叉轨迹显乱, 不如干净直线滑入, 2026-09-27 主人裁定回退)
    wire [11:0] c1_sy = dir_vert ? (in_new ? c1_src_new : c1_src_old) : py;
    wire [11:0] c1_sx = dir_vert ? px : (in_new ? c1_src_new : c1_src_old);

    // ------------------------------------------------------------------
    // C2 溶解: Bayer 4×4 阈值抖动 (行/列低 2 位索引 0..15 阈值)
    //   阈值表按 4×4  Bayer 矩阵, 值域 0..15; 比较阈值 = k×16/30 ≈ (k<<4)/30,
    //   用 k≤29 → thr ≤ 15 近似 thr = k>>1 (k/2), 单调 0→14, 足够平滑。
    // ------------------------------------------------------------------
    wire [1:0] bx = px[1:0];
    wire [1:0] by = py[1:0];
    reg  [3:0] bayer;
    always @* begin
        case ({by, bx})
            4'd0 : bayer = 4'd0;   4'd1 : bayer = 4'd8;
            4'd2 : bayer = 4'd2;   4'd3 : bayer = 4'd10;
            4'd4 : bayer = 4'd12;  4'd5 : bayer = 4'd4;
            4'd6 : bayer = 4'd14;  4'd7 : bayer = 4'd6;
            4'd8 : bayer = 4'd3;   4'd9 : bayer = 4'd11;
            4'd10: bayer = 4'd1;   4'd11: bayer = 4'd9;
            4'd12: bayer = 4'd15;  4'd13: bayer = 4'd7;
            4'd14: bayer = 4'd13;  4'd15: bayer = 4'd5;
            default: bayer = 4'd0;
        endcase
    end
    // [C2 时长加倍] 溶解阈值慢一倍: k>>2 (60 帧 k=1..58 → 0..14), 渐进更细腻;
    //   高→低(c_new_blk>c_old_blk)用本 Bayer 溶解(新档像素占比 0→100%)。
    wire [3:0] thr = {2'b00, k[5:2]};        // k/4: 1..58 → 0..14
    wire       use_new_gear = (bayer < thr);

    // [C2 黑场过渡 2026-09-27 主人裁定] 低→高(c_new_blk<c_old_blk, 即 ÷4→÷1 回高清)
    //   改用 dip-to-black: 前半程(k=1..29)旧图渐隐到黑, 后半程(k=30..58)新图从黑渐现。
    //   用 Bayer 阈值控制黑像素占比渐变, rd_en=0 时顶层显黑。不混色、不缩放, 守恒。
    //   前半: 黑占比 thr_fade=k>>1 (0→14 渐隐); 后半: thr_fade=(58-k)>>1 (14→0 渐现)。
    wire       to_hires = (c_new_blk < c_old_blk);   // 低→高(回高清)
    wire       fade_out = to_hires && (k <= 6'd29);  // 前半程: 旧图渐隐
    wire [5:0] kback    = 6'd58 - k;                 // 后半程反向进度 28..0
    wire [3:0] thr_fade = fade_out ? {2'b00, k[4:1]}        // 渐隐 0→14
                                   : {2'b00, kback[4:1]};   // 渐现 14→0
    wire       is_black = to_hires && (bayer < thr_fade);   // 该像素显黑

    // C2 源坐标: 与 view_mapper 二级满屏同闭式 —— (v & blk_mask) << 0(scale=0)
    //   block 内像素共用块左上源样本; 旧/新档各自 block_log2。
    //   黑场: 前半程显旧档, 后半程显新档(被 is_black 遮罩的像素 rd_en=0 显黑)。
    //   溶解(高→低): use_new_gear 选档。
    wire [3:0]  c2_blk  = to_hires ? (fade_out ? c_old_blk : c_new_blk)
                                   : (use_new_gear ? c_new_blk : c_old_blk);
    wire [11:0] c2_mask = ~((12'd1 << c2_blk) - 12'd1);
    wire [11:0] c2_sx   = px & c2_mask;
    wire [11:0] c2_sy   = py & c2_mask;

    // ------------------------------------------------------------------
    // 输出选择
    // ------------------------------------------------------------------
    always @* begin
        if (anim_c_sel) begin
            // C2 同图异档: 槽不变, 仅 block 不同; 黑场像素 rd_en=0(显黑)
            rd_en   = !is_black;
            rd_slot = c_src_slot;
            rd_x    = c2_sx[9:0];
            rd_y    = c2_sy[9:0];
        end else begin
            // C1 异图擦除: 槽按所在侧, 源坐标沿轴平移 + 斜向推拉偏移
            rd_en   = 1'b1;                             // 图墙内满屏有源
            rd_slot = in_new ? c_dst_slot : c_src_slot;
            rd_x    = c1_sx[9:0];
            rd_y    = c1_sy[9:0];
        end
    end

endmodule
