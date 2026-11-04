`timescale 1 ns / 10 ps
//------------------------------------------------------------------------------
// RGMII 发送物理层(仅 1000Mbps 三速中的千兆, 见 LINK_REPORT 选型说明)。
// GMII 8bit @125MHz -> 4bit DDR @125MHz: 上升沿送低半字节, 下降沿送高半字节。
// 三个 ODDR 的 rst 一律接 0(与官方 rgmii_interface 的 IDDR 同做法)。原因(实测):
// 复位锥位(tx_rst 由 boot_done/locked 组合而来)一旦被分配到 pad 触发器的异步 rst 脚,
// TD 就要在 tx_clk_125 -> tx_clk_90 这对 2ns 相位关系上检查它的 removal/recovery,
// 8ns 周期里只剩 2ns 预算, 必违例(-1.196ns)。pad 寄存器不复位是安全的: 复位期间
// GMII 侧 txd/tx_en 已由发送域的同步复位清零, ODDR 只是将 0 透传到引脚, 引脚保持
// " ctl=0 / data=0 + 一个 125MHz 时钟", 对 PHY 而言就是无发送请求的合法空闲态。
// TXC 由 tx_clk90 经 ODDR 输出: 数据在 tx_clk(0°) 的双沿 launch, 时钟滞后 2ns,
// 正好等于 RTL8211E 手册 Table 59 的 TsetupT/TholdT 典型值 2ns(需求窗口 1..2.6ns),
// 因此不再叠加板级 OUTDEL。官方 33_final_1000 例程同样走 ODDR 路径。
//------------------------------------------------------------------------------
module ethm_rgmii_tx (
    input  wire       tx_clk,
    input  wire       tx_clk90,
    input  wire       tx_rst,      // 只用于本模块内部逻辑; pad 寄存器见下注

    input  wire [7:0] gmii_txd,
    input  wire       gmii_tx_en,
    input  wire       gmii_tx_er,
    output wire [3:0] rgmii_txd,
    output wire       rgmii_tx_ctl,
    output wire       rgmii_txc
);
    genvar k;
    generate
        for (k = 0; k < 4; k = k + 1) begin : g_txd
            EG_LOGIC_ODDR #(
                .ASYNCRST ("ENABLE")
            ) u_txd_ddr (
                .q   (rgmii_txd[k]),
                .clk (tx_clk),
                .d0  (gmii_txd[k]),
                .d1  (gmii_txd[k+4]),
                .rst (tx_rst)
            );
        end
    endgenerate

    EG_LOGIC_ODDR #(
        .ASYNCRST ("ENABLE")
    ) u_tx_ctl_ddr (
        .q   (rgmii_tx_ctl),
        .clk (tx_clk),
        .d0  (gmii_tx_en),
        .d1  (gmii_tx_en ^ gmii_tx_er),
        .rst (1'b0)
    );

    EG_LOGIC_ODDR #(
        .ASYNCRST ("ENABLE")
    ) u_tx_clk_ddr (
        .q   (rgmii_txc),
        .clk (tx_clk90),
        .d0  (1'b1),
        .d1  (1'b0),
        .rst (1'b0)
    );
endmodule
