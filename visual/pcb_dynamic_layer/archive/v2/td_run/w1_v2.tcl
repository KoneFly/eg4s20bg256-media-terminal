import_device eagle_s20.db -package EG4S20BG256
set_param flow qor_monitor on
read_hdl -file {../rtl/pcb_particle_overlay.v ../rtl/pcb_span_ram.v ../rtl/pcb_ram_2k16.v} -top pcb_particle_overlay
optimize_rtl
read_sdc w1_v2.sdc
optimize_gate
update_timing
report_area -io_info -file w1_v2_gate.area
report_timing_summary -file w1_v2_gate.timing
report_timing -file w1_v2_paths.timing
report_qor -step gate -file w1_v2_gate.qor
exit
