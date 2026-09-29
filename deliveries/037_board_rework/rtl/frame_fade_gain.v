`timescale 1ns/1ps

// 帧边界增益包络：视频淡入淡出的 alpha 搬到音频域作 gain，音画同步转场。
//
// 像素域在帧边界（frame_start）锁存 alpha——一帧内 gain 恒定，避免帧中
// alpha 渐变导致音频爆音；锁存值为准静态信号，经 2FF 跨域到音频域采用。
// 增益映射：fade_active 时 gain = alpha，空闲时 gain = 255（满音量）。
// 复位：两域各自异步置位 / 同步释放（每域一个复位桥）。
module frame_fade_gain (
    input  wire       pix_clk,
    input  wire       pix_rst_n,
    input  wire       frame_start,       // 像素域帧首脉冲
    input  wire [7:0] alpha_pix,         // 淡入淡出 alpha（像素域）
    input  wire       fade_active,       // alpha_pix 有效标志

    input  wire       aud_clk,           // 48kHz 类音频域
    input  wire       aud_rst_n,
    output reg  [7:0] gain_aud           // 音频域增益包络
);
    // ---------------- 复位桥：异步置位 / 同步释放 ----------------
    reg pix_rs1, pix_rs2;
    reg aud_rs1, aud_rs2;
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin pix_rs1 <= 1'b0; pix_rs2 <= 1'b0; end
        else            begin pix_rs1 <= 1'b1; pix_rs2 <= pix_rs1; end
    end
    always @(posedge aud_clk or negedge aud_rst_n) begin
        if (!aud_rst_n) begin aud_rs1 <= 1'b0; aud_rs2 <= 1'b0; end
        else            begin aud_rs1 <= 1'b1; aud_rs2 <= aud_rs1; end
    end
    wire pix_sync_rst_n = pix_rs2;
    wire aud_sync_rst_n = aud_rs2;

    // 像素侧：帧边界锁存 alpha（准静态库，2FF 安全）
    reg [7:0] alpha_latch;
    reg       fade_latch;
    always @(posedge pix_clk or negedge pix_sync_rst_n) begin
        if (!pix_sync_rst_n) begin
            alpha_latch <= 8'd255;
            fade_latch  <= 1'b0;
        end else if (frame_start) begin
            alpha_latch <= alpha_pix;
            fade_latch  <= fade_active;
        end
    end

    // 音频侧：2FF 同步后采用
    reg [7:0] sync1, sync2;
    reg       fsync1, fsync2;
    reg [7:0] seen_alpha;
    reg       seen_fade;

    always @(posedge aud_clk or negedge aud_sync_rst_n) begin
        if (!aud_sync_rst_n) begin
            sync1      <= 8'd255;
            sync2      <= 8'd255;
            fsync1     <= 1'b0;
            fsync2     <= 1'b0;
            seen_alpha <= 8'd255;
            seen_fade  <= 1'b0;
            gain_aud   <= 8'd255;
        end else begin
            sync1  <= alpha_latch;
            sync2  <= sync1;
            fsync1 <= fade_latch;
            fsync2 <= fsync1;

            if (sync2 != seen_alpha) begin
                // alpha 变了：采用新值
                seen_alpha <= sync2;
                gain_aud   <= sync2;
            end else if (!fsync2 && seen_fade) begin
                // 转场结束（fade_active 拉低）：恢复满音量
                seen_fade <= 1'b0;
                if (gain_aud != 8'd255)
                    gain_aud <= 8'd255;
            end else if (fsync2) begin
                // 转场进行中：跟踪 alpha
                seen_fade <= 1'b1;
                gain_aud  <= sync2;
            end
        end
    end
endmodule
