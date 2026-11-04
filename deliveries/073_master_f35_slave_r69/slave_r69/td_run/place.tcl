import_device eagle_s20.db -package EG4S20BG256
import_db gate.db
puts "PLACE_SEED:[get_param place seed]"
puts "FLOW_ENABLE_SEED:[get_param flow enable_seed]"
set_path_margin -group R69_PLACE_SETUP_GOAL -setup -global 2.000
set_param place effort high
commit_param -step place
place
reset_path_margin -all
update_timing -mode manhattan
report_area -verbose -io_info -file combined.place.area
export_db combined.place.db
puts "R69_SLIM_PLACE_COMPLETE"
exit
