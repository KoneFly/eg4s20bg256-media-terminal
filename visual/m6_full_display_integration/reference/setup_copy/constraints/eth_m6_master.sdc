# 第四步保留已验网口约束，增加显示域异步握手的第一同步级入口。
create_clock -name clk_50 -period 20 -waveform {0 10} [get_ports {clk_50}]
create_clock -name phy1_rgmii_rx_clk -period 8 -waveform {0 4} [get_ports {phy1_rgmii_rx_clk}]
derive_clocks
set_false_path -from [get_ports {key1}]
set_false_path -from [get_ports {key2}]
set_false_path -from [get_ports {key3}]
set_false_path -from [get_clocks {phy1_rgmii_rx_clk}] -to [get_clocks {clk_50}]
set_false_path -from [get_clocks {clk_50}] -to [get_clocks {phy1_rgmii_rx_clk}]
# 只有第一同步级；meta->sync及确认后描述符采样均正常STA。
set_false_path -from [get_regs {u_display/u_snapshot/request_toggle}] -to [get_regs {u_display/u_snapshot/request_meta}]
set_false_path -from [get_regs {u_display/u_snapshot/ack_toggle}] -to [get_regs {u_display/u_snapshot/ack_meta}]
# 源寄存器可能被合并到front_bank，限定源域及三个第一同步级，避免引用消失的别名。
set_false_path -from [get_clocks {clk_50}] -to [get_regs {u_display/u_snapshot/descriptor_meta[0]}]
set_false_path -from [get_clocks {clk_50}] -to [get_regs {u_display/u_snapshot/descriptor_meta[1]}]
set_false_path -from [get_clocks {clk_50}] -to [get_regs {u_display/u_snapshot/descriptor_meta[2]}]
set_false_path -from [get_clocks {u_display/u_pll/u_video_pll.clkc[0]}] -to [get_regs {u_display/locked_meta}]
