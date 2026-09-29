# ============================================================================
# m1a_top.sdc — 时钟时序约束 (TD, EG4S20BG256)
#
# 时钟架构(与 Task 019 蓝本一致, 新增域均为 ctrl 域内低速逻辑):
#   clk_50m (50MHz 板载晶振 R7)
#     -> u_sdram_pll/u_pll (EG_PHY_PLL, Task 012 V3 同配置)
#          -> ctrl_clk : 50MHz 0°   (控制逻辑: SD/003/009/loader/加载FSM/
#                                    fetch 引擎/FIFO 写侧)
#          -> mem_clk  : 50MHz 180° (EG_PHY_SDRAM_2M_32 原语采样时钟)
#     -> u_hdmi_pll/u_video_pll (EG_PHY_PLL×2, Task 011 同配置)
#          -> pixel_clk  : 25.2MHz  (视频时序/AXIS源/FIFO 读侧)
#          -> serial_clk : 126MHz   (TMDS 10:1 串化)
#          -> audio_mclk : 12.3077MHz (task_032 返工: audio_i2s_bridge 的
#                             i2s_master 负载, 音频投递节拍主时钟)
#
# 跨时钟域说明(Task 019 同口径):
#   1. ctrl_clk <-> mem_clk: 双相采样架构设计意图(同 Task 012), 原语端口
#      路径声明 false path(工具对原语硬核端口建模的伪违例)。
#   2. ctrl/mem <-> pixel: 异步 CDC, 跨域路径仅两类标准同步结构: 异步 FIFO
#      灰码指针(2FF 同步器)与 VS 下降沿单拍脉冲(2FF 同步)。SD/TF 四线
#      (sd_*)为 ctrl 域同步输出、板级无返回路径, 不构成跨域。
#   3. pixel_clk -> serial_clk: 5x 倍频同步关系(lane_lvds_10_1 内两级同步器
#      + 装载使能), 由 derive_clocks 推导关系直接分析, 不设例外(同 Task 011)。
#   4. audio_mclk <-> pixel: 音频 I2S 投递链的异步 CDC(帧 FIFO 格雷码指针 +
#      准静态电平 2FF + 官方 I2S_receiver 三拍同步器), 见文末显式豁免。
# ============================================================================

# ---- 板级输入主时钟 ----
create_clock -name clk_50m -period 20 -waveform {0 10} [get_ports {clk_50m}]

# ---- 自动推导 PLL 输出时钟 ----
derive_clocks
rename_clock -name {ctrl_clk}  [get_clocks {u_sdram_pll/u_pll.clkc[1]}]
rename_clock -name {mem_clk}   [get_clocks {u_sdram_pll/u_pll.clkc[2]}]
rename_clock -name {pixel_clk} [get_clocks {u_hdmi_pll/u_video_pll.clkc[0]}]
rename_clock -name {serial_clk}[get_clocks {u_hdmi_pll/u_video_pll.clkc[1]}]
rename_clock -name {audio_mclk} [get_clocks {u_hdmi_pll/u_audio_pll.clkc[0]}]

# ---- 原语端口跨域伪违例豁免(Task 012 同口径) ----
set_false_path -from [get_clocks {ctrl_clk}] -to [get_clocks {mem_clk}]
# [task_026 V0] 本行 mem_clk->ctrl_clk 豁免已删除: 读回 DQ 改由 sdram_clk 域预捕获一级后,
#   该跳成为同时钟域出发的正常同步路径, 必须留在 STA 覆盖内(见 sdram_frame_buffer.v 的 dq_m)。
# ---- ctrl/mem 与 pixel 跨域路径豁免(Task 019 同口径) ----
# 跨域路径仅异步 FIFO 灰码指针与 VS 脉冲两类 2FF 同步结构;
# TD 不支持 set_clock_groups(USR-8159), 按显式时钟对声明 false path。
set_false_path -from [get_clocks {ctrl_clk}]  -to [get_clocks {pixel_clk}]
set_false_path -from [get_clocks {pixel_clk}] -to [get_clocks {ctrl_clk}]
set_false_path -from [get_clocks {mem_clk}]   -to [get_clocks {pixel_clk}]
set_false_path -from [get_clocks {pixel_clk}] -to [get_clocks {mem_clk}]

# ---- [task_032 返工] audio_mclk 域 (12.3077MHz) ----
# audio_i2s_bridge 使 audio_mclk 首次承担真实负载(i2s_master), 此前为空载预留。
# 与像素域的跨域路径全部为设计意图内的标准同步结构, 共三类:
#   1. audio_frame_fifo 读/写指针: 格雷码 + 各域 2FF 同步(异步 FIFO);
#   2. 预充门控 primed_req(像素→mclk) 与 fifo_empty(mclk→像素): 准静态电平 2FF;
#   3. i2s_master 的 BCLK/LRCK/DOUT(mclk 域寄存器) → 官方 I2S_receiver 三拍
#      同步器(像素域), 与官方 lab_ex5_i2s / task_021 完全同构。
# 无 ctrl/mem 与 mclk 之间的逻辑路径, 故不声明该两对(避免掩盖真实违例)。
set_false_path -from [get_clocks {pixel_clk}]  -to [get_clocks {audio_mclk}]
set_false_path -from [get_clocks {audio_mclk}] -to [get_clocks {pixel_clk}]
