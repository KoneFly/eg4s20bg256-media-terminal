`timescale 1ns/1ps
// ============================================================================
// spectrum_row_fill — 单路 128 桶频谱的平滑 + 填充式渲染(像素域)
//
// 绘图区 x = 64..575(每桶 4 像素), 64 行(TOP_LINE..TOP_LINE+63), 底部为 0 高度。
// 平滑: 每桶一个 6.3 定点状态 s(本地 RAM)。每帧在首行(更新行)按原始桶值 r 更新一次:
//   目标 t = (r[i-1] + 2·r[i] + r[i+1]) / 4   (频段间 3 点平滑, 削掉孤立单桶尖刺)
//   t > s: s += (t - s)/4   (上升约 4 帧跟上)
//   t ≤ s: s -= (s - t)/8   (回落约 8 帧, 慢放更柔和)
//   原始数据有效即更新(不论是否显示), 打开显示时状态已收敛。
// 显示只用平滑后的整数高度 h = s[8:3]; 首行显示更新前的值, 其余行显示更新后的值。
// 两种样式(BARS):
//   1 音柱: 每桶左 3 像素为柱、右 1 像素留缝, 柱内 bottom_distance <= h 即填充。
//   0 波形: 相邻两桶之间按桶内相位线性插值 h + (h_next - h)·phase/4, 插值线以下填充。
// 输出 fill_mask 与 level(像素离底高度 0..63, 供上层按高度做渐变配色)。
// 原始数据取数: 读地址提前一桶(lookahead), 同步应答落到 next_*, 在桶边界提升到 current_*;
//   应答须与当前显示 bank 与索引一致。平滑 RAM 读地址与之同序但不经应答握手(读延迟 1)。
// ============================================================================
module spectrum_row_fill #(
    parameter integer TOP_LINE = 387,
    parameter         BARS     = 1
)(
    input wire pixel_clk,
    input wire pixel_rst,
    input wire de,
    input wire frame_boundary,
    input wire [9:0] pixel_x,
    input wire [9:0] absolute_line,
    input wire display_valid,                // 原始数据可取(取数与平滑更新)
    input wire show,                         // 绘制
    input wire display_bank,
    input wire [5:0] mirror_height_q,
    input wire mirror_bank_q,
    input wire mirror_valid_q,
    input wire [6:0] mirror_index_q,
    output wire [6:0] mirror_read_index,
    output wire fill_mask,
    output wire [5:0] level
);
    localparam integer END_LINE = TOP_LINE + 64;
    localparam integer BOTTOM_LINE = TOP_LINE + 63;
    localparam [9:0] TOP10 = TOP_LINE[9:0], END10 = END_LINE[9:0];
    localparam [5:0] BOTTOM6 = BOTTOM_LINE[5:0];
    wire line_in = absolute_line >= TOP10 && absolute_line < END10;
    wire upd_line = absolute_line == TOP10;
    wire x_in    = pixel_x >= 10'd64 && pixel_x < 10'd576;
    wire [8:0] x_offset = pixel_x[8:0] - 9'd64;
    wire [6:0] column_index = x_offset[8:2];
    wire [1:0] column_phase = x_offset[1:0];
    wire [5:0] bottom_distance = BOTTOM6 - absolute_line[5:0];
    wire [6:0] lookahead_index = column_index == 7'd127 ? 7'd127 : column_index + 7'd1;
    assign mirror_read_index = !pixel_rst && display_valid && line_in && x_in ? lookahead_index : 7'd0;
    assign level = bottom_distance;

    // ---- 原始桶值(只用于更新行) ----
    reg [5:0] current_height, next_height, prev_height;
    reg       current_valid, next_valid;

    // ---- 平滑状态 RAM ----
    (* ram_style="bram" *) reg [8:0] sm [0:127];
    // 器件不保证 RAM 上电内容。复位释放后逐桶写零，完成前禁止绘制与更新。
    reg [6:0] init_addr;
    reg init_ready;
    always @(posedge pixel_clk or posedge pixel_rst) begin
        if (pixel_rst) begin init_addr <= 7'd0; init_ready <= 1'b0; end
        else if (!init_ready) begin
            if (init_addr == 7'd127) init_ready <= 1'b1;
            else init_addr <= init_addr + 7'd1;
        end
    end
    reg  [8:0] s_rd;                         // 读延迟 1, 与表应答同拍
    reg  [8:0] s_cur;                        // 当前桶平滑值
    reg        s_we;
    reg  [6:0] s_wa;
    reg  [8:0] s_wd;
    wire [6:0] s_ra = x_in ? lookahead_index : 7'd0;
    always @(posedge pixel_clk) begin
        s_rd <= sm[s_ra];
        if (!pixel_rst && !init_ready) sm[init_addr] <= 9'd0;
        else if (!pixel_rst && s_we && init_ready) sm[s_wa] <= s_wd;
    end

    // 更新: 目标(6.2 定点, 左移一位成 6.3)与新状态
    wire [5:0] r_next = next_valid ? next_height : current_height;
    wire [7:0] t4 = {2'd0, prev_height} + {1'b0, current_height, 1'b0} + {2'd0, r_next};
    wire [8:0] t9 = {t4, 1'b0};
    wire [9:0] dv = {1'b0, t9} - {1'b0, s_cur};
    wire [8:0] up_step = dv[9:2];                            // dv > 0 时 (t - s)/4
    wire [9:0] dn_mag  = {1'b0, s_cur} - {1'b0, t9};
    wire [8:0] s_new   = dv[9] ? s_cur - dn_mag[9:3] : s_cur + up_step;

    // ---- 显示 ----
    wire [5:0] h_cur  = s_cur[8:3];
    wire [5:0] h_next = s_rd[8:3];                           // 相位 1..3 时为下一桶
    wire [6:0] dh  = {1'b0, h_next} - {1'b0, h_cur};
    wire [8:0] dhp = $signed({{2{dh[6]}}, dh}) * $signed({1'b0, column_phase});
    wire [6:0] hi  = {1'b0, h_cur} + {{2{dhp[8]}}, dhp[6:2]};
    wire       under = BARS ? (column_phase != 2'd3 && bottom_distance <= h_cur && h_cur != 6'd0)
                            : ({1'b0, bottom_distance} <= hi && hi != 7'd0);
    assign fill_mask = !pixel_rst && init_ready && de && show && line_in && x_in && under;

    always @(posedge pixel_clk or posedge pixel_rst) begin
        if (pixel_rst) begin
            current_height <= 6'd0; next_height <= 6'd0; prev_height <= 6'd0;
            current_valid <= 1'b0; next_valid <= 1'b0;
            s_cur <= 9'd0; s_we <= 1'b0; s_wa <= 7'd0; s_wd <= 9'd0;
        end else begin
            s_we <= 1'b0;
            if (de) begin
                // 平滑值: 绘图区前一拍取第 0 桶, 每桶最后一拍提升到下一桶
                if (pixel_x == 10'd63) s_cur <= s_rd;
                else if (x_in && column_phase == 2'd3 && column_index < 7'd127) s_cur <= s_rd;
                // 更新行: 每桶最后一拍写回该桶
                if (init_ready && upd_line && x_in && column_phase == 2'd3 && current_valid) begin
                    s_we <= 1'b1; s_wa <= column_index; s_wd <= s_new;
                end
            end
            if (frame_boundary || !display_valid) begin
                current_valid <= 1'b0; next_valid <= 1'b0;
            end else begin
                if (mirror_valid_q && mirror_bank_q == display_bank && mirror_index_q == mirror_read_index) begin
                    next_height <= mirror_height_q; next_valid <= 1'b1;
                end
                if (de) begin
                    if (pixel_x == 10'd0 || !line_in) begin
                        current_valid <= 1'b0; next_valid <= 1'b0;
                    end else if (pixel_x == 10'd63) begin
                        if (mirror_valid_q && mirror_bank_q == display_bank && mirror_index_q == 7'd0) begin
                            current_height <= mirror_height_q; prev_height <= mirror_height_q; current_valid <= 1'b1;
                        end else current_valid <= 1'b0;
                        next_valid <= 1'b0;
                    end else if (!x_in) begin
                        next_valid <= 1'b0;
                        if (pixel_x >= 10'd576) current_valid <= 1'b0;
                    end else if (column_phase == 2'd3 && column_index < 7'd127) begin
                        prev_height <= current_height;
                        if (next_valid) begin current_height <= next_height; current_valid <= 1'b1; end
                        else current_valid <= 1'b0;
                        next_valid <= 1'b0;
                    end
                end
            end
        end
    end
endmodule
