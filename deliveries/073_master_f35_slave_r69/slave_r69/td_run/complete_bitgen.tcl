if {![file exists release_authorization.permit]} {error "R69 source/DB preseal not verified"}
import_device eagle_s20.db -package EG4S20BG256
import_db verified.db
update_timing -mode final
report_timing_summary -ep_num 5000 -path_num 1 -file bitgen_check.timing
report_area -verbose -io_info -file bitgen_check.area
bitgen -bit task068_slave_room_model_r69.bit
write_verilog bitgen_check.v
puts "R69_SLIM_BITGEN_COMPLETE"
exit
