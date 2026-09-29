`timescale 1ns / 1ps
// ============================================================================
// pixel_adjust — 像素级亮度/对比度调节 (task_040 自研, pixel 域 25.2MHz)
//
// 功能: 逐像素一拍完成 亮度->对比度 两级调节(顺序冻结: 先亮度后对比度,
//   两级各自饱和, 见 PARAM_SPEC §3), RGB888 三通道同构:
//     亮度   out = sat8(pixel + off)          off 为 two's complement 偏移
//     对比度 out = (b-128)·g + 128 (128 锚定), g 由 2bit 档位选择:
//       sel=0: g=0.0  恒输出 128 (对比度=0)
//       sel=1: g=1.0  直通(默认档)
//       sel=2: g=1.5  b + ((b-128) >>> 1)      右移 1 位近似(截断向 -inf)
//       sel=3: g=2.0  ((b-128) <<< 1) + 128
//   全部为 加法/移位/常量, 无通用乘法器(红线 5 低功耗论述素材, 代价对比见
//   PARAM_SPEC §5 与 td/ 面积实测)。
//
// 饱和纪律: 两级均为 10bit 有符号中间值 + sat8 钳位(0/255), 任何输入组合
//   不回绕(255+off 不落 0, 0+负 off 不落 255); 10bit 覆盖两级极值
//   (亮度和域 [-128,383], 对比度域 [-128,382])。
//
// 接口: **纯组合直通**(与 res_caption 叠加点同拍风格) —— O_pixel 与
//   I_pixel 同拍, 背压时上游数据保持即输出保持, 无需流水保持端口;
//   1 像素/时钟吞吐, 不新增帧缓冲。I_bri_off/I_con_sel 语义为"帧内恒定"
//   (由 param_ctrl 在 vsync 边界更新, 本模块不感知帧边界)。
//   集成位置: fifo_pixel_source 数据之后、OSD/字幕 mask mux 之前,
//   mask 与调节后像素天然同拍(已在 TB 集成台验证)。
//
// 复位: 无时序元件, 不需要复位(输出恒为输入的确定函数)。
// ============================================================================
module pixel_adjust (
    input  wire [7:0]  I_bri_off,    // 亮度偏移(two's complement, 帧内恒定)
    input  wire [1:0]  I_con_sel,    // 对比度档: 0=x0.0 1=x1.0 2=x1.5 3=x2.0
    input  wire [23:0] I_pixel,      // RGB888 输入
    output wire [23:0] O_pixel       // 处理后 RGB888(与输入同拍)
);

    // ---- sat8: 10bit 有符号 -> [0,255] 钳位(封顶 255 / 封底 0) ----
    function [7:0] sat8;
        input signed [9:0] s;
        begin
            if (s < 10'sd0)        sat8 = 8'd0;
            else if (s > 10'sd255) sat8 = 8'd255;
            else                   sat8 = s[7:0];
        end
    endfunction

    // ---- 亮度: sat(p + off), 纯加法(off 符号扩展到 10bit) ----
    function signed [9:0] bri_sum;
        input [7:0] p;
        input [7:0] off;
        begin
            bri_sum = $signed({2'b00, p}) + $signed({{2{off[7]}}, off});
        end
    endfunction

    // ---- 对比度: 128 锚定移位近似 ----
    function [7:0] con_gain;
        input [7:0] b;              // 亮度级输出 0..255
        input [1:0] sel;
        reg signed [9:0] d, c;
        begin
            d = $signed({2'b00, b}) - 10'sd128;    // b-128 ∈ [-128,127]
            case (sel)
                2'd0:    con_gain = 8'd128;        // g=0.0: 对比度=0 全灰
                2'd1:    con_gain = b;             // g=1.0: 直通
                2'd2:    begin                     // g=1.5: b+(b-128)/2
                             c        = $signed({2'b00, b}) + (d >>> 1);
                             con_gain = sat8(c);
                         end
                default: begin                     // g=2.0: 2(b-128)+128
                             c        = (d <<< 1) + 10'sd128;
                             con_gain = sat8(c);
                         end
            endcase
        end
    endfunction

    // ---- 两级合成(顺序冻结: 先亮度后对比度; 变异测试注入点) ----
    function [7:0] adj8;
        input [7:0] p;
        input [7:0] off;
        input [1:0] sel;
        begin
            adj8 = con_gain(sat8(bri_sum(p, off)), sel);
        end
    endfunction

    assign O_pixel = {adj8(I_pixel[23:16], I_bri_off, I_con_sel),
                      adj8(I_pixel[15:8],  I_bri_off, I_con_sel),
                      adj8(I_pixel[7:0],   I_bri_off, I_con_sel)};

endmodule
