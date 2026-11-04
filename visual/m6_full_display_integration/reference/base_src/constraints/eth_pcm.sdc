# ============================================================================
# eth_pcm.sdc — task_052 时钟约束 (TD 6.2, EG4S20BG256)
#
# 时钟架构(三域):
#   clk_50 (板载 50MHz 晶振 R7, period 20ns)
#     -> u_core/u_pll_tx/u_pll (EG_PHY_PLL, FIN=50)
#          -> tx_clk_125 : 125MHz 0°   TEMAC 发送半 / TX 排空机
#          -> tx_clk_90  : 125MHz 90°  仅驱动 phy1_rgmii_tx_clk 引脚
#          -> app_clk    : 25MHz       全部应用逻辑: 发包机 / 收包机 / 记录 FIFO /
#                          统计 / LED / dled / epoch / 离线计时
#   phy1_rgmii_rx_clk (PHY 恢复出的 125MHz RXC, T14)
#     -> u_core/u_pll_rx/u_pll (EG_PHY_PLL, FIN=125)
#          -> rx_clk_0   : 125MHz 0°   默认 IDDR 采样相位(见 §采样相位)+ RX 捕获机
#          -> rx_clk_90  : 125MHz 90°  备选采样相位(RX_PHASE=90 的那颗 bit 用)
#
# 为什么把应用侧搬到 25MHz(结构调整, 不是约束技巧):
#   实测 125MHz 下应用逻辑的最差路径是 byte_idx -> 包内字节译码(索引算术 + 载荷
#   图形混合 + 大 mux) -> CRC32, 8~9 级逻辑, rx_clk 域 WNS -2.939ns、tx_clk_125
#   域 WNS -1.488ns, 也就是应用逻辑本身 Fmax 只有约 91~105MHz。而这条链路的业务
#   量级只有约 112 字节/ms(48k 样本/s => 375 包/s x 306B ≈ 114,750 字节/s), 用
#   40ns 一拍跑应用侧绰绰有余。于是发包机/收包机/统计全部搬到 app_clk, MAC 两侧
#   仍是 125MHz, 中间只隔两个 512 深的字节 FIFO。违例从根上消失, 不需要放宽约束。
#
# 异步关系与豁免理由(TD 不支持 set_clock_groups, USR-8159, 按显式时钟对声明):
#   1) tx_clk_* / app_clk <-> rx_clk_0: 两个参考源本身异步(本板晶振 vs PHY 恢复
#      时钟)。app<->rx 之间只剩两类结构: 字节 FIFO 的灰码指针 2FF、rxc 翻转沿与
#      rx_locked 单 bit 2FF。=> 双向 false path, 不参与 STA。
#   2) phy1_rgmii_rx_clk(引脚) <-> clk_50: 同上, 该引脚时钟只进 u_pll_rx。
#   3) tx_clk_125 / tx_clk_90 / app_clk 两两之间: 同一 PLL 的三个输出(C0/C1 反馈、
#      C1 0°、C2 90°、C3 分频 40), 是同源同步关系, 不設任何豁免, 由 derive_clocks
#      真实分析 —— 字节 FIFO 两侧的指针与数据就是走这条关系, 一旦这里被豁免掉,
#      FIFO 的跨域连线就完全没有 STA 覆盖了。
#   4) clk_50 <-> tx_clk_125/app_clk/rx_clk_*: 同源或晶振到 PLL 的关系, 不豁免。
#      ethm_link_core 现在只让"引脚/PLL lock 脚"做异步断言, boot_hold(clk_50 域
#      寄存器)先在各域各取两拍再当释放门用 => clk_50 到各域只剩 2FF 同步器的
#      第一级这一类真实路径, 按同步关系分析即可, 不需要也不应该在这里加豁免。
#
# 未约束路径(必须如实报告, 不得声称已被 STA 覆盖):
#   * RGMII 12 个引脚没有 set_input_delay / set_output_delay。理由:
#     - 本包需要 PHY 侧 RXC/TXC 内部延迟 strap 的实测数值(见 LINK_REPORT §E0
#       开放项), 在这些数值核实前写延迟约束会造出"假的通过"或"假的违例";
#     - 主线历史基线(043 及官方例程 SDC)同样未含 IO 延迟约束, 本包不新增
#       无法自证的约束项。
#     => 采样窗口的真实证据来自上板: 30 分钟双向连续 + CRC/序号/溢出为 0,
#        以及 rx_pll 90° 中心移相的相位预算分析(LINK_REPORT §相位预算)。
#   * 灰码指针/2FF 同步器路径被豁免(见上), 由结构保证正确性, 不由 STA 保证。
# ============================================================================

