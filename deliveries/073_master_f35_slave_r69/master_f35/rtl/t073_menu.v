`timescale 1ns / 1ps
// t073_menu：保存音乐开关、音量、转场、轮播周期、频谱、信息条和输出设置。菜单长按KEY3恢复默认；媒体页重启由顶层处理。
module t073_menu (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       active,                // 处于菜单页
    input  wire [2:0] k_short,               // {KEY4, KEY3, KEY2}
    input  wire [2:0] k_long,
    input  wire       music_toggle,          // 单拍
    output reg  [2:0] focus,
    output reg        music_on,
    output reg  [4:0] volume,
    output reg  [2:0] trans_sel,             // 0 OFF 1 FADE 2 WIPE 3 CURTAIN 4 AUTO
    output reg  [5:0] period_s,              // 0 = 关闭自动轮播
    output reg  [1:0] spec_sel,              // 0 OFF 1 PLAY 2 PLAY-RAW
    output reg        info_on,
    output reg        spk_only,
    output reg  [2:0] trans_cfg
);
    localparam [4:0] D_VOL = 5'd20;
    localparam [5:0] D_PER = 6'd3;
    wire nx   = active && k_short[0];
    wire pv   = active && k_long[0];
    wire dflt = active && k_long[1];
    wire dn   = active && k_short[1];
    wire up   = active && k_short[2];

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            focus <= 3'd0; music_on <= 1'b0; volume <= D_VOL; trans_sel <= 3'd0; period_s <= D_PER;
            spec_sel <= 2'd0; info_on <= 1'b0; spk_only <= 1'b0;
        end else if (dflt) begin
            focus <= 3'd0; music_on <= 1'b0; volume <= D_VOL; trans_sel <= 3'd0; period_s <= D_PER;
            spec_sel <= 2'd0; info_on <= 1'b0; spk_only <= 1'b0;
        end else begin
            if (music_toggle) music_on <= !music_on;
            if (nx) focus <= (focus == 3'd6) ? 3'd0 : focus + 3'd1;
            else if (pv) focus <= (focus == 3'd0) ? 3'd6 : focus - 3'd1;
            else if (up != dn) begin
                case (focus)
                3'd0: music_on <= up;
                3'd1: if (up && volume != 5'd20) volume <= volume + 5'd1;
                      else if (dn && volume != 5'd0) volume <= volume - 5'd1;
                3'd2: trans_sel <= up ? ((trans_sel == 3'd4) ? 3'd0 : trans_sel + 3'd1)
                                      : ((trans_sel == 3'd0) ? 3'd4 : trans_sel - 3'd1);
                3'd3: if (up && period_s != 6'd60) period_s <= period_s + 6'd1;
                      else if (dn && period_s != 6'd0) period_s <= period_s - 6'd1;
                3'd4: spec_sel <= up ? ((spec_sel == 2'd2) ? 2'd0 : spec_sel + 2'd1)
                                     : ((spec_sel == 2'd0) ? 2'd2 : spec_sel - 2'd1);
                3'd5: info_on <= up;
                default: spk_only <= up;
                endcase
            end
        end

    always @(*) begin
        case (trans_sel)
        3'd1: trans_cfg = 3'd1;
        3'd2: trans_cfg = 3'd3;
        3'd3: trans_cfg = 3'd4;
        3'd4: trans_cfg = 3'd7;
        default: trans_cfg = 3'd0;
        endcase
    end
endmodule
