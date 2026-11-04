import_device eagle_s20.db -package EG4S20BG256
import_db combined.place.db
puts "SEED:[get_param place seed]"
set_path_margin -group R69_SLIM_ROUTE_SETUP_GOAL -setup -global 2.000
set_param route effort routability
commit_param -step route
set_param route fix_hold off
route
update_timing -mode final
reset_path_margin -all
set_path_margin -group R69_SLIM_HOLD_GOAL -hold -global 0.020
fix_hold
update_timing -mode final
reset_path_margin -all
update_timing -mode final
report_area -verbose -io_info -file verified.area
report_qor -step route -file verified.qor
report_timing_summary -ep_num 5000 -path_num 1 -file verified.timing
report_timing_status -file verified.status
report_timing_ignored -file verified.ignored.txt
export_db verified.db
write_verilog verified.v
puts "R69_SLIM_ROUTE_COMPLETE"
exit
