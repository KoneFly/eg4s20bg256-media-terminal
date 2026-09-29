`timescale 1ns/1ps
// ============================================================================
// pcm16_to_pcm24 — 16bit 单声道 → 24bit 立体声符号扩展适配层 (task_032 新写)
//
// 背景:
//   task_028 的 wav_pcm_streamer 读出的是 16bit 有符号**单声道** PCM
//   (WAV 素材为 48kHz/mono/16bit)。顶层音频链下游(audio_src_mux →
//   audio_src_mux → audio_i2s_bridge → HDMI IP)统一使用
//   24bit 有符号**立体声**。本层完成位宽与声道数两处适配。
//
// 适配规则(INTERFACE_SPEC §4):
//   * 位宽: 符号扩展左移 8 位 —— {sample_in, 8'h00}。
//     16bit 有效幅度映射到 24bit 域的高 16 位, 与测试音的 24bit 幅度
//     在同一量级(-26dBFS 量级可比); 低位补 0 不引入量化噪声。
//   * 声道: 单声道复制为左右同值(left = right = ext)。
//   * valid: 直通; 节拍由上游 sample_tick 决定, 本层不整形。
//
// 纯组合、零延迟 —— 与 audio_src_mux 的组合数据通路语义一致, 便于
// 在同一拍内串联而不改变时序关系。
// ============================================================================

module pcm16_to_pcm24 (
    input  wire signed [15:0] sample_in,     // 16bit 单声道
    input  wire               sample_valid,  // 采样有效(单拍)
    output wire signed [23:0] left_out,      // 24bit 立体声左
    output wire signed [23:0] right_out,     // 24bit 立体声右
    output wire               valid_out
);
    // 符号扩展左移 8 位: 低 8 位补 0, 高 16 位 = 原 16bit 有符号样本
    wire signed [23:0] ext = {sample_in, 8'h00};

    assign left_out  = ext;
    assign right_out = ext;   // 单声道 → 左右同值
    assign valid_out = sample_valid;

endmodule
