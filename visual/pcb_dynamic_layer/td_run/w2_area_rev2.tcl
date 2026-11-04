import_device eagle_s20.db -package EG4S20BG256
read_hdl -file {rev2/pcb_frame_updater.v} -top pcb_frame_updater
optimize_rtl
report_area -file w2_rev2_rtl.area
optimize_gate
report_area -file w2_rev2_gate.area
exit
