import_device eagle_s20.db -package EG4S20BG256
set_param flow qor_monitor on
set_param gate pack_seq_in_io off
read_hdl -file {../rtl/anc_biquad_shared_r61.v ../rtl/anc_core_arithmetic_r61.v ../rtl/anc_decay_dsp65.v ../rtl/anc_divider_compact_r65.v ../rtl/anc_dot18_engine_r61.v ../rtl/anc_first_fault_snapshot_r68.v ../rtl/anc_fxn_core_r61.v ../rtl/anc_gain_numerator_r62.v ../rtl/anc_mul18_pipe_r61.v ../rtl/anc_mul32x18_r61.v ../rtl/anc_native_actuator_r61.v ../rtl/anc_numerator_dsp65.v ../rtl/anc_ram_decimator_r61.v ../rtl/anc_ratio_monitor_r65.v ../rtl/anc_rise_compare_r62.v ../rtl/anc_run_guard_r56.v ../rtl/anc_sf_rom_r65.v ../rtl/anc_stability_guard_r61.v ../rtl/anc_u64_divider_r61.v ../rtl/anc_uart_snapshot_r68.v ../rtl/anc_weak_path_frequency.v ../rtl/anc_weight_update_r61.v ../rtl/anc_work_ram_r61.v ../rtl/audio_i2s_stereo_tx_r12.v ../rtl/fft_three_path_scheduler_r06.v ../rtl/i2s_mic4_rx_50m.v ../rtl/interboard_rx.v ../rtl/interboard_tx.v ../rtl/key_press_debounce.v ../rtl/link062_packet_tx.v ../rtl/link062_pcm_rx.v ../rtl/mic2_frequency_display_r66.v ../rtl/mic_three_mean_t16.v ../rtl/multi_spectrum_group_tx_r03_bram.v ../rtl/pcf_fft_frontend.v ../rtl/r58_uart_tx.v ../rtl/seg6_hz_display_r66.v ../rtl/slave_audio_demo_top.v ../rtl/slave_demo_physical_wrapper.v ../rtl/slave_panel_ctrl.v ../rtl/tf_pcm_player.v} -top slave_demo_physical_wrapper
read_adc ../constraints/slave_demo_physical.adc
optimize_rtl
report_area -file combined.rtl.area
read_sdc ../constraints/slave_demo_physical.sdc
set_param gate pack_effort high
set_param gate map_mode area_prior
set_param gate merge_tiny_lut on
commit_param -step gate
optimize_gate
legalize_phy_inst
report_area -verbose -file combined.gate.area
write_verilog gate_logic.v
export_db gate.db
puts "R69_SLIM_SYNTH_COMPLETE"
exit
