`timescale 1ns / 1ps
// audio_tone_gen：查表生成左右同相测试音。采样节拍为25.2MHz×25/13104，约48076.923Hz；48个采样点构成一个周期，音调约1001.6Hz。
module audio_tone_gen (
    input  wire        I_clk,          // pixel clock
    input  wire        I_rst,          // 高有效, 同步复位
    output reg         O_audio_valid,  // 采样对有效, 单拍脉冲
    output reg  [23:0] O_audio_left_data,
    output reg  [23:0] O_audio_right_data,
    output reg         O_tone_tick     // 音频采样节拍(与 valid 同拍,  集成用)
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