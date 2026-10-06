`timescale 1ns / 1ps
// ============================================================================
// video_timing_data — 640x480@60 (VIC=1) 视频同步/使能时序发生器
//
// 功能: 在像素时钟域产生 VS/HS/DE 三个显示时序信号。DE 只在有效视频区
//   为高, 其余为低; HS/VS 采用负极性(同步期间为低)。
//
// 时序参数 (VIC=1, 与加密 IP 参数一致):
//   HTOTAL=800, HSA=96, HBP=48, HACTIVE=640, HFP=16
//   VTOTAL=525, VSA=2,  VBP=33, VACTIVE=480, VFP=10
//
// 行内布局 (水平像素计数 hcnt):
//   [        0        |  96   |   48    |    640    |  16  ]
//   hcnt:   0..799, total = 800
//     hs_sync : hcnt < 96            (负极性低有效)
//     h_back  : 96 <= hcnt < 144
//     active  : 144 <= hcnt < 784    (DE 高)
//     h_front : hcnt >= 784
// 帧内布局 (行计数 vcnt):
//   [      0       |  2   |   33   |    480    |  10 ]
//   vcnt:   0..524, total = 525
//     vs_sync : vcnt < 2             (负极性低有效)
//     v_back  : 2 <= vcnt < 35
//     active  : 35 <= vcnt < 515     (有效视频行)
//     v_front : vcnt >= 515
//
// 设计说明:
//   * 计数在像素时钟上升沿推进, 复位后从 0 重新开始, 周期无断点。
//   * 输出(HS/VS/DE)由当前计数组合产生, 无额外打拍延迟, 与加密 IP
//     输入侧对像素流时序的预期一致。
// ============================================================================
module video_timing_data (
    input  wire        I_clk,          // pixel clock
    input  wire        I_rst,          // 高有效, 同步复位
    output wire        O_hs,           // 行同步 (负极性)
    output wire        O_vs,           // 帧同步 (负极性)
    output wire        O_de            // 数据使能 (有效视频区为高)
);

    localparam integer HTOTAL   = 800;
    localparam integer HSA      = 96;
    localparam integer HBACKEND = 48;   // 后肩, 使能区起点 = HSA+HBACKEND
    localparam integer HACTIVE  = 640;
    localparam integer HSTART   = HSA + HBACKEND;          // 144
    localparam integer HEND     = HSTART + HACTIVE;        // 784

    localparam integer VTOTAL   = 525;
    localparam integer VSA      = 2;
    localparam integer VBACKEND = 33;   // 后肩, 有效行起点 = VSA+VBACKEND
    localparam integer VACTIVE  = 480;
    localparam integer VSTART   = VSA + VBACKEND;          // 35
    localparam integer VEND     = VSTART + VACTIVE;        // 515

    reg [ 9:0] S_hcnt;                 // 0..799   (宽度容纳 HTOTAL-1)
    reg [ 9:0] S_vcnt;                 // 0..524   (宽度容纳 VTOTAL-1)

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            S_hcnt <= 10'd0;
            S_vcnt <= 10'd0;
        end else begin
            if (S_hcnt == HTOTAL - 1) begin
                S_hcnt <= 10'd0;
                if (S_vcnt == VTOTAL - 1)
                    S_vcnt <= 10'd0;
                else
                    S_vcnt <= S_vcnt + 10'd1;
            end else begin
                S_hcnt <= S_hcnt + 10'd1;
            end
        end
    end

    assign O_hs = (S_hcnt >= HSA);        // 低有效: 同步段为低
    assign O_vs = (S_vcnt >= VSA);        // 低有效: 同步段为低
    assign O_de = (S_hcnt >= HSTART) && (S_hcnt < HEND) &&
                  (S_vcnt >= VSTART) && (S_vcnt < VEND);

endmodule