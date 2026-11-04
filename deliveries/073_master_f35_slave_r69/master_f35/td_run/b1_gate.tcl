
#   主板门禁 PLB<=2450, Setup>=3.690ns, Hold>=0.214ns; 不生成 bit
import_device eagle_s20.db -package EG4S20BG256
set_param flow qor_monitor on
source ./b1_sources.tcl
read_adc ../constraints/t073_master_top.adc

set_param rtl resource_sharing off
commit_param -step rtl
optimize_rtl

read_sdc ../constraints/t073_master_top.sdc
set_param gate pack_effort high
set_param gate map_mode area_prior
set_param gate merge_tiny_lut on
commit_param -step gate
optimize_gate
legalize_phy_inst
read_sdc ../constraints/t073_master_top.sdc
source ../constraints/c1_first_stage_exception.tcl
update_timing

set_param place effort high
commit_param -step place
place

# 每轮保留数据库；满足原门禁即输出最终报告。
proc timing_gate_pass {} {
    report_timing_status -file current_gate.ts
    set f [open current_gate.ts r]
    set txt [read $f]
    close $f
    foreach field {SWNS STNS HWNS HTNS} {
        if {![regexp "${field}:\\s*(-?\\d+(?:\\.\\d+)?)ns" $txt unused value]} { error "MISSING_TIMING_$field" }
        set val($field) $value
    }
    return [expr {$val(SWNS)>=3.690 && $val(HWNS)>=0.214 && $val(STNS)==0 && $val(HTNS)==0}]
}
set_path_margin -group S1_setup -setup -global 3.800
set_param route effort routability
commit_param -step route
route
update_timing -mode final
reset_path_margin -all
update_timing -mode final
export_db routed_checkpoint.db
if {![timing_gate_pass]} {
    set_path_margin -group S2_setup -setup -global 3.690
    set_path_margin -group H1_hold -hold -global 0.214
    update_timing -mode final
    fix_hold
    reset_path_margin -all
    update_timing -mode final
    export_db hold_checkpoint.db
}
if {![timing_gate_pass]} {
    set_path_margin -group H2_hold -hold -global 0.260
    update_timing -mode final
    fix_hold
    reset_path_margin -all
    update_timing -mode final
    fix_hold
    update_timing -mode final
}
# 先落库与门禁所需的两份报告, 慢报告放后(被看门狗打断也不丢结果)
export_db gate_b1.db
report_timing_status -file gate_b1.ts
report_area -verbose -io_info -file gate_b1.area
report_timing_summary -ep_num 5000 -path_num 1 -file gate_b1.timing
report_qor -step route -file gate_b1.qor
report_timing_ignored -file gate_b1.ignored.txt
puts "MASTER_B1_COMPLETE"
exit
