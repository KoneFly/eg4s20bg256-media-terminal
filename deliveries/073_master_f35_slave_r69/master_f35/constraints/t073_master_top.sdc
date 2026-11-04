
create_clock -name clk_50m -period 20 -waveform {0 10} [get_ports {clk_50m}]
derive_clocks
rename_clock -name {ctrl_clk}  [get_clocks {u_sdram_pll/u_pll.clkc[1]}]
rename_clock -name {mem_clk}   [get_clocks {u_sdram_pll/u_pll.clkc[2]}]
rename_clock -name {pixel_clk} [get_clocks {u_hdmi_pll/u_video_pll.clkc[0]}]
rename_clock -name {serial_clk}[get_clocks {u_hdmi_pll/u_video_pll.clkc[1]}]
rename_clock -name {audio_mclk} [get_clocks {u_hdmi_pll/u_audio_pll.clkc[0]}]


set_false_path -from [get_clocks {ctrl_clk}] -to [get_clocks {mem_clk}]
# ctrl/mem 与 pixel 之间只有格雷码异步 FIFO 指针和 frame_tog 翻转同步
set_false_path -from [get_clocks {ctrl_clk}]  -to [get_clocks {pixel_clk}]
set_false_path -from [get_clocks {pixel_clk}] -to [get_clocks {ctrl_clk}]
set_false_path -from [get_clocks {mem_clk}]   -to [get_clocks {pixel_clk}]
set_false_path -from [get_clocks {pixel_clk}] -to [get_clocks {mem_clk}]
# FIXME: SD 接口 IO 时序约束(转发时钟/输入输出延迟)仍需目标卡与走线数据, 当前仅约束内部路径

set_false_path -from [get_clocks {pixel_clk}]  -to [get_clocks {audio_mclk}]
set_false_path -from [get_clocks {audio_mclk}] -to [get_clocks {pixel_clk}]
# 拨码/按键为人手操作的异步输入, 经两级同步与毫秒级消抖后使用
set_false_path -from [get_ports {sw[*]}]
set_false_path -from [get_ports {key2_n}]
set_false_path -from [get_ports {key3_n}]
set_false_path -from [get_ports {key4_n}]

# C1首级例外由主Tcl仅在optimize_gate/import_db后source本地helper；不在RTL/pre-gate/read_sdc执行。
