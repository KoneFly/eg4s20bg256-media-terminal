`timescale 1ns / 1ps
// ============================================================================
// audio_tone_gen — 1kHz 正弦测试音生成器 (24-bit 立体声 PCM + valid)
//
// 功能: 以像素时钟为时基, 精确产生 48kHz 采样节拍, ROM 查表输出
//   1kHz 正弦波的 24-bit 左/右声道 PCM 采样对, 每采样一拍的 valid 脉冲。
//
// 采样节拍推导([task_032 返工] 由整数分频改为分数分频):
//   节拍必须与 I2S 投递侧的 LRCK **严格同频**, 否则 audio_i2s_bridge 的帧
//   FIFO 会持续漂移并周期性欠载(插静音)。故取:
//     rate = 25.2MHz × TICK_INC/TICK_MOD = 25.2e6 × 25/13104 = 48076.9230769Hz
//     LRCK = audio_mclk/256 = (480MHz/39)/256      = 48076.9230769Hz
//   两者精确相等(630×9984 == 480×13104 == 6289920), 零漂移。
//   附带收益: 每视频帧样本数 = 48076.923/60 = 801.28(非整数), 音频事件相对
//   视频帧自由漂移 —— 与 021/官方两套上板出声实现同性质。首版用 525 整数
//   分频得 48000Hz, 每帧恰 800 样本, 事件相位被永久锁死(task_018 R2 唯一
//   幸存嫌疑), 已随返工废弃。
//
// 波形频率推导:
//   48 点查表一周期, 每采样点地址 +1 -> 波形频率 = 48076.923/48 = 1001.6Hz。
//   幅度 2,000,000 (24-bit 有符号, 约 -26dBFS), 左右声道同相。
//
// 接口说明:
//   valid=1 单拍即为一对采样; left/right 与 valid 同拍有效。
//   后续 Task 013(WAV 解析器)接入时, 本模块内部替换为 WAV 流读取,
//   接口签名(I_audio_valid/left/right)保持不变。
//
// [task_032 音频集成] 新增 O_tone_tick 输出:
//   本模块的采样节拍是整机唯一的音频时基, 与 I2S 投递侧 LRCK 严格同频(见上)。
//   集成时 wav_pcm_streamer 的读侧 sample_tick 必须使用同一节拍, 否则音频节拍
//   与投递速率失去固定关系, 会漂移导致欠载插静音/音画不同步。
//   O_tone_tick 与 O_audio_valid 严格同拍同宽(均为单拍脉冲), 波形逻辑
//   与查表数据逐行未改 —— 仅新增一路输出镜像。
// ============================================================================
module audio_tone_gen (
    input  wire        I_clk,          // pixel clock
    input  wire        I_rst,          // 高有效, 同步复位
    output reg         O_audio_valid,  // 采样对有效, 单拍脉冲
    output reg  [23:0] O_audio_left_data,
    output reg  [23:0] O_audio_right_data,
    output reg         O_tone_tick     // 音频采样节拍(与 valid 同拍, task_032 集成用)
);

    // 分数分频参数: rate = 25.2MHz × 25/13104 = 48076.9230769Hz = audio_mclk/256
    localparam integer TICK_INC = 25;
    localparam integer TICK_MOD = 13104;

    reg [13:0] S_smp_acc;       // 相位累加器 (0..TICK_MOD-1)
    reg [5:0]  S_phase;         // 波形相位 (0..47)

    // 48 点 1kHz 正弦表, 幅度 2,000,000 (24-bit 有符号)
    function signed [23:0] f_sin_tbl;
        input [5:0] idx;
        begin
            case (idx)
                6'd0:  f_sin_tbl = 24'sd0;
                6'd1:  f_sin_tbl = 24'sd261052;
                6'd2:  f_sin_tbl = 24'sd517638;
                6'd3:  f_sin_tbl = 24'sd765367;
                6'd4:  f_sin_tbl = 24'sd1000000;
                6'd5:  f_sin_tbl = 24'sd1217523;
                6'd6:  f_sin_tbl = 24'sd1414214;
                6'd7:  f_sin_tbl = 24'sd1586707;
                6'd8:  f_sin_tbl = 24'sd1732051;
                6'd9:  f_sin_tbl = 24'sd1847759;
                6'd10: f_sin_tbl = 24'sd1931852;
                6'd11: f_sin_tbl = 24'sd1982890;
                6'd12: f_sin_tbl = 24'sd2000000;
                6'd13: f_sin_tbl = 24'sd1982890;
                6'd14: f_sin_tbl = 24'sd1931852;
                6'd15: f_sin_tbl = 24'sd1847759;
                6'd16: f_sin_tbl = 24'sd1732051;
                6'd17: f_sin_tbl = 24'sd1586707;
                6'd18: f_sin_tbl = 24'sd1414214;
                6'd19: f_sin_tbl = 24'sd1217523;
                6'd20: f_sin_tbl = 24'sd1000000;
                6'd21: f_sin_tbl = 24'sd765367;
                6'd22: f_sin_tbl = 24'sd517638;
                6'd23: f_sin_tbl = 24'sd261052;
                6'd24: f_sin_tbl = 24'sd0;
                6'd25: f_sin_tbl = -24'sd261052;
                6'd26: f_sin_tbl = -24'sd517638;
                6'd27: f_sin_tbl = -24'sd765367;
                6'd28: f_sin_tbl = -24'sd1000000;
                6'd29: f_sin_tbl = -24'sd1217523;
                6'd30: f_sin_tbl = -24'sd1414214;
                6'd31: f_sin_tbl = -24'sd1586707;
                6'd32: f_sin_tbl = -24'sd1732051;
                6'd33: f_sin_tbl = -24'sd1847759;
                6'd34: f_sin_tbl = -24'sd1931852;
                6'd35: f_sin_tbl = -24'sd1982890;
                6'd36: f_sin_tbl = -24'sd2000000;
                6'd37: f_sin_tbl = -24'sd1982890;
                6'd38: f_sin_tbl = -24'sd1931852;
                6'd39: f_sin_tbl = -24'sd1847759;
                6'd40: f_sin_tbl = -24'sd1732051;
                6'd41: f_sin_tbl = -24'sd1586707;
                6'd42: f_sin_tbl = -24'sd1414214;
                6'd43: f_sin_tbl = -24'sd1217523;
                6'd44: f_sin_tbl = -24'sd1000000;
                6'd45: f_sin_tbl = -24'sd765367;
                6'd46: f_sin_tbl = -24'sd517638;
                6'd47: f_sin_tbl = -24'sd261052;
                default: f_sin_tbl = 24'sd0;
            endcase
        end
    endfunction

    wire signed [23:0] W_sample = f_sin_tbl(S_phase);

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            S_smp_acc          <= 14'd0;
            S_phase            <= 6'd0;
            O_audio_valid      <= 1'b0;
            O_audio_left_data  <= 24'd0;
            O_audio_right_data <= 24'd0;
            O_tone_tick        <= 1'b0;
        end else begin
            O_audio_valid <= 1'b0;
            O_tone_tick   <= 1'b0;
            if (S_smp_acc + TICK_INC >= TICK_MOD) begin
                // 采样节拍: 输出一对待采样 PCM; 累加器回绕**保留余数**
                // (分数分频要点: 清零会丢失小数部分, 平均速率即偏离目标)
                S_smp_acc          <= S_smp_acc + TICK_INC - TICK_MOD;
                O_audio_valid      <= 1'b1;
                O_tone_tick        <= 1'b1;   // 与 valid 同拍(音频时基引出)
                O_audio_left_data  <= W_sample;
                O_audio_right_data <= W_sample;
                if (S_phase == 6'd47)
                    S_phase <= 6'd0;
                else
                    S_phase <= S_phase + 6'd1;
            end else begin
                S_smp_acc <= S_smp_acc + TICK_INC;
            end
        end
    end

endmodule