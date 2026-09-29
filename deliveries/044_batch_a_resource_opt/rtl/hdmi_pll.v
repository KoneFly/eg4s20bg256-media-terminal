`timescale 1ns / 1ps
// ============================================================================
// hdmi_pll — HDMI 发射链路时钟发生器 (EG4S20BG256)
//
// 功能: 由板载 50MHz 参考晶振产生三路时钟:
//   pixel_clk  : 25.2MHz  — 640x480@60 像素时钟 (VIC=1)
//   serial_clk : 126MHz   — 5x pixel, TMDS 10:1 串化时钟 (DDR 双沿=10x)
//   audio_mclk : 12.3077MHz — 音频参考主时钟 (近似 12.288MHz, 见下)
//   pll_locked : PLL 锁定指示(两个PLL取与)
//
// 频率与相位推导:
//   1. 640x480@60 像素时钟: 标准为 25.175MHz(VIC=1)。本工程晶振 50MHz,
//      25.175 = 50 * 1007/2000, 化简整数比超出 EG_PHY_PLL 分频范围
//      (REFCLK_DIV/FBCLK_DIV/CLKCx_DIV 均为 1~128), 无法精确合成。
//      取可精确合成的最近值 25.2MHz(=50*63/(5*25), VCO=630MHz):
//        VCO = FIN * FBCLK_DIV / REFCLK_DIV = 50 * 63 / 5 = 630MHz
//        C0  = VCO / CLKC0_DIV = 630 / 25 = 25.2MHz  (pixel_clk)
//        C1  = VCO / CLKC1_DIV = 630 / 5  = 126MHz   (serial_clk, 5x pixel)
//      25.2MHz 对 640x480 是显示时序工程常用值(官方 HX4S20C 例程同), 多数
//      HDMI 接收端容差内可锁定; ACR 的 CTS 按实际像素时钟动态计数, 自动匹配。
//   2. 音频参考主时钟: 12.288MHz(=256*48k) 与 50MHz 无整数倍比
//      (12.288 = 1536/125 MHz, 与50的比 1536/6250 不可用1~128分频器实现),
//      取 VCO=480MHz(=50*48/5) 下最近值 12.3077MHz(=480/39, 误差+0.16%)。
//      本任务的 48kHz 采样节奏在像素时钟域用精确整数分频产生
//      (25.2MHz/48k = 525 整除, 误差0), audio_mclk 仅作为后续 WAV 播放
//      参考时钟预留, 不参与采样节拍。
// ============================================================================
module hdmi_pll (
    input  wire ref_clk,      // 板载 50MHz 参考时钟 (R7)
    input  wire pll_rst_n,    // PLL 复位, 低有效
    output wire pixel_clk,    // 25.2MHz  像素时钟
    output wire serial_clk,   // 126MHz   TMDS 串化时钟
    output wire audio_mclk,   // 12.3077MHz 音频参考主时钟
    output wire pll_locked    // 高 = PLL 锁定
);

`ifdef SIMULATION
    // ------------------------------------------------------------------------
    // 仿真行为模型: 独立方波 + 锁定延迟, 用于 iverilog 行为仿真
    // (EG_PHY_PLL 为安路原语, 仿真不支持, 由行为模型替代)
    // ------------------------------------------------------------------------
    reg sim_pixel  = 1'b0;
    reg sim_serial = 1'b0;
    reg sim_audio  = 1'b0;
    reg sim_locked = 1'b0;

    // 25.2MHz: 半周期 19.8412ns; 126MHz: 3.9682ns; 12.3077MHz: 40.625ns
    always #19.841 sim_pixel  = ~sim_pixel;
    always #3.968  sim_serial = ~sim_serial;
    always #40.625 sim_audio  = ~sim_audio;

    initial begin
        sim_locked = 1'b0;
        #200;                   // 模拟 PLL 锁定时间
        sim_locked = 1'b1;
    end

    assign pixel_clk  = sim_pixel;
    assign serial_clk = sim_serial;
    assign audio_mclk = sim_audio;
    assign pll_locked = (pll_rst_n & sim_locked);