# ---- 板级与 PHY 侧输入主时钟 ----
# R7 实际是 50MHz 晶振(task_043 主线在板上按 period 20 长期验证; PLL 生成文件
# FIN="50.000000" 亦为 50MHz)。官方两份以太网例程的 SDC 把 R7 写成 period 40
# (=25MHz), 相当于把 125MHz 逻辑的约束放松了 2 倍, 其报告的正裕量不可信;
# 本包按真实 50MHz 约束, 因此 WNS 会显著变差, 这是修正而不是退化。
create_clock -name clk_50             -period 20 -waveform {0 10} [get_ports {clk_50}]
create_clock -name phy1_rgmii_rx_clk  -period 8  -waveform {0 4}  [get_ports {phy1_rgmii_rx_clk}]

# ---- 推导 PLL 输出时钟并命名 ----
derive_clocks
rename_clock -name {tx_clk_125} [get_clocks {u_core/u_pll_tx/u_pll.clkc[1]}]
rename_clock -name {tx_clk_90}  [get_clocks {u_core/u_pll_tx/u_pll.clkc[2]}]
rename_clock -name {app_clk}    [get_clocks {u_core/u_pll_tx/u_pll.clkc[3]}]
rename_clock -name {rx_clk_0}   [get_clocks {u_core/u_pll_rx/u_pll.clkc[0]}]
# rx_clk_90 只在 RX_PHASE=90 的对照 bit 里存在: 相位为 0° 时 90° 那一路没有负载,
# 会被综合剪掉, 此时 rename 它会报 USR-8130/8159 伪告警。对照 bit 请改用
# constraints/eth_pcm_rx90.sdc(仅本段与下面的豁免对换名), 不要在共用的本文件里
# 同时引用两路。

# ---- 异步时钟对豁免(理由见文件头) ----
# rx 域与本片晶振域异步: tx 侧两路 + app 侧一路, 与 rx_clk_0 双向各一条。
set_false_path -from [get_clocks {tx_clk_125}] -to [get_clocks {rx_clk_0}]
set_false_path -from [get_clocks {rx_clk_0}]   -to [get_clocks {tx_clk_125}]
set_false_path -from [get_clocks {app_clk}]    -to [get_clocks {rx_clk_0}]
set_false_path -from [get_clocks {rx_clk_0}]   -to [get_clocks {app_clk}]
# 注意: app_clk 与 tx_clk_125 / tx_clk_90 同出本板 PLL(REFCLK 都是 clk_50), 是
# 同源关系, 绝对不要在这里补 false_path —— 字节 FIFO 两侧的指针同步与数据通路
# 全走这条关系, 豁免掉就等于让跨域结构失去 STA 覆盖。
# rx_clk_0 与 rx_clk_90 同源于 u_pll_rx, 未被选中的那一路不驱动任何负载;
# 两者之间不设豁免, 以免掩盖"两路都被用到"时的真实跨相路径。
set_false_path -from [get_clocks {phy1_rgmii_rx_clk}] -to [get_clocks {clk_50}]
set_false_path -from [get_clocks {clk_50}]           -to [get_clocks {phy1_rgmii_rx_clk}]

# ---- 板级准静态输入: 按键与拨码 ----
# key1 是异步断言复位源(释放侧在两个域各经 2FF 同步), key2/key3 与 sw[3:0]
# 先 2FF 同步再 2ms 去抖; 端口到首级同步器不构成真实时序路径(task_043 同口径)。
set_false_path -from [get_ports {key1}]
set_false_path -from [get_ports {key2}]
set_false_path -from [get_ports {key3}]
set_false_path -from [get_ports {sw[0]}]
set_false_path -from [get_ports {sw[1]}]
set_false_path -from [get_ports {sw[2]}]
set_false_path -from [get_ports {sw[3]}]
