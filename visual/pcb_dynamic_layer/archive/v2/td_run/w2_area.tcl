# 本任务独立 W2 面积门禁；输入清单于 2026-10-04 用户确认后冻结。
import_device eagle_s20.db -package EG4S20BG256
read_hdl -file {../rtl/pcb_frame_updater.v} -top pcb_frame_updater
optimize_rtl
report_area -file w2_rtl.area
optimize_gate
report_area -file w2_gate.area
exit
