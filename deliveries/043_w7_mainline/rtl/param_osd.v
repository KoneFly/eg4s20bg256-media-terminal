`timescale 1ns / 1ps
// ============================================================================
// param_osd — 参数变化信息叠加 (task_040 自研, pixel 域 25.2MHz)
//
// 功能: 参数换装后 ≈2s(SHOW_FRAMES 帧)内在画面左上角(分辨率字幕正下方)
//   叠加黑底白字参数条 "BRI+nn CON d.d"(14 字符 x 8x8 点阵), 如
//   "BRI+96 CON 2.0"; 计时归零自动隐藏, 再次换装计时重置(不提前消失、
//   不闪烁 —— 重装优先于递减)。
//
// 复用与共存(边界场景 6):
//   * 坐标自计数(line_cnt/x_cnt)、字模 ROM(case 常量 64'h 字面量, row0 存
//     [63:56], bit7=最左像素)、黑底/白字双 mask 叠加机制 —— 均复用
//     res_caption(task_026 自研已验证)的同款机制, 已登记台账; 数字 0-9
//     字模逐字节沿用 res_caption, 字母/符号为同风格自绘;
//   * 与 res_caption 字幕条(8,8)起 16 行 x 80 列 几何错开: 本条 (8,28)起
//     16 行 x 120 列(VSTART 相对), 垂直间隔 4 行, 两 mask 永不相交
//     (TB 场景 6 逐像素断言); 顶层集成时两模块独立输出 mask/text, 优先级
//     mux 任意(不相交则无冲突)。
//
// 时序契约: I_param_upd 为 param_ctrl 换装拍单拍脉冲(与生效档位更新同拍),
//   显示内容 = 生效档位(与画面同帧一致, 不抢跑)。
// ============================================================================
module param_osd #(
    parameter integer HACTIVE     = 640,   // 有效行像素数(x_cnt 饱和界)
    parameter integer VSTART      = 35,    // 垂直消隐行数(VSA+VBP)
    parameter integer SHOW_FRAMES = 120    // 显示帧数(≈2s @60fps)
)(
    input  wire       I_clk,
    input  wire       I_rst,             // 高有效异步复位(pixel 域)
    input  wire       I_vs,              // 负极性
    input  wire       I_hs,
    input  wire       I_de,
    input  wire       I_advance,         // = de && ready(流推进拍)
    input  wire       I_param_upd,       // 参数换装拍(param_ctrl 单拍脉冲)
    input  wire [1:0] I_bri_gear,        // 生效亮度档位码
    input  wire [1:0] I_con_gear,        // 生效对比度档位码
    output wire       osd_mask,          // 黑底条区域(含字符位)
    output wire       osd_text           // 白字像素(osd_mask 内子集)
);

    // ---- 几何常量(10bit 显式定宽; 字幕条占 y=[8,23], 本条 y=[28,43]) ----
    localparam [9:0] BOX_X0 = 10'd8;                    // 黑底条左上角 x
    localparam [9:0] BOX_W  = 10'd120;                  // 14 字符 x8 + 2x4 内边距
    localparam [9:0] BOX_Y0 = VSTART[9:0] + 10'd28;     // 字幕条下方, 间隔 4 行
    localparam [9:0] BOX_H  = 10'd16;
    localparam [9:0] TXT_X0 = 10'd12;                   // 首字符列(BOX_X0+PAD)
    localparam [9:0] TXT_W  = 10'd112;                  // 14 字符 x8
    localparam [9:0] TXT_Y0 = VSTART[9:0] + 10'd32;     // 字符顶行(条内垂直居中)
    localparam [9:0] CHAR_H = 10'd8;
    localparam [9:0] X_SAT  = HACTIVE[9:0] - 10'd1;

    // ========================================================================
    // 行/列计数(机制同 res_caption: 自计数, 不依赖 video_timing_data 内部)
    // ========================================================================
    reg [9:0] line_cnt;
    reg [9:0] x_cnt;
    reg       vs_d, hs_d;

    wire vs_fall = vs_d & ~I_vs;

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            line_cnt <= 10'd0;
            x_cnt    <= 10'd0;
            vs_d     <= 1'b1;
            hs_d     <= 1'b1;
        end else begin
            vs_d <= I_vs;
            hs_d <= I_hs;
            // 帧首 VS 下降沿清零; 其后每个 HS 下降沿进入新行
            if (vs_d && !I_vs)
                line_cnt <= 10'd0;
            else if (hs_d && !I_hs)
                line_cnt <= line_cnt + 10'd1;
            // x 随流推进(背压冻结), 饱和防回绕
            if (!I_de)
                x_cnt <= 10'd0;
            else if (I_advance && (x_cnt != X_SAT))
                x_cnt <= x_cnt + 10'd1;
        end
    end

    // ========================================================================
    // 显示定时: 换装即点亮并重装计时; 每帧首递减; 重装优先(不闪烁)
    // ========================================================================
    reg       show;
    reg [7:0] fcnt;
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            show <= 1'b0;
            fcnt <= 8'd0;
        end else if (I_param_upd) begin
            show <= 1'b1;
            fcnt <= SHOW_FRAMES[7:0];
        end else if (vs_fall && show) begin
            if (fcnt <= 8'd1)
                show <= 1'b0;
            else
                fcnt <= fcnt - 8'd1;
        end
    end

    // ========================================================================
    // 字符映射: slot 0..13 -> 字符码(5bit)
    //   0..9=数字, 10=空白, 11='+', 12='.', 13='B', 14='C', 15='I',
    //   16='N', 17='O', 18='R'
    //   布局 = "BRI+nn CON d.d"
    //     亮度: 档 0..3 -> 偏移 {00,32,64,96}(十位/个位数字码)
    //     对比度: 档 0..3 -> {0.0,1.0,1.5,2.0}(整数位/小数位数字码)
    // ========================================================================
    reg [3:0] bri_tens, bri_ones;
    always @(*) begin
        case (I_bri_gear)
            2'd0:    begin bri_tens = 4'd0; bri_ones = 4'd0; end  // +00
            2'd1:    begin bri_tens = 4'd3; bri_ones = 4'd2; end  // +32
            2'd2:    begin bri_tens = 4'd6; bri_ones = 4'd4; end  // +64
            default: begin bri_tens = 4'd9; bri_ones = 4'd6; end  // +96
        endcase
    end
    reg [3:0] con_int, con_frac;
    always @(*) begin
        case (I_con_gear)
            2'd0:    begin con_int = 4'd0; con_frac = 4'd0; end   // 0.0
            2'd1:    begin con_int = 4'd1; con_frac = 4'd0; end   // 1.0
            2'd2:    begin con_int = 4'd1; con_frac = 4'd5; end   // 1.5
            default: begin con_int = 4'd2; con_frac = 4'd0; end   // 2.0
        endcase
    end

    function [4:0] osd_char;            // 槽位 -> 字符码
        input [3:0] slot;
        begin
            case (slot)
                4'd0:     osd_char = 5'd13;      // 'B'
                4'd1:     osd_char = 5'd18;      // 'R'
                4'd2:     osd_char = 5'd15;      // 'I'
                4'd3:     osd_char = 5'd11;      // '+'
                4'd4:     osd_char = {1'b0, bri_tens};
                4'd5:     osd_char = {1'b0, bri_ones};
                4'd6:     osd_char = 5'd10;      // ' '
                4'd7:     osd_char = 5'd14;      // 'C'
                4'd8:     osd_char = 5'd17;      // 'O'
                4'd9:     osd_char = 5'd16;      // 'N'
                4'd10:    osd_char = 5'd10;      // ' '
                4'd11:    osd_char = {1'b0, con_int};
                4'd12:    osd_char = 5'd12;      // '.'
                default:  osd_char = {1'b0, con_frac};
            endcase
        end
    endfunction

    // ========================================================================
    // 8x8 字模 ROM(case 常量; 每字符 8 字节, row0 存 [63:56], bit7=最左像素)
    //   数字 0-9 逐字节沿用 res_caption 字模(登记); 其余为同风格自绘。
    // ========================================================================
    function [7:0] glyph_row;
        input [4:0] code;
        input [2:0] row;
        reg  [63:0] gt;
        reg  [2:0]  rinv;
        begin
            case (code)
                5'd0:    gt = 64'h3C666E7666663C00;   // '0'
                5'd1:    gt = 64'h1838181818187E00;   // '1'
                5'd2:    gt = 64'h3C66060C18307E00;   // '2'
                5'd3:    gt = 64'h3C66061C06663C00;   // '3'
                5'd4:    gt = 64'h0C1C3C6C7E0C0C00;   // '4'
                5'd5:    gt = 64'h7E607C0606663C00;   // '5'
                5'd6:    gt = 64'h1C30607C66663C00;   // '6'
                5'd7:    gt = 64'h7E060C1818181800;   // '7'
                5'd8:    gt = 64'h3C66663C66663C00;   // '8'
                5'd9:    gt = 64'h3C66663E060C3800;   // '9'
                5'd10:   gt = 64'h0000000000000000;   // ' '
                5'd11:   gt = 64'h0018187E18180000;   // '+'
                5'd12:   gt = 64'h0000000000181800;   // '.'
                5'd13:   gt = 64'h7C66667C66667C00;   // 'B'
                5'd14:   gt = 64'h3C66606060663C00;   // 'C'
                5'd15:   gt = 64'h7E18181818187E00;   // 'I'
                5'd16:   gt = 64'h66766E6666666600;   // 'N'
                5'd17:   gt = 64'h3C66666666663C00;   // 'O'
                default: gt = 64'h7C66667C786C6600;   // 'R'
            endcase
            rinv      = 3'd7 - row;
            glyph_row = gt >> ({rinv, 3'b000});
        end
    endfunction

    // ========================================================================
    // 叠加判定(纯组合; 仅 I_de 有效区, show=0 整体关闭)
    // ========================================================================
    wire        in_box_x = (x_cnt >= BOX_X0) && (x_cnt < (BOX_X0 + BOX_W));
    wire        in_box_y = (line_cnt >= BOX_Y0) && (line_cnt < (BOX_Y0 + BOX_H));
    wire        in_txt_x = (x_cnt >= TXT_X0) && (x_cnt < (TXT_X0 + TXT_W));
    wire        in_txt_y = (line_cnt >= TXT_Y0) && (line_cnt < (TXT_Y0 + CHAR_H));
    wire [9:0]  gx       = x_cnt - TXT_X0;        // 文本区内列偏移 0..111
    wire [9:0]  gy       = line_cnt - TXT_Y0;     // 文本区内行偏移 0..7
    wire [3:0]  slot     = gx[6:3];               // /8 => 字符槽 0..13
    wire [7:0]  gbits    = glyph_row(osd_char(slot), gy[2:0]);
    wire        gpx      = gbits[3'd7 - gx[2:0]];

    assign osd_mask = I_de && show && in_box_x && in_box_y;
    assign osd_text = osd_mask && in_txt_y && in_txt_x && gpx;

endmodule
