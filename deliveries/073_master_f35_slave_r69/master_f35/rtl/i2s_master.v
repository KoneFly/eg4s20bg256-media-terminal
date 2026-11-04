`timescale 1ns / 1ps
// i2s_master：音频主时钟域I2S发送器，时序沿用官方发送结构。BCLK=mclk/2，每声道占64个BCLK，LRCK=mclk/256，约48076.923Hz；FIFO空时继续输出时钟并送静音。
module i2s_master (
    input  wire        I_mclk,         // 12.3077MHz
    input  wire        I_rst,          // 高有效 (与官方模块同风格)
    // 帧源 (FIFO 读侧直连)
    input  wire [31:0] I_frame_data,   // {left[15:0], right[15:0]}
    input  wire        I_frame_empty,  // FIFO 空
    output wire        O_frame_rd,     // 读下一帧 (LRCK 1->0 装载拍; 空时不拉)
    // I2S 三线
    output reg         O_i2s_BCLK,
    output reg         O_i2s_LRCK,
    output reg         O_i2s_DOUT
);

    reg  [5:0]  bit_cnt;      // 0..63
    reg  [63:0] shift;        // 帧移位寄存器 (MSB first)
    reg  [15:0] play_l;       // 待播帧 L (FIFO 弹出后锁存)
    reg  [15:0] play_r;       // 待播帧 R
    reg         play_valid;   // play 寄存器持有未播帧
    reg  [15:0] r_hold;       // 当前帧 R 段装载值 (LRCK 0->1 拍使用)
    reg         rd_req;       // O_frame_rd 单拍请求
    reg         rd_fire_d;    // 读请求被 FIFO 接受后一拍 (rd_data 已更新)

    wire rd_fire = rd_req && !I_frame_empty;

    assign O_frame_rd = rd_req;

    always @(posedge I_mclk or posedge I_rst) begin
        if (I_rst) begin
            O_i2s_BCLK <= 1'b0;
            O_i2s_LRCK <= 1'b0;
            O_i2s_DOUT <= 1'b0;
            bit_cnt    <= 6'd0;
            shift      <= 64'd0;
            play_l     <= 16'd0;
            play_r     <= 16'd0;
            play_valid <= 1'b0;
            r_hold     <= 16'd0;
            rd_req     <= 1'b0;
            rd_fire_d  <= 1'b0;
        end else begin
            // 骨架: BCLK 每拍翻转 (官方同构)
            O_i2s_BCLK <= ~O_i2s_BCLK;

            rd_req    <= 1'b0;            // 单拍脉冲默认归零
            rd_fire_d <= rd_fire;
            if (rd_fire_d) begin
                // FIFO rd_data 于读请求次拍更新, 本拍锁存新弹出帧
                play_l     <= I_frame_data[31:16];
                play_r     <= I_frame_data[15:0];
                play_valid <= 1'b1;
            end

            if (O_i2s_BCLK) begin
                // 官方同构: BCLK 更新前为 1 的拍移位/计数
                O_i2s_DOUT <= shift[63];
                shift      <= {shift[62:0], 1'b0};

                if (bit_cnt == 6'd63) begin
                    bit_cnt <= 6'd0;
                    if (!O_i2s_LRCK) begin
                        // L 段发完, 装 R 段 (当前帧)
                        O_i2s_LRCK <= 1'b1;
                        shift      <= {r_hold, 8'b0, 40'd0};
                    end else begin
                        // R 段发完, 进入下一帧: 装新帧 L 段并取下一帧
                        O_i2s_LRCK <= 1'b0;
                        shift      <= play_valid ? {play_l, 8'b0, 40'd0} : 64'd0;
                        r_hold     <= play_valid ? play_r : 16'd0;
                        play_valid <= 1'b0;
                        rd_req     <= !I_frame_empty;   // 空时不拉, FIFO 数据保留
                    end
                end else begin
                    bit_cnt <= bit_cnt + 6'd1;
                end
            end
        end
    end

endmodule
