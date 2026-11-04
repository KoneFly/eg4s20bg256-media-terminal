`timescale 1ns / 1ps
// ============================================================================
// transition_engine_curtain — 转场引擎(独立模块; ctrl 域 50MHz; 逐像素一拍, 无反压)
//
// 职责(单一): 把两路像素流 A(源/当前图)与 B(目标/下一图)按转场进度 trans_t
// 混合/选择成一路输出。进度与模式由 trans_progress(或集成方)在 vsync 边界
// 更新, 本模块内部不做进度计数; trans_mode/trans_t 帧内恒定是上游契约。
//
// 转场类型(trans_mode):
//   0 直接切换   out = A 路直通(混合通路整体旁路, 最低功耗)
//   1 淡入淡出   out = A + ((B-A)*N >>> 5), N = ceil(t/8) ∈ [0,32]
//                —— 三个通道各一个乘法(映射到 DSP), 不占 LUT;
//                   N=0 时空和恰为 A、N=32 时直通 B ⇒ 端点逐位精确
//   3 擦除       水平分界线自上向下推进: side_B ⟺ px_y*255+127 < t*480
//   4 幕布       上下两片黑幕向中线合拢盖住 A, 合拢后换 B 再向上下展开:
//                t<128 时半高 h=(t*15)>>3, 其余 h=((255-t)*15)>>3, 幕区
//                py<h 或 py>=480-h 输出黑; t<128 显示 A 否则 B(纯移位加)
//   2,5~7 保留   按直接切换处理(A 路直通)
//
// 端点精确性(验收判据): t=0 时 N=0 ⇒ 空和=0 ⇒ out=A 逐位相等; t=255 时
// N[5]=1 ⇒ 直通 B; 分界型比较器在 t=0/255 下两侧判式恒真/恒假 ⇒ 全 A/全 B。
//
// 输入流契约(与帧缓冲流式读口对接, 每显示像素):
//   * 淡入淡出: A、B 各一拍(先 A 后 B 的固定顺序最典型, 引擎对先后不敏感);
//     若同侧连拍(上游缺路), 缺侧以已到侧像素补齐射出 ⇒ 永不饿死、永不卡死;
//   * 分界型(擦除/幕布): 上游可只发选中路一拍(带宽减半), 也可两路都发
//     (引擎按 sel 丢弃未选中路); 选中判式与上游取数侧必须同式(见 SPEC);
//   * 直接切换: 只发 A 拍;
//   * px_x/px_y 在该像素的各拍期间保持稳定。
// 输出延迟(固定且已知): out_de/out_pixel 在"该像素完成拍"后第 1 拍出现;
//   完成拍 = 模式0 的 a 拍 / 模式1 的后到拍(含同侧补齐拍) / 分界型被选中路的拍。
//
// 时钟域: ctrl(50MHz, 与帧缓冲读口/取数链同域) —— A/B 流与像素坐标本就在
// ctrl 域产生, 引擎置于读响应与异步 FIFO 之间, 数据路径零跨域。
// ============================================================================

module transition_engine_curtain (
    input  wire        clk,
    input  wire        rst_n,
    // 像素流 A(源/当前图, 来自已缓存槽 A)
    input  wire        a_de,
    input  wire [15:0] a_pixel,      // RGB565
    // 像素流 B(目标/下一图, 来自已缓存槽 B)
    input  wire        b_de,
    input  wire [15:0] b_pixel,      // RGB565
    // 控制(准静态, 帧边界更新)
    input  wire [2:0]  trans_mode,   // 0=直接 1=淡入淡出 2=滑动 3=擦除 4=幕布 5~7保留
    input  wire [7:0]  trans_t,      // 进度 0~255(0=纯A, 255=纯B), 帧内恒定
    input  wire [11:0] px_x,         // 当前显示像素横坐标(分界型需要)
    input  wire [11:0] px_y,         // 当前显示像素纵坐标(擦除/幕布需要)
    // 输出(完成拍后固定 1 拍)
    output reg         out_de,
    output reg  [15:0] out_pixel
);

    // ------------------------------------------------------------------------
    // 模式译码
    // ------------------------------------------------------------------------
    wire mode_fade   = (trans_mode == 3'd1);
    wire mode_wipe   = (trans_mode == 3'd3);
    wire mode_curtain = (trans_mode == 3'd4);
    // 直接切换 = 模式 0 或保留模式: A 路直通
    wire mode_direct = !(mode_fade || mode_wipe || mode_curtain);

    // ------------------------------------------------------------------------
    // 淡入淡出: 混合权重 N = ceil(t/8) ∈ [0,32]
    //   t+7 最大 262, 9 位足够; [8:3] 即除 8 向上取整, 天然饱和到 32
    // ------------------------------------------------------------------------
    wire [8:0] t_p7    = {1'b0, trans_t} + 9'd7;
    wire [5:0] blend_n = t_p7[8:3];

    // 5 位域(R/B)混合: av + ((bv-av)*N >>> 5), 乘法映射到 DSP(结果与移位加展开逐位相同)
    // 结果恒在 [min(av,bv), max(av,bv)] 内, 无溢出、输出无需钳位; 算术右移 = 向下取整。
    function [4:0] blend5;
        input [4:0] av;
        input [4:0] bv;
        input [5:0] nn;
        reg signed [6:0]  d;
        reg signed [13:0] prod, sum;
        begin
            d    = $signed({2'b0, bv}) - $signed({2'b0, av});
            prod = d * $signed({1'b0, nn});
            sum  = $signed({9'b0, av}) + (prod >>> 5);
            blend5 = sum[4:0];
        end
    endfunction

    // 6 位域(G)混合: 同上
    function [5:0] blend6;
        input [5:0] av;
        input [5:0] bv;
        input [5:0] nn;
        reg signed [7:0]  d;
        reg signed [14:0] prod, sum;
        begin
            d    = $signed({2'b0, bv}) - $signed({2'b0, av});
            prod = d * $signed({1'b0, nn});
            sum  = $signed({9'b0, av}) + (prod >>> 5);
            blend6 = sum[5:0];
        end
    endfunction

    // ------------------------------------------------------------------------
    // 擦除: side_B ⟺ px_y*255 + 127 < t*480;  px*255 = (px<<8) - px, t*480 = (t<<9) - (t<<5)
    //   半像素偏置 127 使分界以子像素精度匀速推进且两端点严格全 A / 全 B
    // ------------------------------------------------------------------------
    wire [19:0] y255     = {8'b0, px_y, 8'b0} - {8'b0, px_y};
    wire [17:0] y_lhs    = y255[17:0] + 18'd127;      // ≤ 479*255+127 = 122272
    wire [17:0] t_w480   = {1'b0, trans_t, 9'b0} - {7'b0, trans_t, 5'b0};
    wire        sel_wipe  = (y_lhs < t_w480);

    // ------------------------------------------------------------------------
    // 幕布: 前半程合拢(显示 A), 后半程展开(显示 B); t=0 全 A, t=255 全 B
    // ------------------------------------------------------------------------
    wire        cur_open  = trans_t[7];
    wire [6:0]  cur_v     = cur_open ? ~trans_t[6:0] : trans_t[6:0];   // 0..127
    wire [10:0] cur_v15   = {cur_v, 4'b0} - {4'b0, cur_v};
    wire [11:0] cur_h     = {4'b0, cur_v15[10:3]};                       // 0..238
    wire        in_curt   = (px_y < cur_h) || (px_y >= 12'd480 - cur_h);

    // 分界型选中判(保留模式不会到达此处)
    wire sel_b = mode_wipe   ? sel_wipe   :
                 mode_curtain ? cur_open : 1'b0;

    // ------------------------------------------------------------------------
    // 淡入淡出配对状态与有效值
    // ------------------------------------------------------------------------
    reg        a_seen, b_seen;
    reg [15:0] a_q, b_q;

    wire have_a = a_de || a_seen;
    wire have_b = b_de || b_seen;
    wire [15:0] a_eff = a_de ? a_pixel : a_q;
    wire [15:0] b_eff = b_de ? b_pixel : b_q;
    wire [15:0] fade_mix = {blend5(a_eff[15:11], b_eff[15:11], blend_n),
                            blend6(a_eff[10:5],  b_eff[10:5],  blend_n),
                            blend5(a_eff[4:0],   b_eff[4:0],   blend_n)};
    wire [15:0] fade_out = blend_n[5] ? b_eff : fade_mix;   // t≥249 ⇒ 纯 B

    // ------------------------------------------------------------------------
    // 发射逻辑: 每像素至多一射, 恒在完成拍后第 1 拍
    // ------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_de    <= 1'b0;
            out_pixel <= 16'd0;
            a_seen    <= 1'b0;
            b_seen    <= 1'b0;
            a_q       <= 16'd0;
            b_q       <= 16'd0;
        end else begin
            out_de <= 1'b0;
            if (mode_fade) begin
                if (have_a && have_b) begin
                    // 完成拍: 双到即射(同拍双到亦然); 配对即消耗, 两标志全清
                    // (同侧重复到达由下方分支处理 —— 缺侧以已到侧补齐防饿死)
                    out_de    <= 1'b1;
                    out_pixel <= fade_out;
                    a_seen    <= 1'b0;
                    b_seen    <= 1'b0;
                    a_q       <= a_de ? a_pixel : a_q;
                    b_q       <= b_de ? b_pixel : b_q;
                end else if (a_de && a_seen) begin
                    // A 重复且 B 缺席: 上像素以其 A 补齐射出, 本拍 A 另起新配对
                    out_de    <= 1'b1;
                    out_pixel <= a_q;
                    a_q       <= a_pixel;
                end else if (b_de && b_seen) begin
                    out_de    <= 1'b1;
                    out_pixel <= b_q;
                    b_q       <= b_pixel;
                end else begin
                    if (a_de) begin a_seen <= 1'b1; a_q <= a_pixel; end
                    if (b_de) begin b_seen <= 1'b1; b_q <= b_pixel; end
                end
            end else if (mode_direct) begin
                // 直接切换: A 路直通, B 路忽略
                if (a_de) begin
                    out_de    <= 1'b1;
                    out_pixel <= a_pixel;
                end
                a_seen <= 1'b0;
                b_seen <= 1'b0;
            end else begin
                // 分界型: 仅被选中路发射(上游可只发选中路, 也可两路都发)
                if (a_de && !sel_b) begin
                    out_de    <= 1'b1;
                    out_pixel <= (mode_curtain && in_curt) ? 16'd0 : a_pixel;
                end else if (b_de && sel_b) begin
                    out_de    <= 1'b1;
                    out_pixel <= (mode_curtain && in_curt) ? 16'd0 : b_pixel;
                end
                a_seen <= 1'b0;
                b_seen <= 1'b0;
            end
        end
    end

endmodule