`else
    // ------------------------------------------------------------------------
    // 综合实现: EG_PHY_PLL 原语 (安路 EG4 模板, NORMAL 反馈)
    // ------------------------------------------------------------------------
    // 视频 PLL: VCO = 50*63/5 = 630MHz
    //   C0: DIV=25, CPHASE=24 -> 25.2MHz pixel_clk
    //   C1: DIV=5,  CPHASE=4  -> 126MHz  serial_clk
    // 音频 PLL: VCO = 50*48/5 = 480MHz
    //   C0: DIV=39, CPHASE=38 -> 12.3077MHz audio_mclk
    wire video_clk0_buf;         // C0 原始输出, 经 BUFG 全局化
    wire video_fb;               // 反馈时钟
    wire video_lock, audio_lock; // 各 PLL 锁定
    wire video_c2, video_c3, video_c4;
    wire audio_clk0_buf;
    wire audio_fb;
    wire audio_c1, audio_c2, audio_c3, audio_c4;
    wire serial_clk_raw;         // C1 原始输出, 经 BUFG 全局化(降低串化时钟偏斜)
    wire [7:0] open_do_v, open_do_a;
    wire       open_psdone_v, open_psdone_a;

    EG_LOGIC_BUFG u_video_fb_bufg (
        .i (video_clk0_buf),
        .o (video_fb)
    );
    assign pixel_clk = video_fb;   // 全局化后的像素时钟

    EG_LOGIC_BUFG u_serial_bufg (
        .i (serial_clk_raw),
        .o (serial_clk)
    );

    EG_PHY_PLL #(
        .DPHASE_SOURCE ("DISABLE"),
        .DYNCFG        ("DISABLE"),
        .FIN           ("50.000000"),
        .REFCLK_DIV    (5),
        .FBCLK_DIV     (63),
        .CLKC0_ENABLE  ("ENABLE"),
        .CLKC0_DIV     (25),
        .CLKC0_CPHASE  (24),
        .CLKC0_FPHASE  (0),
        .CLKC1_ENABLE  ("ENABLE"),
        .CLKC1_DIV     (5),
        .CLKC1_CPHASE  (4),
        .CLKC1_FPHASE  (0),
        .CLKC2_ENABLE  ("DISABLE"),
        .FEEDBK_MODE   ("NORMAL"),
        .FEEDBK_PATH   ("VCO_PHASE_0"),
        .STDBY_ENABLE  ("DISABLE"),
        .PLLRST_ENA    ("ENABLE"),
        .SYNC_ENABLE   ("DISABLE"),
        .GMC_GAIN      (4),
        .ICP_CURRENT   (29),
        .KVCO          (4),
        .LPF_CAPACITOR (1),
        .LPF_RESISTOR  (2)
    ) u_video_pll (
        .refclk   (ref_clk),
        .reset    (~pll_rst_n),
        .stdby    (1'b0),
        .extlock  (video_lock),
        .load_reg (1'b0),
        .psclk    (1'b0),
        .psdown   (1'b0),
        .psstep   (1'b0),
        .psclksel (3'b000),
        .psdone   (open_psdone_v),
        .dclk     (1'b0),
        .dcs      (1'b0),
        .dwe      (1'b0),
        .di       (8'd0),
        .daddr    (6'd0),
        .do       (open_do_v),
        .fbclk    (video_fb),
        .clkc     ({video_c4, video_c3, video_c2, serial_clk_raw, video_clk0_buf})
    );

    EG_LOGIC_BUFG u_audio_fb_bufg (
        .i (audio_clk0_buf),
        .o (audio_fb)
    );
    assign audio_mclk = audio_fb;

    EG_PHY_PLL #(
        .DPHASE_SOURCE ("DISABLE"),
        .DYNCFG        ("DISABLE"),
        .FIN           ("50.000000"),
        .REFCLK_DIV    (5),
        .FBCLK_DIV     (48),
        .CLKC0_ENABLE  ("ENABLE"),
        .CLKC0_DIV     (39),
        .CLKC0_CPHASE  (38),
        .CLKC0_FPHASE  (0),
        .CLKC1_ENABLE  ("DISABLE"),
        .CLKC2_ENABLE  ("DISABLE"),
        .FEEDBK_MODE   ("NORMAL"),
        .FEEDBK_PATH   ("VCO_PHASE_0"),
        .STDBY_ENABLE  ("DISABLE"),
        .PLLRST_ENA    ("ENABLE"),
        .SYNC_ENABLE   ("DISABLE"),
        .GMC_GAIN      (4),
        .ICP_CURRENT   (29),
        .KVCO          (4),
        .LPF_CAPACITOR (1),
        .LPF_RESISTOR  (2)
    ) u_audio_pll (
        .refclk   (ref_clk),
        .reset    (~pll_rst_n),
        .stdby    (1'b0),
        .extlock  (audio_lock),
        .load_reg (1'b0),
        .psclk    (1'b0),
        .psdown   (1'b0),
        .psstep   (1'b0),
        .psclksel (3'b000),
        .psdone   (open_psdone_a),
        .dclk     (1'b0),
        .dcs      (1'b0),
        .dwe      (1'b0),
        .di       (8'd0),
        .daddr    (6'd0),
        .do       (open_do_a),
        .fbclk    (audio_fb),
        .clkc     ({audio_c4, audio_c3, audio_c2, audio_c1, audio_clk0_buf})
    );

    assign pll_locked = (video_lock & audio_lock);
`endif

endmodule