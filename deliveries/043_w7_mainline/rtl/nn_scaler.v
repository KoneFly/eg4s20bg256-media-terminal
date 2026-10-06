`timescale 1ns / 1ps
// ============================================================================
// nn_scaler — [task_043 P2a] 最近邻连续缩放模块(离线; TRANSITION_PHASED_GUIDE §7)
//
// 定位: A 类聚焦放大/缩小的"rect 内源坐标"产生器。替代 view_mapper 的
//   (block_log2,scale_log2) 整数档位, 实现格(320×240) ⇄ 满屏(640×480) 之间的
//   连续最近邻缩放; rect 外像素直通(rsp_in=0), 背景合成归 P2b。
//
// 几何(表见 nn_scaler_table.vh, 由 sim/gen_p2a_table.py 生成并自检):
//   w_k = 吸附 4 倍数的缓入缓出曲线 320→640, h = 3w/4(4:3 恒成立);
//   rect_x = slot[0] ? 640−w : 0, rect_y = slot[1] ? 480−h : 0
//   (对角锚定: 格 {cy,cx} 向满屏生长, 由构造保证单调且不越界)。
//
// 采样(三模式, 整像素量化规则):
//   端点态  = mapper 块公式精确对齐(逐像素一致, 冻结契约 P0 §3):
//             进入 k=0:  sx=(lx&~1)<<1          (图墙焦点格, blk=1,scl=1)
//             进入 k=30: sx=lx                  (二级 ÷1, blk=0,scl=0)
//             退出 k=0:  sx=lx&~((1<<gear)-1)   (二级 ÷1/÷2/÷4 块映射)
//             退出 k=30: 同进入 k=0
//   中间态  = 定点累加器最近邻(零乘除零 DSP):
//             S_k = round(640·2^12/w_k) 预计算入表;
//             src(lx) = (lx·S + 2^11) >> 12     (边对齐最近邻, lx=0→源0,
//             与 mapper 全部端点模式的 lx=0→0 语义一致);
//             RTL 以逐拍 acc += S 等价实现(受理拍推进, 背压/复位保持)。
//   k=29 与 k=30 几何相同且采样逐位一致(表自检, 尾端驻留); k=0→1 为已声明的
//   块映射→最近邻相位切换(整帧一致, 非跳倍)。
//
// 状态锁定: k/dir/gear/slot 仅在 frame_start 拍采样, 帧内变化忽略
//   (P2b 契约: 动画状态只在帧边界切换)。
// ============================================================================
module nn_scaler #(
    parameter integer SCREEN_W = 640,
    parameter integer SCREEN_H = 480
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        frame_start,     // 帧首: 采样动画状态
    input  wire [4:0]  k_in,            // 进度 0..30
    input  wire        dir_exit,        // 0=进入(格→÷1)  1=退出(÷gear→格)
    input  wire [1:0]  gear,            // 退出起始档位编码 = block_log2(0/1/2)
    input  wire [1:0]  slot,            // 焦点槽 = {cy, cx}
    // 逐像素请求(显示流, 光栅序)
    input  wire        req_v,
    input  wire [11:0] req_px,
    input  wire [11:0] req_py,
    input  wire        up_rdy,          // 上游受理门控(0 拍坐标保持)
    output wire        req_rdy,         // = up_rdy(本模块不产生额外反压)
    // 受理拍组合响应
    output wire        rsp_v,           // = 受理
    output wire        rsp_in,          // 1=rect 内(源坐标有效) 0=rect 外直通
    output wire [1:0]  rsp_slot,
    output wire [9:0]  rsp_x,
    output wire [9:0]  rsp_y,
    // 几何抽头(P2b hint 游走器用; 避免上层复制公式)
    output wire [11:0] geo_w,
    output wire [11:0] geo_h,
    output wire [11:0] geo_x,
    output wire [11:0] geo_y,
    output wire [13:0] geo_S
);
    localparam [4:0] K_LAST = 5'd30;
    localparam [23:0] ACC_BIAS = 24'd2048;              // 2^(FRAC-1), 边对齐偏置

    // ---- 帧级状态寄存 ----
    reg [4:0] k_q;
    reg       exit_q;
    reg [1:0] gear_q, slot_q;
    // 几何查表索引: 退出方向反演(k=0 满屏→k=30 格), 与进入共用同一条 w 曲线
    wire [4:0] k = exit_q ? (5'd30 - k_q) : k_q;

`include "nn_scaler_table.vh"                           // localparams + nsc_w_s(k)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            k_q <= 5'd0; exit_q <= 1'b0; gear_q <= 2'd0; slot_q <= 2'd0;
        end else if (frame_start) begin
            k_q <= k_in; exit_q <= dir_exit; gear_q <= gear; slot_q <= slot;
        end
    end

    // ---- 几何: w/S 查表 + h/x/y 派生(零乘除) ----
    wire [23:0] w_s    = nsc_w_s;                       // {w[9:0], S[13:0]}
    wire [11:0] w_q    = {2'b0, w_s[23:14]};
    wire [13:0] S_sel  = w_s[13:0];
    wire [11:0] h_w    = w_q - {2'b0, w_q[11:2]};       // h = 3w/4 = w − w/4
    wire [11:0] rect_x = slot_q[0] ? (12'd640 - w_q) : 12'd0;
    wire [11:0] rect_y = slot_q[1] ? (12'd480 - h_w) : 12'd0;

    // ---- 端点/中间模式 ----
    wire k0 = (k_q == 5'd0);
    wire kl = (k_q == K_LAST);
    wire ep_cell = exit_q ? kl : k0;                    // 图墙格采样端点
    wire ep_full = exit_q ? k0 : kl;                    // 满屏采样端点
    wire ep_acc  = !ep_cell && !ep_full;                // 中间态累加器

    // ---- 逐像素受理 ----
    wire        acc_ok  = req_v && up_rdy;
    wire [11:0] lx      = req_px - rect_x;
    wire [11:0] ly      = req_py - rect_y;
    wire        in_x    = (req_px >= rect_x) && (lx < w_q);
    wire        in_y    = (req_py >= rect_y) && (ly < h_w);
    wire        in_rect = in_x && in_y;
    wire        acc_px  = acc_ok && in_rect;

    // 端点块公式(与 view_mapper 闭式逐位一致)
    wire [11:0] blk_inv   = ~(((12'd1) << gear_q) - 12'd1);
    wire [11:0] sx_ep_cell = (lx & 12'hFFE) << 1;       // (lx>>1)<<2
    wire [11:0] sy_ep_cell = (ly & 12'hFFE) << 1;
    // 满屏端点: 进入 k30 = ÷1 直通; 退出 k0 = ÷gear 块映射(2^gear 对齐)
    wire [11:0] sx_ep_full = exit_q ? (lx & blk_inv) : lx;
    wire [11:0] sy_ep_full = exit_q ? (ly & blk_inv) : ly;

    // 累加器: acc_x 每受理像素推进(cur = lx==0 ? BIAS : acc); acc_y 存"当前行"
    //   定点 cur = BIAS + 行序·S, 帧首重载 BIAS; 以 py 变化检测换行 —— 首行仅
    //   登记 py, 换行拍输出 acc_y+S 并锁存为新当前行(协议假设 = rect 内光栅序)
    reg  [23:0] acc_x, acc_y;
    reg  [11:0] py_last;
    reg         py_v;                                // py_last 有效(帧首清)
    wire [23:0] cur_x   = (lx == 12'd0) ? ACC_BIAS : acc_x;
    wire        row_adv = py_v && (req_py != py_last);  // 真换行(非首行)
    wire        new_row = !py_v || row_adv;             // 需登记 py 的受理
    wire [23:0] cur_y   = row_adv ? (acc_y + {10'd0, S_sel}) : acc_y;
    wire [9:0]  sx_acc = cur_x[23:12];               // floor(定点)
    wire [9:0]  sy_acc = cur_y[23:12];
    wire [9:0]  sx = ep_acc ? sx_acc : (ep_cell ? sx_ep_cell[9:0] : sx_ep_full[9:0]);
    wire [9:0]  sy = ep_acc ? sy_acc : (ep_cell ? sy_ep_cell[9:0] : sy_ep_full[9:0]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_x   <= 24'd0;
            acc_y   <= ACC_BIAS;
            py_last <= 12'd0;
            py_v    <= 1'b0;
        end else begin
            if (frame_start) begin
                acc_y <= ACC_BIAS;
                py_v  <= 1'b0;
            end
            if (acc_px && !frame_start) begin
                acc_x <= cur_x + {10'd0, S_sel};
                if (new_row) begin
                    acc_y   <= cur_y;
                    py_last <= req_py;
                    py_v    <= 1'b1;
                end
            end
        end
    end

    assign req_rdy  = up_rdy;
    assign rsp_v    = acc_ok;
    assign rsp_in   = in_rect;
    assign rsp_slot = slot_q;
    assign rsp_x    = sx;
    assign rsp_y    = sy;
    assign geo_w    = w_q;
    assign geo_h    = h_w;
    assign geo_x    = rect_x;
    assign geo_y    = rect_y;
    assign geo_S    = S_sel;

endmodule
