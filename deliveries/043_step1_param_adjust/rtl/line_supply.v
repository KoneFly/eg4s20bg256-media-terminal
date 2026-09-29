`timescale 1ns / 1ps
// ============================================================================
// line_supply — 显示读口供数观测/协议平面 (task_043 P1 新写; ctrl 域)
//
// 定位: vm_q(映射结果一级) 与帧缓冲流式读口之间的**组合直通**平面 + 协议观测。
//   P1 策略 = 直通: 请求/响应/就绪逐拍原样转发(与基线逐拍一致, 含 fb 停顿语义),
//   数据通路行为零变化; 本模块增加:
//     * 1:1 在途协议追踪: 受理/返回配对, 返回时无在途 = 协议破坏计数;
//     * 帧提交点排空检查: frame_start 拍仍有在途 = 帧末排空破坏计数
//       (指导书 §2.1: 提交点 = 下一输出帧请求开始前的受控边界);
//     * 源坐标越界捕获: x≥640 / y≥480 的请求计数;
//     * 在途期间最长无响应连续拍(供数动态观测, 指导书 G2);
//     * (slot,y) 驻留映射(P2b 预取策略的基础, 本阶段只登记不服务)。
//   P2b 起的数据通路策略切换(bank 供数/预取)在本模块内演进, 接口不变。
//
// 计数器全部饱和饱和饱和(到达上限停), 供 TB/ChipWatcher 读取; 不驱动数据通路。
// ============================================================================
module line_supply #(
    parameter integer LINE_PIX = 640,
    parameter integer LINE_NUM = 480,
    parameter integer WAYS     = 3
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        frame_start,     // 帧提交点(vs_start_pulse)
    // 消费侧请求(vm_q →)
    input  wire        cq_v,
    output wire        cq_rdy,
    input  wire        cq_en,
    input  wire [1:0]  cq_slot,
    input  wire [10:0] cq_x,
    input  wire [9:0]  cq_y,
    input  wire [1:0]  cq_tag,
    // 消费侧响应(→ fetch)
    output wire        sq_v,
    output wire        sq_en,
    output wire [15:0] sq_data,
    output wire [1:0]  sq_tag,
    // 帧缓冲侧请求(→ fb 读口)
    output wire        fq_v,
    input  wire        fq_rdy,
    output wire        fq_en,
    output wire [1:0]  fq_slot,
    output wire [10:0] fq_x,
    output wire [9:0]  fq_y,
    output wire [1:0]  fq_tag,
    // 帧缓冲响应
    input  wire        fs_v,
    input  wire        fs_en,
    input  wire [15:0] fs_data,
    input  wire [1:0]  fs_tag,
    // 观测计数(饱和)
    output reg  [15:0] cnt_req,         // 受理请求累计
    output reg  [15:0] cnt_rsp,         // 返回响应累计
    output reg  [15:0] cnt_oob,         // 源坐标越界请求
    output reg  [15:0] cnt_order_err,   // 返回时无在途(1:1 协议破坏)
    output reg  [15:0] cnt_drain_err,   // 帧提交点仍有在途(排空破坏)
    output reg  [15:0] max_noresp,      // 受理后最长无响应连续拍
    output reg  [15:0] max_grant_wait,  // 请求最长等受理连续拍(供数停顿真值:
                                        //   fb ready 为数据就绪门控, 行填充停顿
                                        //   发生在受理前, 只有本计数可观测)
    // (slot,y) 驻留映射观测(P2b 用; 本阶段直通不服务)
    output wire [WAYS*13-1:0] resid     // 每 13bit = {v, slot[1:0], y[9:0]}
);
    // ---- 直通数据通路(P1 策略; 与基线逐拍一致) ----
    assign cq_rdy  = fq_rdy;
    assign fq_v    = cq_v;
    assign fq_en   = cq_en;
    assign fq_slot = cq_slot;
    assign fq_x    = cq_x;
    assign fq_y    = cq_y;
    assign fq_tag  = cq_tag;
    assign sq_v    = fs_v;
    assign sq_en   = fs_en;
    assign sq_data = fs_data;
    assign sq_tag  = fs_tag;

    // ---- 在途追踪 ----
    reg [7:0]  inflight;                // 已受理未返回(同一读口按序, 单计数即可)
    reg [15:0] noresp;                  // 受理后无响应连续拍
    reg [15:0] gwait;                   // 请求等受理连续拍

    wire acc  = cq_v && cq_rdy;         // 请求受理
    wire ret  = fs_v;                   // 响应返回(响应无反压)

    // 无响应窗口: 本拍事件结算后在途非零且本拍无返回 ⇒ 该拍计入游程
    //   (含受理拍本身: 受理后响应最早下一拍出现; 空闲拍同样计数, 否则
    //    行填充 ~540 拍停顿只在受理拍被观测到, G2 最长无响应失真)
    wire [8:0] nf        = {1'b0, inflight} + {8'b0, acc} - {8'b0, ret};
    wire       stall_cyc = !ret && (nf[7:0] != 8'd0);
    // 等受理窗口: 有请求悬空且本拍未受理(fb ready=数据就绪门控, 行填充期拒收)
    wire       wait_g    = cq_v && !cq_rdy;

    // ---- 受理拍行号锁存(响应按序返回, 与受理同序) ----
    reg [9:0] cq_y_l;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cq_y_l <= 10'd0;
        else if (acc) cq_y_l <= cq_y;
    end

    // ---- (slot,y) 驻留映射(被动登记; 一响应至多更新一项, 替换指针轮询) ----
    reg [12:0] rmap [0:WAYS-1];         // {v, slot[1:0], y[9:0]}
    reg [1:0]  rp;                      // 替换指针
    integer wi;
    wire      rmap_hit0 = rmap[0][12] && (rmap[0][11:10] == fs_tag) && (rmap[0][9:0] == cq_y_l);
    wire      rmap_hit1 = rmap[1][12] && (rmap[1][11:10] == fs_tag) && (rmap[1][9:0] == cq_y_l);
    wire      rmap_hit2 = rmap[2][12] && (rmap[2][11:10] == fs_tag) && (rmap[2][9:0] == cq_y_l);
    wire      rmap_any  = rmap_hit0 || rmap_hit1 || rmap_hit2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (wi = 0; wi < WAYS; wi = wi + 1) rmap[wi] <= 13'd0;
            rp <= 2'd0;
        end else if (ret && fs_en) begin
            if (!rmap_any) begin
                rmap[rp] <= {1'b1, fs_tag, cq_y_l};
                rp       <= rp + 2'd1;
            end
            // 命中项行号已是现值, 无需更新
        end
    end

    genvar g;
    generate
        for (g = 0; g < WAYS; g = g + 1) begin : G_R
            assign resid[g*13 +: 13] = rmap[g];
        end
    endgenerate

    // ---- 协议观测 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            inflight <= 8'd0; noresp <= 16'd0; max_noresp <= 16'd0;
            gwait <= 16'd0; max_grant_wait <= 16'd0;
            cnt_req <= 16'd0; cnt_rsp <= 16'd0; cnt_oob <= 16'd0;
            cnt_order_err <= 16'd0; cnt_drain_err <= 16'd0;
        end else begin
            // 帧提交点: 在途必须已排空(帧末排空协议)
            if (frame_start && inflight != 8'd0 && cnt_drain_err != 16'hFFFF)
                cnt_drain_err <= cnt_drain_err + 16'd1;

            if (acc) begin
                if (cnt_req != 16'hFFFF) cnt_req <= cnt_req + 16'd1;
                if (cq_x >= 11'd640 || cq_y >= 10'd480) begin
                    if (cnt_oob != 16'hFFFF) cnt_oob <= cnt_oob + 16'd1;
                end
            end

            if (ret) begin
                if (cnt_rsp != 16'hFFFF) cnt_rsp <= cnt_rsp + 16'd1;
                if (inflight == 8'd0 && cnt_order_err != 16'hFFFF)
                    cnt_order_err <= cnt_order_err + 16'd1;
            end

            // 无响应游程(窗口语义见 stall_cyc; 饱和停)
            if (stall_cyc) begin
                noresp <= (noresp == 16'hFFFF) ? 16'hFFFF : noresp + 16'd1;
                if (noresp != 16'hFFFF && noresp + 16'd1 > max_noresp)
                    max_noresp <= noresp + 16'd1;
            end else begin
                noresp <= 16'd0;
            end

            // 等受理游程(供数停顿真值; 饱和停)
            if (wait_g) begin
                gwait <= (gwait == 16'hFFFF) ? 16'hFFFF : gwait + 16'd1;
                if (gwait != 16'hFFFF && gwait + 16'd1 > max_grant_wait)
                    max_grant_wait <= gwait + 16'd1;
            end else begin
                gwait <= 16'd0;
            end

            // 在途计数(同拍一收一返不变; 协议破坏时地板饱和防下溢)
            if (acc && !ret) begin
                if (inflight != 8'hFF) inflight <= inflight + 8'd1;
            end else if (ret && !acc && inflight != 8'd0) begin
                inflight <= inflight - 8'd1;
            end
        end
    end

endmodule
