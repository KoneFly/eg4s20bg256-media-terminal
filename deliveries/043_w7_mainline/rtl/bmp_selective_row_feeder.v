`timescale 1ns/1ps
// ============================================================================
// bmp_selective_row_feeder — task_046 新增(B2 冻结 接口 3 前级): 选择性
// 行解码供流器。把"区间字节流(每内容行恰一源行窗口 src_win 像素, 24bpp
// BGR)"转成 640x480 目标像素流, 输出签名与 bmp_resampler 输出一致
// (out_x/out_y/out_pixel/out_valid + dn_full 背压), 量化 R[7:3]G[7:2]
// B[7:3] 截断, 段末 ceil 列 DDA, KEEP_ASPECT 居中黑边(16'h0000),
// 全帧恒 307200 像素(像素计数闭合判据; 每行恰 640、每内容行恰 cw 个
// 内容列, 其余列黑)。
//
// 结构:
//   * F_HDR: 收 54B 头 → 字段+格式判定(与 converter 同契约域);
//   * 像素引擎: ox 单列前进; 非内容列发黑免数据; 内容列取 1 深像素阶
//     (staged_rgb): 源像素 3 字节收集 BGR, 段末 ceil DDA(acc_h)折返
//     进阶; 阶占或下游满 ⇒ byte_ready 关断(interval reader 弹性吸收);
//   * 行边长: 内容行消费恰 src_win*3B; rc==src_win 后 64 拍窗内须见
//     ival_done, 提前/缺席皆 E_ROW_LEN;
//   * F_FIN: px_total==307200 当拍 frame_done。
// ============================================================================
module bmp_selective_row_feeder (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        fs_start,       // 单拍: 新装载(F_HDR 起)
    input  wire        byte_valid,
    input  wire [7:0]  byte_data,
    output wire        byte_ready,
    input  wire        ival_done,      // 每内容行一条区间收尾(对齐点)
    input  wire [7:0]  rd_error,       // interval reader sticky(透传)

    // 头字段输出(规划器/包装置用)
    output reg  [15:0] hdr_w,
    output reg  [15:0] hdr_h,
    output reg         hdr_topdown,
    output reg  [31:0] hdr_bfo,
    output reg         hdr_fmtok,
    output reg         hdr_valid,

    // 头扩展跳过(bfOffBits>54 时补读区间 [54,bfo), 本态消费丢弃)
    input  wire        hdr_skip,       // 单拍: F_GEOM 受理进 F_HDRSKP

    // 内容几何(plan_supported 后 geom_latch 锁存)
    input  wire        geom_latch,
    input  wire [15:0] content_w,      // cw
    input  wire [15:0] content_h,      // ch
    input  wire [15:0] src_win,        // 源窗口(像素/行)
    input  wire [10:0] lft,
    input  wire [9:0]  top_black,
    input  wire [9:0]  bot_black,

    // 目标像素流(resampler 签名)
    output reg  [10:0] out_x,
    output reg  [9:0]  out_y,
    output reg  [15:0] out_pixel,
    output reg         out_valid,
    input  wire        dn_full,

    output reg         frame_done,
    output reg  [7:0]  error,
    output wire        busy
);
    localparam [7:0] E_NONE     = 8'h00;
    localparam [7:0] E_ROW_LEN  = 8'h62;
    localparam [7:0] E_STARVE   = 8'h63;
    localparam [7:0] E_UPSTREAM = 8'h10;

    localparam [3:0]
        F_IDLE = 4'd0, F_HDR = 4'd1, F_GEOM = 4'd2, F_ROW = 4'd3,
        F_FIN  = 4'd4, F_ERR = 4'd5, F_HDRSKP = 4'd6;

    reg [3:0]  state;
    reg [15:0] cw_r, ch_r, swin_r;
    reg [10:0] lft_r;
    reg [9:0]  top_r;

    // 像素前进引擎
    reg [9:0]  oy;
    reg [10:0] ox;
    reg [15:0] rc;
    reg [15:0] acc_h;
    reg [19:0] px_total;

    // 像素阶(1 深)
    reg        staged;
    reg [15:0] staged_rgb;
    reg        pend_is_cont;   // 呈现中像素的内容属性(消费拍推进用)

    // 头收集
    reg [5:0]  hdr_cnt;
    reg [7:0]  hb0, hb1, hb10, hb11, hb12, hb13, hb14, hb15;
    reg [7:0]  hb18, hb19, hb20, hb21, hb22, hb23, hb24, hb25;
    reg [7:0]  hb26, hb27, hb28, hb29, hb30, hb31, hb32, hb33;

    // BGR 收集(第3拍成像素)
    reg [7:0]  b_r, g_r;
    reg [1:0]  bcnt;

    // 行边长对齐
    reg        ival_done_r;
    wire       ival_pe = ival_done && !ival_done_r;
    reg        row_done_ok;
    reg [19:0] starve_wd;

    // ---- 行/列类别(组合) ----
    wire [10:0] cw11    = cw_r[10:0];
    wire [10:0] oy11    = {1'b0, oy};
    wire [10:0] top11   = {1'b0, top_r};
    wire [10:0] cont_hi = {1'b0, top_r} + {1'b0, ch_r[9:0]};
    wire        row_is_cont = (oy11 >= top11) && (oy11 < cont_hi);
    wire [10:0] lft_end = lft_r + cw11;
    wire        col_is_cont = row_is_cont && (ox >= lft_r) && (ox < lft_end);
    // 头字段组合视图(54B 收集期间随字节更新)
    wire [31:0] w32     = {hb21, hb20, hb19, hb18};
    wire [31:0] h32     = {hb25, hb24, hb23, hb22};
    wire [31:0] h32_abs = h32[31] ? (~h32 + 32'd1) : h32;

    wire [15:0] rgb565_c = {byte_data[7:3], g_r[7:2], b_r[7:3]};
    wire        third_b  = (bcnt == 2'd2);
    wire        fold_w   = ((acc_h + cw_r) >= swin_r);
    wire        hold3    = third_b && fold_w && staged;

    // ---- 消费节流(1B/16clk): 复现旧路径 fat32_lite 匀速级(1 字/64 拍 =
    //   1B/20 拍, 给显示读留 21% 裕量)的 fb 写侧节律 —— 选择路径消除了字节间空闲, 若按消费能力
    //   满速供像素, SDRAM 写突发会挤占显示读(集成冒烟实测显示行缺 5 像素);
    //   以旧路径已上板验证的节律为上限, 总时长不变(SPI 仍为瓶颈)。
    reg [4:0]  pace_cnt;
    wire       pace_ok = (pace_cnt == 5'd0);

    assign byte_ready = ((state == F_HDR) || (state == F_HDRSKP) ||
                        ((state == F_ROW) && row_is_cont &&
                         (rc < swin_r) && !hold3)) && pace_ok;
    // busy = 数据通路处理中(F_FIN 为"等待下次启动"的停泊态, 不算忙 —— 
    //   包装置的 fs_start 电平保持以本信号为撤销条件)
    assign busy       = (state != F_IDLE) && (state != F_ERR) && (state != F_FIN);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= F_IDLE;
            cw_r <= 16'd0; ch_r <= 16'd0; swin_r <= 16'd0;
            lft_r <= 11'd0; top_r <= 10'd0;
            oy <= 10'd0; ox <= 11'd0; rc <= 16'd0; acc_h <= 16'd0;
            staged <= 1'b0; staged_rgb <= 16'd0; pend_is_cont <= 1'b0;
            hdr_cnt <= 6'd0;
            hdr_w <= 16'd0; hdr_h <= 16'd0; hdr_topdown <= 1'b0;
            hdr_bfo <= 32'd0; hdr_fmtok <= 1'b0; hdr_valid <= 1'b0;
            b_r <= 8'd0; g_r <= 8'd0; bcnt <= 2'd0;
            ival_done_r <= 1'b0; row_done_ok <= 1'b0; starve_wd <= 20'd0;
            pace_cnt <= 5'd0;
            out_x <= 11'd0; out_y <= 10'd0; out_pixel <= 16'd0; out_valid <= 1'b0;
            frame_done <= 1'b0; error <= E_NONE;
        end else begin
            out_valid  <= 1'b0;
            frame_done <= 1'b0;
            ival_done_r <= ival_done;
            if (pace_cnt != 5'd0) pace_cnt <= pace_cnt - 5'd1;

            // interval reader sticky 透传
            if (error == E_NONE && rd_error != 8'd0) begin
                error <= E_UPSTREAM;
                state <= F_ERR;
            end

            case (state)
                // ------------------------------------------------------------
                // 空闲与回退等待态共用同步初始化, 启动优先于旧几何确认。
                F_IDLE, F_GEOM: begin
                    if (fs_start) begin
                        hdr_cnt <= 6'd0;
                        hdr_w <= 16'd0; hdr_h <= 16'd0; hdr_topdown <= 1'b0;
                        hdr_bfo <= 32'd0; hdr_fmtok <= 1'b0; hdr_valid <= 1'b0;
                        oy <= 10'd0; ox <= 11'd0; rc <= 16'd0; acc_h <= 16'd0;
                        staged <= 1'b0; bcnt <= 2'd0; pace_cnt <= 5'd0;
                        px_total <= 20'd0;
                        ival_done_r <= 1'b0; row_done_ok <= 1'b0; starve_wd <= 20'd0;
                        error <= E_NONE;
                        state <= F_HDR;
                    end else if (state == F_GEOM) begin
                        if (geom_latch) begin
                            cw_r <= content_w; ch_r <= content_h; swin_r <= src_win;
                            lft_r <= lft; top_r <= top_black;
                            rc <= 16'd0; acc_h <= 16'd0; staged <= 1'b0;
                            row_done_ok <= 1'b0; starve_wd <= 20'd0; pace_cnt <= 5'd0;
                            state <= F_ROW;
                        end else if (hdr_skip) begin
                            state <= F_HDRSKP;
                        end
                    end
                end
                // ------------------------------------------------------------
                F_HDR: begin
                    if (byte_valid) begin
                        case (hdr_cnt)
                            6'd0:  hb0  <= byte_data;   6'd1:  hb1  <= byte_data;
                            6'd10: hb10 <= byte_data;   6'd11: hb11 <= byte_data;
                            6'd12: hb12 <= byte_data;   6'd13: hb13 <= byte_data;
                            6'd14: hb14 <= byte_data;   6'd15: hb15 <= byte_data;
                            6'd18: hb18 <= byte_data;   6'd19: hb19 <= byte_data;
                            6'd20: hb20 <= byte_data;   6'd21: hb21 <= byte_data;
                            6'd22: hb22 <= byte_data;   6'd23: hb23 <= byte_data;
                            6'd24: hb24 <= byte_data;   6'd25: hb25 <= byte_data;
                            6'd26: hb26 <= byte_data;   6'd27: hb27 <= byte_data;
                            6'd28: hb28 <= byte_data;   6'd29: hb29 <= byte_data;
                            6'd30: hb30 <= byte_data;   6'd31: hb31 <= byte_data;
                            6'd32: hb32 <= byte_data;   6'd33: hb33 <= byte_data;
                            default: ;
                        endcase
                        if (hdr_cnt == 6'd53) begin
                            hdr_w <= w32[15:0];
                            hdr_h <= h32_abs[15:0];
                            hdr_topdown <= h32[31];
                            hdr_bfo <= {hb13, hb12, hb11, hb10};
                            hdr_fmtok <= ({hb1, hb0} == 16'h4D42) &&
                                         ({hb15, hb14} == 16'd40) &&
                                         ({hb27, hb26} == 16'd1) &&
                                         ({hb29, hb28} == 16'd24) &&
                                         ({hb33, hb32, hb31, hb30} == 32'd0);
                            hdr_valid <= 1'b1;
                            state <= F_GEOM;
                        end else begin
                            hdr_cnt <= hdr_cnt + 6'd1;
                        end
                    end
                end
                // ------------------------------------------------------------
                // ------------------------------------------------------------
                // 补读区间 [54,bfo) 消费丢弃, 收尾回 F_GEOM
                F_HDRSKP: begin
                    if (ival_pe) state <= F_GEOM;
                end
                // ------------------------------------------------------------
                F_ROW: begin
                    // ---- 字节消费(BGR 收集+折返入阶) ----
                    if (byte_valid && byte_ready && state == F_ROW) begin
                        pace_cnt <= 5'd19;
                    end
                    if (byte_valid && byte_ready) begin
                        if (bcnt == 2'd0) begin
                            b_r <= byte_data; bcnt <= 2'd1;
                            // 新行首字节: 上行收满标志至此失效(此后 ival_done
                            // 必属本行; 读侧序列化保证本行字节不先于上行 done)
                            if (rc == 16'd0) row_done_ok <= 1'b0;
                        end else if (bcnt == 2'd1) begin
                            g_r <= byte_data; bcnt <= 2'd2;
                        end else begin
                            bcnt <= 2'd0;
                            rc   <= rc + 16'd1;
                            if (rc == swin_r - 16'd1) row_done_ok <= 1'b1;
                            if (fold_w) begin
                                staged     <= 1'b1;
                                staged_rgb <= rgb565_c;
                                acc_h      <= acc_h + cw_r - swin_r;
                            end else begin
                                acc_h      <= acc_h + cw_r;
                            end
                        end
                    end

                    // ---- 行边长对齐(收满置标志; ival_done 先于收满 = 区间早闭) ----
                    // (旧版 rc==swin 窗口与行折返竞态: done 可在换行后一拍才到,
                    //  rc 已清零误判 E_ROW_LEN —— 以收满标志替代计数窗)
                    if (ival_pe && !row_done_ok) begin
                        error  <= E_ROW_LEN;
                        state  <= F_ERR;
                    end

                    // ---- 流饥饿看门狗 ----
                    if (row_is_cont && (rc < swin_r) && !byte_valid) begin
                        if (starve_wd == 20'hFFFFF) begin
                            error <= E_STARVE;
                            state <= F_ERR;
                        end else starve_wd <= starve_wd + 20'd1;
                    end else starve_wd <= 20'd0;

                    // ---- 像素前进引擎(持有到消费的标准握手) ----
                    //   旧版单拍 out_valid 用上一拍的 dn_full 决策呈现: 适配器
                    //   FIFO 恰在决策/呈现两拍间变满时该像素被静默丢弃(模块台
                    //   ready 恒 1 掩盖; 全链显示读争用压实测丢写 → 帧计数永不
                    //   闭合)。改为 out_valid 持有至 !dn_full 拍(适配器当拍
                    //   push), 消费拍才计数/推进; 字节侧由 rc<swin 门天然等待。
                    if (!out_valid) begin
                        if (!col_is_cont) begin
                            out_x <= ox; out_y <= oy; out_pixel <= 16'h0000;
                            out_valid   <= 1'b1;
                            pend_is_cont<= 1'b0;
                        end else if (staged) begin
                            out_x <= ox; out_y <= oy; out_pixel <= staged_rgb;
                            out_valid   <= 1'b1;
                            staged      <= 1'b0;
                            pend_is_cont<= 1'b1;
                        end
                    end else if (!dn_full) begin
                        // 本拍被适配器接受(in_valid && !fifo_full 同拍)
                        out_valid <= 1'b0;
                        px_total  <= px_total + 20'd1;
                        row_advance;
                    end
                end
                // ------------------------------------------------------------
                // F_FIN/F_ERR 均一拍后自动回 F_IDLE(帧完成/错误已由寄存器
                // 锁存: frame_done 单拍已发, error sticky 保持到包装置采样;
                // 停泊态会吃掉包装置的 fs_start 电平有效窗, 多装载挂死)
                F_FIN: begin
                    frame_done <= (px_total == 20'd307200);  // 单拍
                    state      <= F_IDLE;
                end
                F_ERR: begin
                    state <= F_IDLE;
                end
                default: state <= F_IDLE;
            endcase
        end
    end

    // ---- 行/帧前进(ox 639 折返; 行计数器复位; 帧末转 F_FIN) ----
    task row_advance;
        begin
            if (ox == 11'd639) begin
                ox <= 11'd0;
                oy <= oy + 10'd1;
                rc <= 16'd0; acc_h <= 16'd0;
                bcnt <= 2'd0; staged <= 1'b0;
                if (oy == 10'd479) state <= F_FIN;   // 末行末列当拍后入 F_FIN
            end else begin
                ox <= ox + 11'd1;
            end
        end
    endtask

endmodule
