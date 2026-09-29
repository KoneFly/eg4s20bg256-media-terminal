`timescale 1ns / 1ps
// ============================================================================
// fifo_pixel_source — 异步FIFO读侧 → RGB888 → AXIS 视频源 (pixel 域 25.2MHz)
//
// 外部可观察语义(user/valid/last/反压保持)与 video_source_b_fixed 逐拍等价:
//   * axis_s_valid = I_de(仅有效视频区);
//   * user(SOF): 任一次 VS 跳变(含复位)武装, 首条有效行首像素被采样时一拍;
//   * last(EOL): 每行第 HACTIVE 像素一拍;
//   * hcol 消隐清零, 有效区随 I_de&&ready 推进, 反压时保持(不丢不重).
//
// 数据对齐(预取+寄存, 1 拍 FIFO 读延迟补偿):
//   * 消隐期(!I_de)只要 FIFO 非空且未预取即发一拍 fifo_rd_en 预取(电平
//     条件, [task_026 第三步] 原 empty 下降沿条件在"DE 高期间首次变非空"
//     场景永久错过边沿 => 预取死锁黑屏, sim/prefetch_review_09026.log 实证;
//     电平条件在下一个消隐窗口即恢复读取, 对齐锚语义不变: 正常帧首队头
//     仍是像素0, 预取仍在消隐期、仍单拍、仍由 prefetched 自锁);
//     响应经寄存载入 pix_r 并武装 first_px;
//   * 帧内第 0 像素由 pix_r 呈现, 其握手完成当拍发出 rd_en 取像素1, 此后
//     每个像素的握手当拍发出 rd_en 取下一像素 —— FIFO 寄存输出(rd_en 后
//     1 拍有效)恰好在对位置呈现下一像素, 屏上位置 (x,y) 恒为图案 (x,y);
//   * rd_fresh 标志跟踪 FIFO 输出寄存器是否持有未呈现像素: 握手消费后由
//     当拍读出是否发生更新, 反压期间保持(重复呈现当前像素, 不丢不重).
//
// 下溢契约: FIFO 空(且无在途读响应)期间输出恒为黑 24'h000000, valid 仍
// 跟随 I_de; empty 清除 prefetched(预取读在途时除外, 此时对齐锚 pix_r 已
// 成立); 重预取仅发生在消隐期(电平条件 !I_de && !fifo_empty && !prefetched),
// 帧对齐在下一个 VS 后自然恢复: 帧末 FIFO 排空清 prefetched, 帧首消隐期
// FE 重新预填(队头=像素0), 首次非空即触发预取重建对齐锚. 帧末最后一个
// 像素呈现时 FIFO 恰好排空, 但该像素数据已在 FIFO 输出寄存器中
// (rd_fresh=1), 正常呈现不丢.
//
// 本模块不含视频时序发生器(HS/VS/DE 由顶层例化 video_timing_data 提供).
// ============================================================================
module fifo_pixel_source #(
    parameter integer HACTIVE = 640,
    parameter integer VACTIVE = 480
)(
    input  wire        I_clk,          // pixel_clk 25.2MHz
    input  wire        I_rst,          // 高有效同步复位
    input  wire        I_vs,           // 帧同步, 负极性(video_timing_data O_vs)
    input  wire        I_de,           // 数据使能(有效视频区高)
    // 异步FIFO读侧
    output wire        fifo_rd_en,
    input  wire [15:0] fifo_rd_data,   // RGB565(rd_en后1拍有效)
    input  wire        fifo_empty,
    // AXIS 输出
    input  wire        axis_s_ready,   // 下游反压(加密IP)
    output wire        axis_s_user,    // SOF: 每帧首有效像素一拍
    output wire        axis_s_valid,   // = I_de
    output wire        axis_s_last,    // EOL: 每行第HACTIVE像素一拍
    output wire [23:0] axis_s_data     // {R,G,B} RGB888
);

    localparam integer HCOL_W = (HACTIVE <= 512) ? 9 :
                                (HACTIVE <= 1024) ? 10 : 11;

    // ---- 与 video_source_b_fixed 逐拍一致的 hcol / 帧武装逻辑 ----
    reg        S_vs_1d;
    reg        S_frame_arm;
    reg [HCOL_W-1:0] S_hcol;

    wire S_advance = I_de && axis_s_ready;   // 有效像素被下游采样

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            S_vs_1d     <= 1'b0;
            S_frame_arm <= 1'b1;
        end else begin
            S_vs_1d <= I_vs;
            if (S_vs_1d != I_vs)
                S_frame_arm <= 1'b1;
            else if (S_advance && S_frame_arm && (S_hcol == {HCOL_W{1'b0}}))
                S_frame_arm <= 1'b0;
        end
    end

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst)
            S_hcol <= {HCOL_W{1'b0}};
        else if (!I_de)
            S_hcol <= {HCOL_W{1'b0}};
        else if (S_advance) begin
            if (S_hcol == HACTIVE - 1)
                S_hcol <= {HCOL_W{1'b0}};
            else
                S_hcol <= S_hcol + {{(HCOL_W-1){1'b0}}, 1'b1};
        end
    end

    assign axis_s_valid = I_de;
    assign axis_s_user  = I_de && S_frame_arm && (S_hcol == {HCOL_W{1'b0}});
    assign axis_s_last  = I_de && (S_hcol == HACTIVE - 1);

    // ---- 预取与读出节拍 ----
    reg        prefetched;   // 已完成预取(帧对齐锚成立)
    reg        first_px;     // 下一呈现像素来自 pix_r(帧第0像素)
    reg        rd_fresh;     // fifo_rd_data 持有未呈现像素
    reg        rd_pend;      // 预取读单拍脉冲
    reg        rd_pend_d;
    reg [15:0] pix_r;        // 帧第0像素寄存

    // [task_026 第三步] 电平条件(原 empty_d 下降沿依赖已删): 消隐期非空即
    // 预取, prefetched 自锁保证单次; DE 高首次非空不再永久死锁。
    wire pf_trig = !I_de && !fifo_empty && !prefetched;
    wire de_read = I_de && axis_s_ready && prefetched && !fifo_empty;

    assign fifo_rd_en = rd_pend || de_read;

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            prefetched <= 1'b0;
            first_px   <= 1'b0;
            rd_fresh   <= 1'b0;
            rd_pend    <= 1'b0;
            rd_pend_d  <= 1'b0;
            pix_r      <= 16'd0;
        end else begin
            rd_pend   <= pf_trig;
            rd_pend_d <= rd_pend;

            // 预取响应(读后1拍)载入对齐锚; 消费优先于装载(避免把对齐锚
            // 呈现到错误列位置)
            if (S_advance) begin
                first_px <= 1'b0;   // 帧第0像素已被采样
            end else if (rd_pend_d) begin
                pix_r    <= fifo_rd_data;
                first_px <= 1'b1;
            end

            // empty 清除预取标志; 预取读在途时对齐锚已成立, 不清
            if (fifo_empty && !rd_pend && !rd_pend_d)
                prefetched <= 1'b0;
            else if (pf_trig)
                prefetched <= 1'b1;

            // FIFO 输出寄存器新鲜度: 消费当拍由读出是否发生更新,
            // 反压期间保持(当前像素重复呈现); de_read 蕴含 S_advance
            if (S_advance)
                rd_fresh <= de_read;
        end
    end

    // ---- 呈现选择与 RGB888 扩展 ----
    wire        src_first = first_px;
    wire        src_fifo  = rd_fresh && !first_px;
    wire        present   = src_first || src_fifo;
    wire [15:0] px565     = (I_de && present) ?
                            (src_first ? pix_r : fifo_rd_data) : 16'h0000;

    rgb565_to_rgb888 u_rgb565_to_rgb888 (
        .clk             (I_clk),
        .rst_n           (~I_rst),
        .pixel_valid     (I_de),
        .pixel_rgb565    (px565),
        .pixel_valid_out (),
        .pixel_rgb888    (axis_s_data)
    );

endmodule
