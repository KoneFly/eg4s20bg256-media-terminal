`timescale 1ns / 1ps
// ============================================================================
// res_caption — 分辨率字幕叠加 ([task_026 第三步] 自研, pixel 域 25.2MHz)
//
// 功能: 在显示画面左上角叠加 "宽x高" 源分辨率字幕(如 "3840x2160"):
//   * 黑底条: 起点 (8,8), 高 16 行, 宽 80 列(9 字符×8px + 左右 4px 内边距),
//     cap_mask=1 区域由顶层以纯黑覆盖;
//   * 白字: 8x8 点阵字模(数字 0-9 + 'x'), 垂直居中于黑底条(y=12..19),
//     cap_text=1 像素由顶层以纯白覆盖; 前导零抑制、左对齐;
//   * 叠加位置: m1a_top 内 fifo_pixel_source RGB888 扩展后、HDMI AXIS 前
//     的数据 mux; valid/user/last/ready 均不经本模块; 背压时 x 计数随
//     I_advance(=de&&ready) 冻结, 与 fifo_pixel_source S_hcol 同拍保持
//     (数据/字幕一起保持, 不丢不重不错位)。
//
// 坐标来源: 自计数(不依赖 video_timing_data 内部信号):
//   * line_cnt: VS 下降沿(帧首 vcnt=0, 与 HS 下降沿同拍, VS 优先)清零,
//     其后每个 HS 下降沿 +1 => line_cnt 与 video_timing_data S_vcnt 一致;
//   * x_cnt: !I_de 清零, I_advance 拍 +1(饱和于 HACTIVE-1) => 与
//     fifo_pixel_source S_hcol 逐拍一致, 保证字幕与像素流同位;
//   * 行号 y = line_cnt - VSTART(VSTART=VSA+VBP=35, 有效行 35..514)。
//
// 尺寸输入 CDC(ctrl -> pixel, 准静态):
//   顶层在帧提交拍(active_buffer 消隐翻转, ctrl 域)锁存 loader src_w/h_out
//   并翻转 cap_toggle; 本模块 2FF 同步 toggle、异或检沿后捕获 cap_w/cap_h
//   (总线在两次 toggle 之间恒定 => 捕获拍为一致快照, 无逐位同步需求;
//   ctrl↔pixel 已由 constraints/m1a_top.sdc 异步 false_path 覆盖)。
//   首次提交前 dim_rdy=0, 字幕整体关闭(加载黑屏期无叠加)。double-dabble
//   转换(16bit -> 4 位 BCD, w/h 顺序共 34 拍)在帧消隐窗内完成, 字幕与
//   新图同帧生效(提交拍锁存 => 同一次消隐)。
//
// 字模 ROM: case 常量 64'h 字面量(8 字节/字符), 纯组合查表 => LUT ROM,
//   不例化 BRAM 推断风险结构(check_report §2 四条件不适用)。
// ============================================================================
module res_caption #(
    parameter integer HACTIVE = 640,   // 有效行像素数(x_cnt 饱和界)
    parameter integer VSTART  = 35     // 垂直消隐行数(VSA+VBP, video_timing_data)
)(
    input  wire        I_clk,          // pixel_clk 25.2MHz
    input  wire        I_rst,          // 高有效异步复位(pixel 域, rst_pixel)
    // 视频时序(video_timing_data 同源, 负极性)
    input  wire        I_vs,
    input  wire        I_hs,
    input  wire        I_de,
    input  wire        I_advance,      // = I_de && axis_s_ready(流推进拍)
    // ctrl 域准静态尺寸输入(toggle 握手; 总线在 toggle 期间稳定)
    input  wire        cap_toggle,
    input  wire [15:0] cap_w,          // 源图宽(1..4096)
    input  wire [15:0] cap_h,          // 源图高(1..4096)
    // 叠加输出(纯组合, 与 axis_s_data 同拍)
    output wire        cap_mask,       // 黑底条区域(含字符位)
    output wire        cap_text        // 白字像素(cap_mask 内子集)
);

    // ---- 几何常量(10bit 显式定宽, 与 x_cnt/line_cnt 同宽比较) ----
    localparam [9:0] BOX_X0 = 10'd8;                   // 黑底条左上角 x
    localparam [9:0] BOX_W  = 10'd80;                  // 9 字符×8 + 2×4 内边距
    localparam [9:0] BOX_Y0 = VSTART[9:0] + 10'd8;     // 黑底条顶行(line_cnt)
    localparam [9:0] BOX_H  = 10'd16;
    localparam [9:0] TXT_X0 = 10'd12;                  // 首字符列(BOX_X0+PAD)
    localparam [9:0] TXT_W  = 10'd72;                  // 9 字符×8
    localparam [9:0] TXT_Y0 = VSTART[9:0] + 10'd12;    // 字符顶行(黑条内垂直居中)
    localparam [9:0] CHAR_H = 10'd8;
    localparam [9:0] X_SAT  = HACTIVE[9:0] - 10'd1;    // 639

    // ========================================================================
    // toggle 2FF 同步 + 检沿(pixel 域)
    // ========================================================================
    reg [2:0] tgl_sync;
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) tgl_sync <= 3'b000;
        else       tgl_sync <= {tgl_sync[1:0], cap_toggle};
    end
    wire cap_upd = tgl_sync[2] ^ tgl_sync[1];   // 同步后 toggle 变化 = 新尺寸

    // ========================================================================
    // 尺寸捕获 + double-dabble 二进制->BCD(16bit -> 4 位十进制, w/h 顺序)
    // ========================================================================
    reg [15:0] cap_h_r;                 // h 相转换源(w 相用捕获拍总线直载)
    reg [31:0] sh;                      // {bcd[31:16], bin[15:0]} 移位寄存器
    reg [4:0]  cst;                     // 相位内步进 0..16
    reg        cph;                     // 0=w 相, 1=h 相
    reg        crun;
    reg [15:0] w_bcd, h_bcd;
    reg        dim_rdy;                 // 首次转换完成(字幕总开关)

    function [3:0] adj4;                // 加三调整(入 0..9, 出 ≤12, 无溢出)
        input [3:0] n;
        begin
            adj4 = (n >= 4'd5) ? (n + 4'd3) : n;
        end
    endfunction

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            cap_h_r <= 16'd0;
            sh      <= 32'd0;
            cst     <= 5'd0;
            cph     <= 1'b0;
            crun    <= 1'b0;
            w_bcd   <= 16'd0;
            h_bcd   <= 16'd0;
            dim_rdy <= 1'b0;
        end else begin
            if (cap_upd) begin          // 捕获(总线稳定拍)并重启转换
                cap_h_r <= cap_h;
                sh      <= {16'd0, cap_w};
                cst     <= 5'd0;
                cph     <= 1'b0;
                crun    <= 1'b1;
            end else if (crun) begin
                if (cst != 5'd16) begin
                    sh  <= {adj4(sh[31:28]), adj4(sh[27:24]),
                            adj4(sh[23:20]), adj4(sh[19:16]),
                            sh[15:0], 1'b0};
                    cst <= cst + 5'd1;
                end else if (!cph) begin
                    w_bcd <= sh[31:16];
                    sh    <= {16'd0, cap_h_r};
                    cst   <= 5'd0;
                    cph   <= 1'b1;
                end else begin
                    h_bcd   <= sh[31:16];
                    crun    <= 1'b0;
                    dim_rdy <= 1'b1;
                end
            end
        end
    end

    // ========================================================================
    // 行/列计数(line_cnt == vcnt; x_cnt == fifo_pixel_source S_hcol 同拍)
    // ========================================================================
    reg [9:0] line_cnt;
    reg [9:0] x_cnt;
    reg       vs_d, hs_d;

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            line_cnt <= 10'd0;
            x_cnt    <= 10'd0;
            vs_d     <= 1'b1;
            hs_d     <= 1'b1;
        end else begin
            vs_d <= I_vs;
            hs_d <= I_hs;
            // 帧首 VS 下降沿(vcnt=0)清零; 其后每个 HS 下降沿进入新行
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
    // 字符映射: slot 0..8 -> 字符码(0..9=数字, 10='x', 11=空白)
    //   布局 = [w 的 nw 位十进制(MSD 先)] ['x'] [h 的 nh 位] 左对齐
    // ========================================================================
    wire [3:0] wd3 = w_bcd[15:12], wd2 = w_bcd[11:8], wd1 = w_bcd[7:4];
    wire [3:0] hd3 = h_bcd[15:12], hd2 = h_bcd[11:8], hd1 = h_bcd[7:4];

    wire [2:0] nw = (wd3 != 4'd0) ? 3'd4 : (wd2 != 4'd0) ? 3'd3 :
                    (wd1 != 4'd0) ? 3'd2 : 3'd1;   // w 十进制位数(1..4)
    wire [2:0] nh = (hd3 != 4'd0) ? 3'd4 : (hd2 != 4'd0) ? 3'd3 :
                    (hd1 != 4'd0) ? 3'd2 : 3'd1;

    function [3:0] bcd_nib;             // 取 4 位 BCD 的第 pos 位(pos0=个位)
        input [15:0] v;
        input [2:0]  pos;
        begin
            case (pos)
                3'd3:    bcd_nib = v[15:12];
                3'd2:    bcd_nib = v[11:8];
                3'd1:    bcd_nib = v[7:4];
                default: bcd_nib = v[3:0];
            endcase
        end
    endfunction

    function [3:0] char_code;           // 槽位 -> 字符码
        input [3:0] slot;
        reg   [3:0] nw4, nh4, k4;
        reg   [2:0] pos;
        begin
            nw4 = {1'b0, nw};
            nh4 = {1'b0, nh};
            if (slot < nw4) begin
                pos = nw4[2:0] - 3'd1 - slot[2:0];       // MSD 先
                char_code = bcd_nib(w_bcd, pos);
            end else if (slot == nw4) begin
                char_code = 4'd10;                        // 'x'
            end else if (slot < (nw4 + 4'd1 + nh4)) begin
                k4  = slot - nw4 - 4'd1;
                pos = nh4[2:0] - 3'd1 - k4[2:0];
                char_code = bcd_nib(h_bcd, pos);
            end else begin
                char_code = 4'd11;                        // 空白
            end
        end
    endfunction

    // ========================================================================
    // 8x8 字模 ROM(case 常量; 每字符 8 字节, row0 存 [63:56], bit7=最左像素)
    // ========================================================================
    function [7:0] glyph_row;
        input [3:0] code;
        input [2:0] row;
        reg  [63:0] g;
        reg  [2:0]  rinv;
        begin
            case (code)
                4'd0:    g = 64'h3C666E7666663C00;   // '0'
                4'd1:    g = 64'h1838181818187E00;   // '1'
                4'd2:    g = 64'h3C66060C18307E00;   // '2'
                4'd3:    g = 64'h3C66061C06663C00;   // '3'
                4'd4:    g = 64'h0C1C3C6C7E0C0C00;   // '4'
                4'd5:    g = 64'h7E607C0606663C00;   // '5'
                4'd6:    g = 64'h1C30607C66663C00;   // '6'
                4'd7:    g = 64'h7E060C1818181800;   // '7'
                4'd8:    g = 64'h3C66663C66663C00;   // '8'
                4'd9:    g = 64'h3C66663E060C3800;   // '9'
                4'd10:   g = 64'h0000663C183C6600;   // 'x'
                default: g = 64'h0000000000000000;   // 空白
            endcase
            rinv = 3'd7 - row;
            glyph_row = g >> ({rinv, 3'b000});
        end
    endfunction

    // ========================================================================
    // 叠加判定(纯组合; 仅 I_de 有效区, dim_rdy 前整体关闭)
    // ========================================================================
    wire        in_box_x = (x_cnt >= BOX_X0) && (x_cnt < (BOX_X0 + BOX_W));
    wire        in_box_y = (line_cnt >= BOX_Y0) && (line_cnt < (BOX_Y0 + BOX_H));
    wire        in_txt_x = (x_cnt >= TXT_X0) && (x_cnt < (TXT_X0 + TXT_W));
    wire        in_txt_y = (line_cnt >= TXT_Y0) && (line_cnt < (TXT_Y0 + CHAR_H));
    wire [9:0]  gx       = x_cnt - TXT_X0;        // 文本区内列偏移 0..71
    wire [9:0]  gy       = line_cnt - TXT_Y0;     // 文本区内行偏移 0..7
    wire [3:0]  slot     = gx[6:3];               // /8 => 字符槽 0..8
    wire [7:0]  gbits    = glyph_row(char_code(slot), gy[2:0]);
    wire        gpx      = gbits[3'd7 - gx[2:0]];

    assign cap_mask = I_de && dim_rdy && in_box_x && in_box_y;
    assign cap_text = cap_mask && in_txt_y && in_txt_x && gpx;

endmodule
