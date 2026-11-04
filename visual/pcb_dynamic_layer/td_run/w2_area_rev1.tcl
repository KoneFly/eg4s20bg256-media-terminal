import_device eagle_s20.db -package EG4S20BG256
read_hdl -file {../rtl/pcb_frame_updater.v} -top pcb_frame_updater
optimize_rtl
report_area -file w2_rev1_rtl.area
optimize_gate
report_area -file w2_rev1_gate.area
exit
