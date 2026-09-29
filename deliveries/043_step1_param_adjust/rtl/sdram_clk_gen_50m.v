`timescale 1ns / 1ps
// ============================================================================
// sdram_clk_gen_50m — Task 010 降频双相时钟发生器
//
// 与 reference/task007_frame_buffer/sdram_clk_gen.v (125MHz) 同拓扑, 仅把
// C1/C2 分频从 8 改为 20, 输出 50MHz 0°/180° (相位推导不变):
//   F_VCO = FIN × FBCLK_DIV × CLKC0_DIV = 50MHz × 2 × 10 = 1000MHz
//   C1 = 1000/20 = 50MHz, CPHASE=19 (CDIV-1)    -> 0°  控制逻辑时钟
//   C2 = 1000/20 = 50MHz, CPHASE=9  (CDIV/2-1)  -> 180° 原语采样时钟
//
// 为什么 Task 010 降频(不修改冻结的 Task007/005 依赖):
//   本任务数据通路含 640 宽帧的 (H-1-y)*320 地址乘法(MULT18, Task007 上板
//   验证的是 1280 宽 = ×640 纯移位, 无此锥)与 BRAM 输出寄存, ctrl_clk=
//   125MHz 时 setup WNS=-4.056ns(10条违例)。50MHz 时预算 20ns, 最差实测
//   路径 ~16ns, 全部自然收敛; 双相 hold 架构(半周期裕量 10ns)同样成立。
//   吞吐: 读回 12 点 + 流式加载(受 converter 单字节处理节流限制, 与时钟
//   频率弱相关), 50MHz 远超 640x480@60Hz 显示带宽需求(对本任务够用)。
//
// 刷新: tREFI 15.625us @50MHz = 781 拍, 由 loader 以 REF_INTERVAL_CYCLES=781
//   参数透传给 sdram_frame_buffer(默认 1953 是 125MHz 值, 必须覆盖)。
// ============================================================================
module sdram_clk_gen_50m (
    input  wire ref_clk,      // 50MHz板载参考时钟(R7)
    input  wire pll_rst_n,    // PLL复位, 低有效
    output wire ctrl_clk,     // 50MHz 0°,  控制逻辑时钟
    output wire mem_clk,      // 50MHz 180°, 原语时钟
    output wire pll_locked    // PLL锁定输出(高=稳定)
);

`ifdef SIMULATION
    // 仿真行为模型: 两路独立always生成50MHz方波, 起始互补保证精确180°相差
    reg sim_ctrl_clk = 1'b0;
    reg sim_mem_clk  = 1'b1;   // 起始与ctrl_clk互补 -> 相差半周期
    reg sim_locked   = 1'b0;

    always #10 sim_ctrl_clk = ~sim_ctrl_clk;
    always #10 sim_mem_clk  = ~sim_mem_clk;

    initial begin
        sim_locked = 1'b0;
        #200;                  // 模拟PLL锁定时间
        sim_locked = 1'b1;
    end

    assign ctrl_clk   = sim_ctrl_clk;
    assign mem_clk    = sim_mem_clk;
    assign pll_locked = sim_locked;
`else
    wire clk0_buf;
    wire clk0_fb;

    // C0: 100MHz反馈专用(官方拓扑), C1: 50MHz 0°, C2: 50MHz 180°
    wire [7:0] open_do_bus;
    wire       open_psdone_w;
    wire       open_c3_w;
    wire       open_c4_w;

    EG_LOGIC_BUFG u_fb_bufg (
        .i (clk0_buf),
        .o (clk0_fb)
    );

    EG_PHY_PLL #(
        .DPHASE_SOURCE ("DISABLE"),
        .DYNCFG        ("DISABLE"),
        .FIN           ("50.000000"),
        .FEEDBK_MODE   ("NORMAL"),
        .FEEDBK_PATH   ("CLKC0_EXT"),
        .STDBY_ENABLE  ("DISABLE"),
        .PLLRST_ENA    ("ENABLE"),
        .SYNC_ENABLE   ("DISABLE"),
        .GMC_GAIN      (4),
        .ICP_CURRENT   (29),
        .KVCO          (4),
        .LPF_CAPACITOR (1),
        .LPF_RESISTOR  (2),
        .REFCLK_DIV    (1),
        .FBCLK_DIV     (2),
        .CLKC0_ENABLE  ("ENABLE"),
        .CLKC0_DIV     (10),
        .CLKC0_CPHASE  (9),
        .CLKC0_FPHASE  (0),
        .CLKC1_ENABLE  ("ENABLE"),
        .CLKC1_DIV     (20),
        .CLKC1_CPHASE  (19),
        .CLKC1_FPHASE  (0),
        .CLKC2_ENABLE  ("ENABLE"),
        .CLKC2_DIV     (20),
        .CLKC2_CPHASE  (9),
        .CLKC2_FPHASE  (0)
    ) u_pll (
        .refclk   (ref_clk),
        .reset    (~pll_rst_n),
        .stdby    (1'b0),
        .extlock  (pll_locked),
        .load_reg (1'b0),
        .psclk    (1'b0),
        .psdown   (1'b0),
        .psstep   (1'b0),
        .psclksel (3'b000),
        .psdone   (open_psdone_w),
        .dclk     (1'b0),
        .dcs      (1'b0),
        .dwe      (1'b0),
        .di       (8'd0),
        .daddr    (6'd0),
        .do       (open_do_bus),
        .fbclk    (clk0_fb),
        .clkc     ({open_c4_w, open_c3_w, mem_clk, ctrl_clk, clk0_buf})
    );
`endif

endmodule
