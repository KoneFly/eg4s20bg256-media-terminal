import_device eagle_s20.db -package EG4S20BG256
set_param flow qor_monitor on
read_hdl -file {../rtl/pcb_frame_updater.v ../rtl/pcb_ram_2k16.v} -top pcb_frame_updater
optimize_rtl
read_sdc w2_v2.sdc
optimize_gate
update_timing
report_area -io_info -file w2_v2_gate.area
report_timing_summary -file w2_v2_gate.timing
report_timing -file w2_v2_paths.timing
report_qor -step gate -file w2_v2_gate.qor
exit
