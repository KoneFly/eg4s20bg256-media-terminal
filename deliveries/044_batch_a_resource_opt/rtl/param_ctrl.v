`timescale 1ns / 1ps
// ============================================================================
// param_ctrl — 拨码参数输入: 同步/去抖/档位映射/vsync 边界锁存
//               (task_040 自研, pixel 域 25.2MHz 单时钟域, 无 CDC)
//
// 功能: 板载拨码开关 SW1~SW4(引脚 C8/C7/C6/C5, 电平输入, 拨上=1) -> 调节
//   亮度/对比度档位, 并保证参数只在 vsync 边界生效(帧内恒定, 防画面撕裂):
//
//   * 档位映射(PARAM_SPEC §4, 低位开关=LSB):
//       亮度 = {SW2,SW1}: 档 0..3 -> 偏移 {+0,+32,+64,+96}(BRI_OFF_Gx 参数),
//                          档 0 为默认(上电/复位后);
//       对比度 = {SW4,SW3}: 档 0..3 -> {x0.0, x1.0, x1.5, x2.0}(128 锚定),
//                          档 1(x1.0) 为默认。
//     档位 -> 物理值译码在本模块完成(pixel_adjust 只收偏移/档码, 保持通用,
//     可被 TB 直接驱动负偏移验证封底)。
//
//   * 同步 + 去抖: 2FF 同步防亚稳态 + 每位 20ms 稳定确认(结构同构主线
//     key_press_debounce/task_027, 已登记台账); 拨码机械抖动 < 20ms 时
//     只认一次变化。
//
//   * 基线捕获: 复位后 2 倍消抖时长(40ms)内的电平只更新消抖基线、不产生
//     变更事件 —— 上电/复位后无论拨码停在何位, 参数保持默认值, 须拨动
//     才生效(边界场景 7"复位中途参数回默认"的保证; 亦避免上电即套用
//     拨码静态位)。
//
//   * vsync 边界生效: 去抖确认只更新 pend(待生效)档位; I_vs 下降沿
//     (帧首, 与 res_caption 帧计数同拍)时若 pend 与生效档不同才换装,
//     并输出 O_param_upd 单拍脉冲(与换装同拍, 供 param_osd 触发显示)。
//     帧内拨码再怎么动都不影响本帧像素。
//
// 端口契约:
//   I_sw[3:0] = {SW4,SW3,SW2,SW1} 板级电平(异步输入, 本模块负责同步);
//   I_vs      负极性场同步(下降沿=帧首, video_timing_data 同源);
//   O_bri_gear/O_con_gear   生效档位码(2bit, 帧内恒定, OSD 显示用);
//   O_bri_off[7:0]          生效亮度偏移(two's complement, 帧内恒定);
//   O_con_sel[1:0]          生效对比度档(= O_con_gear, pixel_adjust 档码);
//   O_param_upd             换装拍单拍脉冲(帧首域内)。
// ============================================================================
module param_ctrl #(
    parameter integer CLK_HZ      = 25_200_000,  // pixel_clk
    parameter integer DEBOUNCE_MS = 20,          // 拨码消抖时长
    parameter [7:0]   BRI_OFF_G0  = 8'd0,        // 亮度档 0 偏移(默认档)
    parameter [7:0]   BRI_OFF_G1  = 8'd32,       // 档 1
    parameter [7:0]   BRI_OFF_G2  = 8'd64,       // 档 2
    parameter [7:0]   BRI_OFF_G3  = 8'd96        // 档 3(拉满)
)(
    input  wire       I_clk,
    input  wire       I_rst,         // 高有效异步复位
    input  wire [3:0] I_sw,          // {SW4,SW3,SW2,SW1} 拨上=1
    input  wire       I_vs,          // 负极性, 下降沿=帧首
    output wire [7:0] O_bri_off,     // 生效亮度偏移(two's complement)
    output wire [1:0] O_con_sel,     // 生效对比度档(= O_con_gear)
    output reg  [1:0] O_bri_gear,    // 生效亮度档位码(OSD 显示)
    output reg  [1:0] O_con_gear,    // 生效对比度档位码(OSD 显示)
    output reg        O_param_upd    // vsync 换装拍单拍脉冲
);

    localparam integer DB_CYC   = (CLK_HZ / 1000) * DEBOUNCE_MS; // 20ms@25.2M=504000
    localparam integer BASE_CYC = DB_CYC * 2;                    // 基线窗 40ms

    // ========================================================================
    // 2FF 同步(板级异步电平 -> pixel 域)
    // ========================================================================
    reg [3:0] sw_s0, sw_s1;
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            sw_s0 <= 4'd0;
            sw_s1 <= 4'd0;
        end else begin
            sw_s0 <= I_sw;
            sw_s1 <= sw_s0;
        end
    end

    // ========================================================================
    // 每位消抖: 稳定 DB_CYC 才确认(同构 key_press_debounce 结构)
    // ========================================================================
    wire [3:0] db_confirm;
    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : G_DB
            reg        stb;                 // 消抖基线(复位=0, 拨下电平)
            reg [23:0] cnt;                 // 24bit 覆盖任意合理 CLK_HZ/MS
            always @(posedge I_clk or posedge I_rst) begin
                if (I_rst) begin
                    stb <= 1'b0;
                    cnt <= 24'd0;
                end else if (sw_s1[g] == stb) begin
                    cnt <= 24'd0;        // 与基线一致: 无变化
                end else if (cnt >= DB_CYC - 1) begin
                    cnt <= 24'd0;        // 稳定达消抖时长: 确认换基线
                    stb <= sw_s1[g];
                end else begin
                    cnt <= cnt + 24'd1;
                end
            end
            assign db_confirm[g] = (sw_s1[g] != stb) && (cnt >= DB_CYC - 1);
        end
    endgenerate

    // ========================================================================
    // 基线捕获窗: 复位后 BASE_CYC 内的确认只换基线, 不产生变更事件
    // ========================================================================
    reg  [23:0] base_cnt;
    wire        in_base = (base_cnt < BASE_CYC);
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst)      base_cnt <= 24'd0;
        else if (!in_base) base_cnt <= base_cnt;   // 饱和于 BASE_CYC
        else            base_cnt <= base_cnt + 24'd1;
    end

    wire [3:0] sw_evt  = db_confirm & {4{~in_base}};   // 窗外确认才是变更
    wire       any_evt = |sw_evt;

    // ========================================================================
    // 待生效档位(去抖确认即更新; 默认 bri=档0, con=档1)
    // ========================================================================
    reg [1:0] pend_bri, pend_con;
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            pend_bri <= 2'd0;
            pend_con <= 2'd1;
        end else if (any_evt) begin
            pend_bri <= sw_s1[1:0];  // {SW2,SW1}
            pend_con <= sw_s1[3:2];  // {SW4,SW3}
        end
    end

    // ========================================================================
    // vsync 边界换装(帧内恒定的唯一写点) + 换装脉冲
    // ========================================================================
    reg  vs_d;
    wire vs_fall = vs_d & ~I_vs;

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            vs_d        <= 1'b1;         // 负极性空闲态(同 res_caption)
            O_bri_gear  <= 2'd0;         // 默认档: 亮度 +0
            O_con_gear  <= 2'd1;         // 默认档: 对比度 x1.0
            O_param_upd <= 1'b0;
        end else begin
            vs_d        <= I_vs;
            O_param_upd <= 1'b0;         // 单拍脉冲默认清零
            if (vs_fall && ({pend_con, pend_bri} != {O_con_gear, O_bri_gear})) begin
                O_bri_gear  <= pend_bri;
                O_con_gear  <= pend_con;
                O_param_upd <= 1'b1;
            end
        end
    end

    // 档位码 -> 偏移译码(常量查表, 无运算; 与 O_bri_gear 换装同拍一致)
    reg [7:0] bri_off_c;
    always @(*) begin
        case (O_bri_gear)
            2'd0:    bri_off_c = BRI_OFF_G0;
            2'd1:    bri_off_c = BRI_OFF_G1;
            2'd2:    bri_off_c = BRI_OFF_G2;
            default: bri_off_c = BRI_OFF_G3;
        endcase
    end
    assign O_bri_off = bri_off_c;
    assign O_con_sel = O_con_gear;                     // 档码即 pixel_adjust 档码

endmodule
