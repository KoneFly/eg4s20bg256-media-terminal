`timescale 1ns / 1ps
// ============================================================================
// trans_progress — 转场进度机(帧级, vsync 对齐; 与 transition_engine 配套)
//
// 职责(单一): 把"转场请求"变成帧边界对齐的 {trans_mode, trans_t} 准静态输出。
//   * 转场时长 = TRANS_FRAMES 帧(推荐 15~30, 0.25~0.5s @60fps), 每个
//     vsync_pulse 推进一次; t 步进 T_STEP = ceil(255/TRANS_FRAMES), 恰在
//     TRANS_FRAMES 个 vsync 后精确到达 255(端点精确, 无 1 LSB 偏差);
//   * 输出仅在 vsync_pulse 拍变化 ⇒ 帧内恒定(防撕裂);
//   * 空闲态输出 mode=0/t=0 ⇒ 引擎 A 路直通(即"直接切换" resting 态);
//   * 完成(DONE)后保持 mode/t=255 直至下一请求 ⇒ 屏幕稳定停在纯 B; 上层借
//     done_pulse 把已完成槽提升为 A 路源(无缝交接, 见 SPEC 接口契约)。
//
// 状态机: IDLE --启动(目标就绪且 mode≠0)--> RUN --t 到 255--> DONE --下一请求--> ..
//   * RUN 中再次触发(重定向, 边界情况 1): t 不回退、mode 不变(视觉连续优先,
//     硬约束 5), 上层在同一 vsync 把 B 路源换到新目标槽, 混合从当前 t 继续推向
//     新目标 —— 立即重定向、无反向跳变、无卡死(完成时刻不因重定向延后);
//   * 请求时目标槽未就绪(启动或重定向, 边界情况 5) ⇒ direct_pulse 降级为
//     直接切换并回到 IDLE(mode=0/t=0), 未就绪槽的数据永不进入混合通路;
//   * 请求 mode=0(要求直接切换) 同样走降级路径。
//
// 上游接口契约: req_start 与两路源槽的切换在同一 vsync 拍提交(上层自知请求
// 时刻, 无需等 direct_pulse); req_start 帧内保持即可(vsync 拍采样)。
// ============================================================================
module trans_progress #(
    parameter integer TRANS_FRAMES = 16   // 一次转场的帧数(推荐 15~30; ≥1)
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync_pulse,    // ctrl 域帧消隐单拍脉冲(顶层 vs_start_pulse)
    input  wire        req_start,      // 转场/重定向请求(vsync 拍采样)
    input  wire [2:0]  req_mode,       // 请求的转场类型(同 transition_engine 编码)
    input  wire        dst_ready,      // 目标槽就绪(准静态)
    output reg         trans_active,   // 1 = 转场进行中(RUN 态)
    output reg  [2:0]  trans_mode,
    output reg  [7:0]  trans_t,        // 0~255, 仅 vsync 拍变化
    output reg         done_pulse,     // t 恰到 255 的 vsync 拍单脉冲
    output reg         direct_pulse    // 请求被降级为直接切换的 vsync 拍单脉冲
);

    localparam [1:0] S_IDLE = 2'd0, S_RUN = 2'd1, S_DONE = 2'd2;
    localparam integer T_STEP = (255 + TRANS_FRAMES - 1) / TRANS_FRAMES;  // ceil

    reg [1:0] state;

    wire [8:0] t_step9 = {1'b0, trans_t} + T_STEP[8:0];   // ≤ 254+255 = 509
    wire [7:0] t_next  = (t_step9 >= 9'd255) ? 8'd255 : t_step9[7:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            trans_active <= 1'b0;
            trans_mode   <= 3'd0;
            trans_t      <= 8'd0;
            done_pulse   <= 1'b0;
            direct_pulse <= 1'b0;
        end else begin
            done_pulse   <= 1'b0;
            direct_pulse <= 1'b0;
            if (vsync_pulse) begin
                case (state)
                    S_IDLE, S_DONE: begin
                        if (req_start) begin
                            if (dst_ready && (req_mode != 3'd0)) begin
                                state        <= S_RUN;
                                trans_active <= 1'b1;
                                trans_mode   <= req_mode;
                                trans_t      <= 8'd0;
                            end else begin
                                // 降级: 目标未就绪或要求直接切换 ⇒ 不转场
                                state        <= S_IDLE;
                                trans_active <= 1'b0;
                                trans_mode   <= 3'd0;
                                trans_t      <= 8'd0;
                                direct_pulse <= 1'b1;
                            end
                        end
                    end
                    S_RUN: begin
                        if (req_start && !(dst_ready && (req_mode != 3'd0))) begin
                            // 重定向但新目标未就绪/要求直接切换: 中止并降级
                            state        <= S_IDLE;
                            trans_active <= 1'b0;
                            trans_mode   <= 3'd0;
                            trans_t      <= 8'd0;
                            direct_pulse <= 1'b1;
                        end else begin
                            trans_t <= t_next;
                            if (t_next == 8'd255) begin
                                state        <= S_DONE;
                                trans_active <= 1'b0;
                                done_pulse   <= 1'b1;
                            end
                            // 重定向(req_start 且新目标就绪): t 不回退、mode 不变
                            // —— "立即重定向", 目标切换由上层在本 vsync 执行
                        end
                    end
                    default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule
