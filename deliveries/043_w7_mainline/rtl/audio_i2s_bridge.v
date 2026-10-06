`timescale 1ns / 1ps
// ============================================================================
// audio_i2s_bridge — 并行 PCM → I2S 串行 → 官方解串 → 加密 IP (task_032 返工)
//
// 存在理由(上板实测教训, 见 doc/REWORK_AUDIO_NOTICE.md):
//   032 首版把并行 PCM(音源 mux 输出)直送加密 IP, 仿真全绿但**上板完全无声**。
//   task_018 用 8 轮上板 A/B 听感定案: 生产音频架构 = **I2S 化**
//   (源 → I2S master → 官方 I2S_receiver → 官方 ACR → IP), 该形态由 task_021
//   上板出声验证。本模块把 032 的音源mux输出改接到该已验证形态上。
//
// 结构(全部为已验证件, 本文件只做接线 + 预充门控):
//   像素域 24bit 帧 ─截位16bit→ audio_frame_fifo(021, 像素写/mclk读)
//     → i2s_master(021, mclk 域, BCLK/LRCK/DOUT)
//     → I2S_receiver(官方, 像素域解串, 出 audio_valid/left/right)
//     → audio_arc_calculate(官方, 像素域, 实测 CTS/N) → IP
//
// 节拍一致性(本模块成立的前提, 由 audio_tone_gen 的分频参数保证):
//   写侧节拍 = 25.2MHz × 25/13104 = 48076.9230769Hz
//   读侧节拍 = audio_mclk/256 = (480MHz/39)/256 = 48076.9230769Hz
//   两者**严格相等**(630×9984 == 480×13104 == 6289920), 故 FIFO 水位不漂移。
//   附带效果: 每视频帧样本数 = 48076.923/60 = 801.28(非整数) ⇒ 音频事件
//   相对视频帧**自由漂移**, 与 021/官方两套出声实现同性质(032 首版为
//   48000/60 = 800 整数, 事件相位被永久锁死, 是 task_018 R2 标记的唯一
//   幸存嫌疑)。CTS 由官方模块实测, 结果≈25160, 与 018 模式A 实测一致。
//
// 预充门控(必须, 否则声音破碎):
//   写读速率虽严格相等, 但复位后 FIFO 为空; 若立刻放行读侧, 水位只在 0/1
//   之间徘徊, i2s_master 约半数 LRCK 拍取不到帧而插入静音 ⇒ 严重破碎。
//   故: 像素域计满 PRIME_FRAMES 次写入才置 primed, 经 2FF 电平同步到 mclk
//   域放行读侧; 一旦 FIFO 排空(音源停供, 如 WAV 静音段), mclk 域 empty 经
//   2FF 同步回像素域清零计数, 恢复供数后重新预充。两处跨域均为准静态
//   **电平**同步(非脉冲), 无亚稳态展宽风险。
//
// 复位: I_rst 高有效、两域同源(顶层 = rst_pixel), 直通各子模块 —— 与 021
//   wav_player_core / 018 mode_a 同口径; audio_frame_fifo 内部各域独立
//   同步释放, i2s_master 与官方模块同风格异步断言直连。
// ============================================================================
module audio_i2s_bridge #(
    parameter integer PRIME_FRAMES = 8      // 预充帧数(FIFO 深 16, 取半)
)(
    input  wire        I_clk_pixel,   // 25.2MHz
    input  wire        I_clk_mclk,    // 12.3077MHz (= 48076.923Hz × 256)
    input  wire        I_rst,         // 高有效, 两域同源

    // ---- 像素域帧输入(音源 mux 输出; valid 为单拍脉冲) ----
    input  wire        I_frame_valid,
    input  wire [23:0] I_frame_left,
    input  wire [23:0] I_frame_right,

    // ---- 像素域输出 → 加密 IP 音频口 ----
    output wire        O_audio_valid,
    output wire [23:0] O_audio_left_data,
    output wire [23:0] O_audio_right_data,

    // ---- 像素域输出 → 加密 IP ACR 口 ----
    output wire        O_acr_valid,
    output wire [19:0] O_acr_cts,
    output wire [19:0] O_acr_n
);

    // ------------------------------------------------------------------
    // 帧 FIFO: 像素域写 / mclk 域读
    // ------------------------------------------------------------------
    wire        fifo_full;
    wire        fifo_empty;      // mclk 域
    wire        frame_rd;        // mclk 域
    wire [31:0] frame_data;      // mclk 域

    wire        wr_fire = I_frame_valid && !fifo_full;

    // 24bit → 16bit 截位(取高 16 位, 保留二补数符号); i2s_master 内部再
    //   左对齐回 24bit({s16,8'b0}), 故端到端等价于"高 16 位精度"。
    audio_frame_fifo u_frame_fifo (
        .wr_clk  (I_clk_pixel),
        .wr_rst  (I_rst),
        .wr_en   (wr_fire),
        .wr_left (I_frame_left[23:8]),
        .wr_right(I_frame_right[23:8]),
        .full    (fifo_full),
        .rd_clk  (I_clk_mclk),
        .rd_rst  (I_rst),
        .rd_en   (frame_rd),
        .rd_data (frame_data),
        .empty   (fifo_empty)
    );

    // ------------------------------------------------------------------
    // 预充门控
    // ------------------------------------------------------------------
    // mclk 域 empty → 像素域(2FF 电平同步): 排空则清零写计数以重新预充
    reg [1:0] empty_sync;
    always @(posedge I_clk_pixel or posedge I_rst) begin
        if (I_rst) empty_sync <= 2'b11;
        else       empty_sync <= {empty_sync[0], fifo_empty};
    end
    wire empty_p = empty_sync[1];

    reg [4:0] wr_cnt;
    always @(posedge I_clk_pixel or posedge I_rst) begin
        if (I_rst)
            wr_cnt <= 5'd0;
        else if (empty_p)
            wr_cnt <= 5'd0;
        else if (wr_fire && (wr_cnt != 5'd31))
            wr_cnt <= wr_cnt + 5'd1;
    end

    wire primed_req = (wr_cnt >= PRIME_FRAMES[4:0]);

    // 像素域 primed → mclk 域(2FF 电平同步): 放行 i2s_master 取帧
    reg [1:0] primed_sync;
    always @(posedge I_clk_mclk or posedge I_rst) begin
        if (I_rst) primed_sync <= 2'b00;
        else       primed_sync <= {primed_sync[0], primed_req};
    end
    wire primed_m = primed_sync[1];

    // 读侧"取不到帧"= 真空 或 尚未预充完成
    wire frame_starve = fifo_empty || !primed_m;

    // ------------------------------------------------------------------
    // I2S master(mclk 域) → 三线
    // ------------------------------------------------------------------
    wire i2s_bclk, i2s_lrck, i2s_dout;

    i2s_master u_i2s_master (
        .I_mclk       (I_clk_mclk),
        .I_rst        (I_rst),
        .I_frame_data (frame_data),
        .I_frame_empty(frame_starve),
        .O_frame_rd   (frame_rd),
        .O_i2s_BCLK   (i2s_bclk),
        .O_i2s_LRCK   (i2s_lrck),
        .O_i2s_DOUT   (i2s_dout)
    );

    // ------------------------------------------------------------------
    // 官方 I2S_receiver(像素域解串) → audio_valid / L / R
    // ------------------------------------------------------------------
    I2S_receiver u_i2s_rx (
        .I_clk              (I_clk_pixel),
        .I_rst              (I_rst),
        .I_i2s_BCLK         (i2s_bclk),
        .I_i2s_LRCK         (i2s_lrck),
        .I_i2s_DOUT         (i2s_dout),
        .O_audio_valid      (O_audio_valid),
        .O_audio_left_data  (O_audio_left_data),
        .O_audio_right_data (O_audio_right_data)
    );

    // ------------------------------------------------------------------
    // 官方 ACR(像素域, 由实测 audio_valid 节奏反推 CTS)
    // ------------------------------------------------------------------
    audio_arc_calculate #(
        .ACR_N (6144)
    ) u_acr (
        .I_clk         (I_clk_pixel),
        .I_rst         (I_rst),
        .I_audio_valid (O_audio_valid),
        .O_acr_valid   (O_acr_valid),
        .O_acr_cts     (O_acr_cts),
        .O_acr_n       (O_acr_n)
    );

endmodule
