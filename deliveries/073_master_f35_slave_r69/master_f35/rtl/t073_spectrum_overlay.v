`timescale 1ns/1ps
// ============================================================================
// t073_spectrum_overlay — 频谱叠加(像素域): 回放渐变音柱 + 麦克风现场声填充渐变波形
//
// 模式在帧边界原子切换: PLAY(single_requested) 只画回放(path0)音柱;
//   PLAY-RAW(dual_requested) 再叠加副板 RAW(path1)的填充波形, 两者同轴同区域。
// 两路都在行渲染器里做时间/频段平滑(spectrum_row_fill), 原始数据有效就持续更新。
// 配色(纵向随离底高度 + 横向随频段):
//   g = (31 - 频段/16) + (31 - 高度/2), 低频底部最亮, 高频顶部最深
//   音柱 = {R 满, G = g, B = 频段/32}:  黄(低频底) -> 橙 -> 红/品红(高频顶)
//   波形 = {R = 频段/32, G = g, B 满}:  青(低频底) -> 蓝 -> 蓝紫(高频顶)
// 叠放: 波形与图像 1:1 半透明; 音柱压在波形上时与下方再 1:1 混合(透出波形轮廓),
//   只压在图像上时不透明。
// 频率轴沿用 spectrum_frequency_axis(底部一行), 有任一路显示时出现。
// 读口: read_address = {path, 桶号}, A 口给音柱、B 口给波形, 应答带地址/bank 回送校验。
// ============================================================================
module t073_spectrum_overlay(
    input wire pixel_clk,pixel_rst,frame_boundary,de,
    input wire [9:0] pixel_x,absolute_line,
    input wire dual_requested,single_requested,display_valid,display_bank,
    input wire [1:0] display_paths,
    output wire [8:0] read_address,
    input wire [7:0] read_data_q,
    input wire [8:0] read_address_q,
    input wire read_bank_q,read_valid_q,
    output wire [8:0] read_address_b,
    input wire [7:0] read_data_b_q,
    input wire [8:0] read_address_b_q,
    input wire read_bank_b_q,read_valid_b_q,
    input wire [15:0] image_rgb565,
    output wire [15:0] rgb565
);
    reg dual_frame, single_frame;
    wire dual_synced, single_synced;
    pixel_switch_sync u_dual_sync(.clk(pixel_clk),.rst(pixel_rst),.async_input(dual_requested),.sync_output(dual_synced));
    pixel_switch_sync u_single_sync(.clk(pixel_clk),.rst(pixel_rst),.async_input(single_requested),.sync_output(single_synced));
    always @(posedge pixel_clk or posedge pixel_rst)
        if (pixel_rst) begin dual_frame <= 1'b0; single_frame <= 1'b0; end
        else if (frame_boundary) begin dual_frame <= dual_synced; single_frame <= single_synced; end
    // display_paths 为快照表发布的路数 1/2/3
    wire bars_src = display_valid && (display_paths >= 2'd1);
    wire wave_src = display_valid && (display_paths >= 2'd2);
    wire bars_on  = (dual_frame || single_frame) && bars_src;
    wire wave_on  = dual_frame && wave_src;

    wire [6:0] bar_index, wave_index;
    wire       bar_mask, wave_mask;
    wire [5:0] bar_level, wave_level;
    assign read_address   = {2'd0, bar_index};
    assign read_address_b = {2'd1, wave_index};
    spectrum_row_fill #(.TOP_LINE(387), .BARS(1)) u_bars(
        .pixel_clk(pixel_clk), .pixel_rst(pixel_rst), .de(de), .frame_boundary(frame_boundary),
        .pixel_x(pixel_x), .absolute_line(absolute_line), .display_valid(bars_src), .show(bars_on),
        .display_bank(display_bank),
        .mirror_height_q(read_data_q[7:2]), .mirror_bank_q(read_bank_q),
        .mirror_valid_q(read_valid_q && read_address_q[8:7] == 2'd0), .mirror_index_q(read_address_q[6:0]),
        .mirror_read_index(bar_index), .fill_mask(bar_mask), .level(bar_level));
    spectrum_row_fill #(.TOP_LINE(387), .BARS(0)) u_wave(
        .pixel_clk(pixel_clk), .pixel_rst(pixel_rst), .de(de), .frame_boundary(frame_boundary),
        .pixel_x(pixel_x), .absolute_line(absolute_line), .display_valid(wave_src), .show(wave_on),
        .display_bank(display_bank),
        .mirror_height_q(read_data_b_q[7:2]), .mirror_bank_q(read_bank_b_q),
        .mirror_valid_q(read_valid_b_q && read_address_b_q[8:7] == 2'd1), .mirror_index_q(read_address_b_q[6:0]),
        .mirror_read_index(wave_index), .fill_mask(wave_mask), .level(wave_level));

    // 渐变: 两路离底高度相同(同一绘图区), 共用一个绿分量
    wire [8:0] xo = pixel_x[8:0] - 9'd64;                   // 0..511, 频段 = xo/4
    wire [4:0] fb = xo[8:4];                                 // 频段/4 的高 5 位: 0..31
    wire [5:0] g6 = {1'b0, ~fb} + {1'b0, ~bar_level[5:1]};
    wire [15:0] bar_rgb  = {5'h1F, g6, 1'b0, fb[4:1]};
    wire [15:0] wave_rgb = {1'b0, fb[4:1], g6, 5'h1F};
    // 1:1 混合(各通道取高位相加, 不进位)
    function [15:0] avg565(input [15:0] a, input [15:0] b);
        avg565 = {1'b0, a[15:12], 1'b0, a[10:6], 1'b0, a[4:1]} + {1'b0, b[15:12], 1'b0, b[10:6], 1'b0, b[4:1]};
    endfunction
    wire [15:0] wave_mix = avg565(image_rgb565, wave_rgb);
    wire [15:0] bar_mix  = avg565(bar_rgb, wave_mix);
    wire axis_mask, axis_text;
    spectrum_frequency_axis u_frequency_axis(.de(de && !pixel_rst),
        .top_display_valid(1'b0), .bottom_display_valid(bars_on),
        .pair_post_active(1'b0), .single_active(!wave_on), .pixel_x(pixel_x), .absolute_line(absolute_line),
        .axis_mask(axis_mask), .axis_text(axis_text));
    assign rgb565 = bar_mask  ? (wave_mask ? bar_mix : bar_rgb) :
                    wave_mask ? wave_mix :
                    axis_mask ? (axis_text ? 16'hFFFF : 16'h0000) : image_rgb565;
endmodule
