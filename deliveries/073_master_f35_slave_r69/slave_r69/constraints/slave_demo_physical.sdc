# 原dual_fft062_top的50MHz时钟与不确定度约束保持不变。
create_clock -name clk_50 -period 20.000 -waveform {0 10.000} [get_ports {clk_50}]
set_clock_uncertainty -setup 2.000 [get_clocks {clk_50}]
set_clock_uncertainty -hold 0.050 [get_clocks {clk_50}]

# 异步串行/麦克风数据仅放宽到其第一级同步器，后续级与数据路径仍受STA覆盖。
set_false_path -from [get_ports {key1}] -to [get_regs {key1_meta}]
set_false_path -from [get_ports {key2}] -to [get_regs {u_key2_debounce/button_sync0}]
set_false_path -from [get_ports {link_rx_data}] -to [get_regs {u_demo/u_pcm_rx/u_transport/s0}]
set_false_path -from [get_ports {mic_sd[0]}] -to [get_regs {u_demo/u_mic_capture/mic_sd_meta[0]}]
set_false_path -from [get_ports {mic_sd[1]}] -to [get_regs {u_demo/u_mic_capture/mic_sd_meta[1]}]
set_false_path -from [get_ports {mic_sd[2]}] -to [get_regs {u_demo/u_mic_capture/mic_sd_meta[2]}]
set_false_path -from [get_ports {mic_sd[3]}] -to [get_regs {u_demo/u_mic_capture/mic_sd_meta[3]}]

# KEY1异步复位到reset rail的recovery/removal未豁免；新增I2S clocks均由clk_50时钟使能生成。

# R46新异步输入只到各自第一级同步器；原时钟与门禁不变。
set_false_path -from [get_ports {key3}] -to [get_regs {u_key3_debounce/button_sync0}]
set_false_path -from [get_ports {key4}] -to [get_regs {u_key4_debounce/button_sync0}]
set_false_path -from [get_ports {sw[0]}] -to [get_regs {u_panel/sw_meta[0]}]
set_false_path -from [get_ports {sw[1]}] -to [get_regs {u_panel/sw_meta[1]}]
set_false_path -from [get_ports {sw[2]}] -to [get_regs {u_panel/sw_meta[2]}]
set_false_path -from [get_ports {sw[3]}] -to [get_regs {u_panel/sw_meta[3]}]
