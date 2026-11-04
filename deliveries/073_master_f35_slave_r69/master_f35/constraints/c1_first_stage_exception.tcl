# 仅在optimize_gate之后或import_db之后从主Tcl source；不得放进SDC解析器。
# 门级网表复核必须证明该PAD的IN_DFFMODE=FF且diq只作s0，s1及其后继续计时。
set t072_rx_port [get_ports -nowarn {*c1_rx_data*}]
set t072_rx_first_d [get_pins -hier -nowarn {*c1_rx_data*.ipad}]
if {[llength $t072_rx_port] != 1 || [llength $t072_rx_first_d] != 1} {
    error "T072_PACKED_RX_FIRST_D_NOT_UNIQUE:$t072_rx_port:$t072_rx_first_d"
}
puts "T072_CHECKED_PACKED_RX_FIRST_D:$t072_rx_port->$t072_rx_first_d"
set_false_path -from $t072_rx_port -to $t072_rx_first_d
