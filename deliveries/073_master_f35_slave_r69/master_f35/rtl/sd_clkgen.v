`timescale 1ns / 1ps
// ============================================================================
// sd_clkgen — SD 卡时钟序列发生器(50MHz 系统域)
//
// 每拍输出 {clk_h1, clk_h2} 给 ODDR(前半拍/后半拍电平); ODDR 再寄存一拍,
// 故本拍 go_rise 决定的 SDCLK 上升沿出现在两拍后的系统时钟上升沿 e。
//   MODE_ID ≈397kHz、MODE_DS 25MHz: 高低各 HALF 拍, 两半拍电平相同;
//   MODE_HS 50MHz: 每个运行拍 h1=1、h2=0。
// 事件:
//   adv — 与 go_rise 同拍。主机 CMD 输出寄存器在下一拍沿更新, 经负沿输出级
//         在沿 e 前半拍送出, 卡在沿 e 采样(建立/保持各半个系统周期)。
//   smp — go_rise 延迟固定拍数, 此拍可见的输入寄存器值为本 SD 时钟周期的卡输出:
//         HS: 输入寄存器在 e+1 拍沿采样(卡在上升沿 e 后 tODLY 内输出), 延迟 3;
//         ID/DS: 卡在下降沿后输出, 输入寄存器在下一上升沿(e+2)采样, 延迟 4。
//         smp_late=1 时再晚一拍(板级配置位, 复位期间静态)。
//         FIXME: 采样点按参考卡与理想走线选定, 仍需目标卡与板级 IO 时序实测确认
// 每个 SDCLK 上升沿恰好对应一个 smp, 因此停钟(run=0)流控不丢不重。
// mark: 与 adv 同拍给出的标记随同一流水到达 smp_mark, 用于把采样与"本方
//   在哪个沿发出的位"精确对应(HS 连续时钟下 smp 每拍都有, 不能靠计数对齐)。
// run=0 时停在低电平(SD 物理层规范允许主机停钟流控)。模式只应在低电平切换。
// ============================================================================
module sd_clkgen (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [1:0] mode,        // 0=ID, 1=DS 25MHz, 2=HS 50MHz
    input  wire       run,
    input  wire       smp_late,
    output reg        clk_h1,
    output reg        clk_h2,
    output wire       adv,
    output wire       smp,
    output wire       low,         // 时钟处于低电平半周期末(可安全切换模式)
    input  wire       mark,
    output wire       smp_mark
);
    localparam [1:0] MODE_ID = 2'd0, MODE_HS = 2'd2;
    localparam [5:0] HALF_ID = 6'd63;    // 50M/126 = 396.8kHz

    reg  [5:0] cnt;
    reg        level;
    reg  [4:0] dly, mdly;
    wire [2:0] si = (hs ? 3'd2 : 3'd3) + {2'b00, smp_late};

    wire       hs       = (mode == MODE_HS);
    wire [5:0] half     = (mode == MODE_ID) ? HALF_ID : 6'd1;
    wire       last_cyc = (cnt >= half - 6'd1);
    wire       go_rise  = hs ? run : (run && !level && last_cyc);
    wire       go_fall  = !hs && level && last_cyc;

    assign adv = go_rise;
    assign smp      = dly[si];
    assign smp_mark = mdly[si];
    assign low = hs || (!level && last_cyc);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt <= 6'd0; level <= 1'b0; dly <= 5'd0; mdly <= 5'd0;
            clk_h1 <= 1'b0; clk_h2 <= 1'b0;
        end else begin
            dly  <= {dly[3:0],  go_rise};
            mdly <= {mdly[3:0], go_rise && mark};
            if (hs) begin
                cnt <= 6'd0; level <= 1'b0;
                clk_h1 <= run; clk_h2 <= 1'b0;
            end else begin
                if (go_rise || go_fall) begin
                    level <= go_rise;
                    cnt   <= 6'd0;
                end else if (!last_cyc) begin
                    cnt <= cnt + 6'd1;
                end
                clk_h1 <= go_rise ? 1'b1 : go_fall ? 1'b0 : level;
                clk_h2 <= go_rise ? 1'b1 : go_fall ? 1'b0 : level;
            end
        end
    end
endmodule
