# 试验 bit 生成(独立文件名, 不进入生产位/BURN_INDEX)
# 只在 gate_b1.db 已过门禁(PLB<=2450, Setup>=3.690, Hold>=0.214)后由看门狗运行
import_device eagle_s20.db -package EG4S20BG256
import_db gate_b1.db
source ../constraints/c1_first_stage_exception.tcl
update_timing -mode final
report_timing_summary -file trial_bitgen_check.timing
write_verilog trial_verified.v
bitgen -bit t073_trial.bit
puts "MASTER_BITGEN_COMPLETE"
exit
