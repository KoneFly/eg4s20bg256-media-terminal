`timescale 1ns/1ps

// 音频源二选一：WAV 流 / 琶音合成音。wav_active 电平切换，WAV 优先。
// 数据通路纯组合（零延迟）；ready 只路由给被选中的源——未选源收不到
// ready，其内部握手不推进，切换音源时两边都不丢数据。
//
// [task_032 集成] 位宽 16→24：
//   顶层音频链下游(audio_src_mux → audio_i2s_bridge → HDMI IP)全程为 24bit
//   有符号立体声。WAV 路径经 pcm16_to_pcm24 完成 16→24 符号扩展后进入本
//   mux；测试音(audio_tone_gen)原生即为 24bit。故本 mux 统一为 24bit 数据
//   通路，语义(选择规则/ready 路由/零延迟组合)与 16bit 版逐条一致。
//   位宽加宽不改变任何选择逻辑，仅扩展数据字段。
module audio_src_mux (
    input  wire               clk,
    input  wire               rst_n,

    // 源 A：WAV 流
    input  wire               wav_valid,
    output wire               wav_ready,
    input  wire signed [23:0] wav_left,
    input  wire signed [23:0] wav_right,
    input  wire               wav_active,     // WAV 流播放中（电平）

    // 源 B：琶音/测试音合成
    input  wire               arp_valid,
    output wire               arp_ready,
    input  wire signed [23:0] arp_left,
    input  wire signed [23:0] arp_right,

    // 输出
    output wire               out_valid,
    input  wire               out_ready,
    output wire signed [23:0] out_left,
    output wire signed [23:0] out_right
);
    wire use_wav = wav_active;

    assign out_valid = use_wav ? wav_valid : arp_valid;
    assign out_left  = use_wav ? wav_left  : arp_left;
    assign out_right = use_wav ? wav_right : arp_right;

    assign wav_ready = use_wav ? out_ready : 1'b0;
    assign arp_ready = use_wav ? 1'b0      : out_ready;
endmodule
