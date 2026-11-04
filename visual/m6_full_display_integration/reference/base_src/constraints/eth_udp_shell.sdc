# v7 空壳时钟约束：真实板载 50MHz 与 PHY RGMII RXC 125MHz。
create_clock -name clk_50 -period 20 -waveform {0 10} [get_ports {clk_50}]
create_clock -name phy1_rgmii_rx_clk -period 8 -waveform {0 4} [get_ports {phy1_rgmii_rx_clk}]
derive_clocks
set_false_path -from [get_ports {key1}]
set_false_path -from [get_ports {key2}]
set_false_path -from [get_ports {key3}]
set_false_path -from [get_clocks {phy1_rgmii_rx_clk}] -to [get_clocks {clk_50}]
set_false_path -from [get_clocks {clk_50}] -to [get_clocks {phy1_rgmii_rx_clk}]
