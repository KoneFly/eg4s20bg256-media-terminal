import_device eagle_s20.db -package EG4S20BG256
set_param flow qor_monitor on
read_hdl -file {pcb_frame_updater.v pcb_ram_2k16.v} -top pcb_frame_updater
optimize_rtl
report_area -file rtl.area
read_sdc clock.sdc
optimize_gate
update_timing
report_area -io_info -file area.txt
report_timing_summary -file timing.txt
report_qor -step gate -file resource.qor
puts "W2_MC_TD_COMPLETE"
exit
