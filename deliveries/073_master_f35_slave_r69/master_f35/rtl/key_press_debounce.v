`timescale 1ns / 1ps
// key_press_debounce：按键同步、消抖与单次按下事件检测。连续稳定采样达到计数门限后更新状态。
module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 50_000_000,   // ctrl_clk
    parameter integer DEBOUNCE_MS = 20            // 消抖时间
)(
    input  wire clk,
    input  wire rst_n,              // 本项目低有效复位(教程原为高有效 rst, 适配点)
    input  wire button_in,          // 低有效: 松开=1, 按下=0
    output reg  press_pulse,        // 按下沿单拍脉冲(消抖确认后)
    output reg  button_stable_out   // 消抖后稳定状态(1=松开 0=按下, 供长按检测)
);

    // 20ms @ 50MHz = 1_000_000 周期; 32 位计数器覆盖任意 CLK_FREQ_HZ/MS 组合
    localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

    reg        button_sync0;
    reg        button_sync1;
    reg        button_stable;
    reg [31:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            button_sync0     <= 1'b1;   // 松开态
            button_sync1     <= 1'b1;
            button_stable    <= 1'b1;
            button_stable_out<= 1'b1;
            press_pulse      <= 1'b0;
            cnt              <= 32'd0;
        end else begin
            // 两级同步
            button_sync0 <= button_in;
            button_sync1 <= button_sync0;
            // 单拍脉冲默认清零(消抖确认拍可覆盖, 同块后赋值胜出)
            press_pulse  <= 1'b0;

            if (button_sync1 == button_stable) begin
                // 输入与稳定态一致: 无变化, 计数清零
                cnt <= 32'd0;
            end else if (cnt >= DEBOUNCE_CYCLES - 1) begin
                // 稳定保持达消抖时间: 接受新电平
                cnt              <= 32'd0;
                button_stable    <= button_sync1;
                button_stable_out<= button_sync1;
                if (!button_sync1) begin
                    // 旧 stable=1(松开) -> 新=0(按下): 按下沿
                    press_pulse <= 1'b1;
                end
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end

endmodule
