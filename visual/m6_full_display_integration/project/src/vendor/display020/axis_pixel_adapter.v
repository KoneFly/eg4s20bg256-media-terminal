`timescale 1ns / 1ps
// ============================================================================
// axis_pixel_adapter — 视觉像素流 -> HDMI 加密 IP AXIS 视频输入适配 (Task 016)
//
// 依据 INTERFACE_SPEC.md 冻结契约(端口不得修改/新增):
//   把视觉子系统(task_015 输出: pixel_valid/pixel_rgb888, 0 拍组合)封装为
//   加密 HDMI IP 的 AXIS 视频输入(user/valid/last/data)。外部可观察行为与
//   已上板验证的 video_source_b_fixed.v(task_011) 等价, 差异仅为像素来源
//   (外部视觉像素 vs 内部彩条) —— 等价性由 TB 的 TC-10 交叉等价逐拍证明。
//
// 关键设计事实(已证实, 见 doc/spec/behavior_spec.md):
//   1. ready 语义(2026-09-13 验收方查证 APUG092 Video Interface): 行内恒高,
//      一行数据必须连续输入; 行末 last 之后才可能拉低。本模块行内直通不丢拍;
//      反压仅在行边界"不丢不重"保持(与官方源等价的保守实现)。
//   2. 相位对齐: 视觉源(task_013 eight_bar_renderer)在 de 高第 1 拍输出 x=0
//      (de_d=0 不递增), 第 2 拍起 x=1,2,...; 参考源 S_hcol 在 de 高第 1 拍组合
//      输出 0。两者同拍对齐 -> data 可组合直通, 不插寄存器。
//   3. user(SOF): VS 跳变(含复位, 复位使 frame_arm=1)后武装, 首条有效视频行
//      首像素(hcol==0 && de)被采样(advance)时拉高, 采样后撤武装; 反压时
//      user 保持到首像素被实际采样(与参考源同一方程)。
//      last(EOL): hcol==HACTIVE-1 && de 时拉高一拍。
//
// 原创性纪律(TASK_BRIEF/IP 复用评估): 理解 video_source_b_fixed 的
//   S_advance/S_hcol/S_frame_arm 语义后按本任务接口重写, 不逐行复制;
//   像素数据源从内部彩条函数改为外部 pixel_rgb888 直通。
//
// pixel_valid 有意不消费(零驱动): 冻结契约规定 axis_s_valid=I_de、列计数随
//   I_de&&axis_s_ready 推进、data 无条件组合直通 —— I_de 是唯一有效裁决;
//   task_015(纯组合)保证集成时 pixel_valid==I_de, 该端口为链路兼容保留。
//   pixel_valid=0 异常注入的可观察行为记录于 tb/handoff_packet.md (A07)。
// ============================================================================
module axis_pixel_adapter #(
    parameter integer HACTIVE = 640,
    parameter integer VACTIVE = 480
)(
    input  wire        I_clk,           // 25.2MHz 像素时钟
    input  wire        I_rst,           // 高有效复位(与 video_timing_data /
                                        // video_source_b_fixed 一致的异步高有效风格)
    input  wire        I_vs,            // 帧同步(低有效, 来自 video_timing_data O_vs)
    input  wire        I_de,            // 数据使能(高=有效视频区)
    input  wire        pixel_valid,     // 视觉像素有效(0 拍组合, 本模块不消费, 见文件头)
    input  wire [23:0] pixel_rgb888,    // 视觉像素 RGB888(0 拍组合, 来自 task_015)
    input  wire        axis_s_ready,    // 下游(加密 IP)反压
    output wire        axis_s_user,     // 帧首像素 SOF, 每帧一次单拍
    output wire        axis_s_valid,    // 像素有效(= I_de)
    output wire        axis_s_last,     // 行末像素 EOL, 每行一次单拍
    output wire [23:0] axis_s_data      // {R,G,B}, 行内组合直通视觉像素
);

    // 列计数位宽: 容纳 HACTIVE-1 (与参考源同规则; 640 -> 10 位)
    localparam integer HCOL_W = (HACTIVE <= 512) ? 9 :
                                (HACTIVE <= 1024) ? 10 : 11;

    reg        S_vs_1d;        // vs 延迟一拍, 检测跳变
    reg        S_frame_arm;    // 帧向量: 允许帧首像素发射 SOF
    reg [HCOL_W-1:0] S_hcol;   // 有效区像素列计数(0..HACTIVE-1)

    // 有效像素被下游采样的握手: de 高 && ready 高
    wire S_advance = I_de && axis_s_ready;

    // ---- vs 打拍与 SOF 向量: 任一次 VS 跳变(含复位)武装帧首 SOF ----
    // 复位: frame_arm=1 保证复位后首帧 user 正常(契约复位语义)。
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            S_vs_1d     <= 1'b0;
            S_frame_arm <= 1'b1;
        end else begin
            S_vs_1d <= I_vs;
            if (S_vs_1d != I_vs)
                S_frame_arm <= 1'b1;                       // 跳变 -> 武装
            else if (S_advance && S_frame_arm &&
                     (S_hcol == {HCOL_W{1'b0}}))
                S_frame_arm <= 1'b0;                       // 首像素被采样 -> 撤武装
        end
    end

    // ---- 有效区列计数: 消隐(de 低)清零, 有效区随握手推进, 反压保持 ----
    // 反压(S_advance=0)时保持当前值 -> 不丢不重; 行末回绕到 0。
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst)
            S_hcol <= {HCOL_W{1'b0}};
        else if (!I_de)
            S_hcol <= {HCOL_W{1'b0}};
        else if (S_advance) begin
            if (S_hcol == HACTIVE - 1)
                S_hcol <= {HCOL_W{1'b0}};
            else
                S_hcol <= S_hcol + {{(HCOL_W-1){1'b0}}, 1'b1};
        end
    end

    // ---- AXIS 输出(组合于当前状态; 反压时状态不变 -> 输出保持稳定) ----
    assign axis_s_valid = I_de;                                   // 仅有效视频区
    assign axis_s_user  = I_de && S_frame_arm &&
                          (S_hcol == {HCOL_W{1'b0}});             // 行首 SOF
    assign axis_s_last  = I_de && (S_hcol == HACTIVE - 1);        // 行末 EOL
    assign axis_s_data  = pixel_rgb888;                           // 0 拍组合直通

    // pixel_valid 有意不消费(见文件头); 显式 tie-off 防止悬空告警。
    wire _unused_pixel_valid = &{1'b0, pixel_valid};

endmodule
