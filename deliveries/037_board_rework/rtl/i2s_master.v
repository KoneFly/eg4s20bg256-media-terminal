`timescale 1ns / 1ps
// ============================================================================
// i2s_master — I2S master 发送 (mclk 域 12.3077MHz, 64fs: BCLK=mclk/2=6.144MHz,
// LRCK=BCLK/64=48kHz 帧率)
//
// 时序骨架与官方 hdmi_audio_tone_i2s_64fs 逐拍同构 (W04 对拍对象, 只读引用):
//   1. 纯 mclk 域寄存器输出; 复位初值 BCLK=0/LRCK=0/DOUT=0
//   2. BCLK 每 mclk 拍翻转 (= mclk/2)
//   3. 位计数 bit_cnt 0..63, 在"更新前 BCLK==1"的 mclk 拍递增
//   4. 同拍移出 shift[63] 并左移 (MSB first)
//   5. 帧打包 shift = {样本24bit 左对齐, 40'd0}, 总长 64
//   6. bit_cnt==63 拍: LRCK 0->1 装 R 段, LRCK 1->0 装 L 段并消费下一帧
//   7. 每 LRCK 全周期 (128 BCLK) 消费一个 48kHz 帧
// 与官方的差异 (设计意图内, 见 TASK_BRIEF 骨架表第 8 条): 官方为 mono 音源
//   两声道复用同一样本; 本模块按帧输入分别装 L/R (真立体声)。
//
// 帧消费协议 (M4/M5, 配合 32bit 寄存输出 FIFO):
//   * LRCK 1->0 装载拍: 装载 play 寄存器中的帧 (L 段), 并在 !empty 时拉
//     O_frame_rd 一拍; FIFO 于下一拍更新 rd_data (新弹出帧), master 再隔一拍
//     锁存到 play 寄存器, 供下一个 LRCK 周期使用。
//   * FIFO 空: 不拉 O_frame_rd, 装载静音 0 (play 寄存器视为已消费, 数据保留
//     在 FIFO 中, 恢复后自然继续)。
//   * 16->24 位扩展: S24 = {s16[15:0], 8'b0} (左对齐), 40 位零填充。
//   * 空载期间 BCLK/LRCK 骨架不断, 仅数据段为 0 (M7)。
//
// 复位: I_rst 高有效, 与官方模块同风格 (异步断言/异步释放); 骨架对拍要求
//   两模块同 rst 逐拍全等, 故不做域内释放同步 (顶层口径与 018 mode_a 一致,
//   跨域时序由 SDC clock groups 声明)。
// ============================================================================
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
