# ============================================================================
# td_full_flow.tcl — task_043 主线集成工程 TD 全流程 (非工程模式)
#   源文件清单 = 044 交付基线(866519aa) + [task_040] param 三件 + [task_043 P1]
#   line_supply 供数观测平面(直通+协议观测, 转场平面已随步② 失败位归档);
#   器件: EG4S20BG256 (eagle_s20.db); 顶层: m1a_top。
#   约束: adc 在 037 口径上新增拨码 sw[3:0](C8 起, 步① 返工序);
#         sdc 新增 sw 端口伪路径。P1 零新增引脚/时钟域。
# 运行: 于 td_run/ 目录启动 TD (LESSON-016 注意验证 SWNS 合理性)。
# ============================================================================
import_device eagle_s20.db -package EG4S20BG256
set_param flow qor_monitor on

# ---- 综合输入 ----
read_hdl -file {../rtl/sd_arbiter.v \
                ../rtl/wav_pcm_streamer.v \
                ../rtl/pcm16_to_pcm24.v \
                ../rtl/audio_src_mux.v \
                ../rtl/pcm_sel_vol.v \
                ../rtl/frame_fade_gain.v \
                ../rtl/key_press_debounce.v \
                ../rtl/sd_spi_byte_engine.v \
                ../rtl/crc7_calc.v \
                ../rtl/sd_cmd_transactor.v \
                ../rtl/sd_init_sequence.v \
                ../rtl/crc16_ccitt.v \
                ../rtl/sd_block_reader.v \
                ../rtl/sd_spi_command.v \
                ../rtl/mx_byte_engine.v \
                ../rtl/sd_spi_sector_reader.v \
                ../rtl/sd_sector_replay_buffer.v \
                ../rtl/fat32_volume_scanner.v \
                ../rtl/fat32_file_streamer.v \
                ../rtl/fat32_lite.v \
                ../rtl/rgb888_to_rgb565.v \
                ../rtl/bmp24_to_rgb565_converter.v \
                ../rtl/bmp_resampler.v \
                ../rtl/bmp_stream_align_shim.v \
                ../rtl/bmp_top_down_observer.v \
                ../rtl/bmp_row_order_adapter.v \
                ../rtl/sync_fifo.v \
                ../rtl/sdram_clk_gen_50m.v \
                ../rtl/sdram_refresh_timer.v \
                ../rtl/sdram_cmd_engine.v \
                ../rtl/sdram_frame_buffer.v \
                ../rtl/bmp_sdram_loader.v \
                ../rtl/display_fetch_engine.v \
                ../rtl/async_pixel_fifo.v \
                ../rtl/pixel_fifo_out.v \
                ../rtl/view_mapper.v \
                ../rtl/res_caption.v \
                ../rtl/param_ctrl.v \
                ../rtl/pixel_adjust.v \
                ../rtl/param_osd.v \
                ../rtl/line_supply.v \
                ../rtl/rgb565_to_rgb888.v \
                ../rtl/hdmi_pll.v \
                ../rtl/hdmi_phy_wrapper.v \
                ../rtl/lane_lvds_10_1.v \
                ../rtl/video_timing_data.v \
                ../rtl/audio_tone_gen.v \
                ../rtl/audio_i2s_bridge.v \
                ../rtl/audio_frame_fifo.v \
                ../rtl/i2s_master.v \
                ../rtl/I2S_receiver.v \
                ../rtl/audio_arc_calculate.v \
                ../rtl/m1a_top.v \
                ./hdmi_1_4b_transmitter_core_wrapper.enc.v} -top m1a_top
read_adc ../constraints/m1a_top.adc

# ---- RTL优化(综合) ----
optimize_rtl
report_area -file rtl.area

# ---- 门级优化 ----
read_sdc ../constraints/m1a_top.sdc
optimize_gate
legalize_phy_inst
read_sdc ../constraints/m1a_top.sdc
update_timing
report_timing_status -file gate.ts
report_timing_summary -file gate.timing
report_area -file gate.area

# ---- 布局 ----
place
update_timing -mode manhattan
report_timing_summary -file place.timing

# ---- 布线 ----
route
update_timing -mode final
report_timing_status -file route.ts
report_timing_summary -file route.timing
report_qor -step route -file route.qor
report_area -io_info -file route_phy.area

# ---- 比特流 ----
bitgen -bit m1a_top.bit
