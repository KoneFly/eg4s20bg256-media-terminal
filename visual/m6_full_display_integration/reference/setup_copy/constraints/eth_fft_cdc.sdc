# 仅用于本次已布线数据库；12条地址数据路径各自放宽一个125MHz周期。
# 稳定时间>=40ns，仿真8相位最小41ns；setup预算4->12ns，hold恢复原值。
# 不豁免时钟域、同步器或其他FIFO路径；生成器与映射JSON一并封存。
if {[llength [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[0\]_syn_3\.q\[0\]$}]] != 1 || [llength [get_pins -hier -regexp {^u_txf/wr_rd_addr_reg\[0\]_syn_3\.mi\[0\]$}]] != 1} {error "CDC bit0 pin missing"}
set_multicycle_path -setup -start -from [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[0\]_syn_3\.q\[0\]$}] -to [get_pins -hier -regexp {^u_txf/wr_rd_addr_reg\[0\]_syn_3\.mi\[0\]$}] 2
set_multicycle_path -hold -start -from [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[0\]_syn_3\.q\[0\]$}] -to [get_pins -hier -regexp {^u_txf/wr_rd_addr_reg\[0\]_syn_3\.mi\[0\]$}] 1
if {[llength [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[1\]_syn_3\.q\[1\]$}]] != 1 || [llength [get_pins -hier -regexp {^u_txf/wr_rd_addr_reg\[1\]_syn_3\.mi\[1\]$}]] != 1} {error "CDC bit1 pin missing"}
set_multicycle_path -setup -start -from [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[1\]_syn_3\.q\[1\]$}] -to [get_pins -hier -regexp {^u_txf/wr_rd_addr_reg\[1\]_syn_3\.mi\[1\]$}] 2
set_multicycle_path -hold -start -from [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[1\]_syn_3\.q\[1\]$}] -to [get_pins -hier -regexp {^u_txf/wr_rd_addr_reg\[1\]_syn_3\.mi\[1\]$}] 1
if {[llength [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[1\]_syn_3\.q\[0\]$}]] != 1 || [llength [get_pins -hier -regexp {^u_txf/wr_rd_addr_reg\[1\]_syn_3\.mi\[0\]$}]] != 1} {error "CDC bit2 pin missing"}
set_multicycle_path -setup -start -from [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[1\]_syn_3\.q\[0\]$}] -to [get_pins -hier -regexp {^u_txf/wr_rd_addr_reg\[1\]_syn_3\.mi\[0\]$}] 2
set_multicycle_path -hold -start -from [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[1\]_syn_3\.q\[0\]$}] -to [get_pins -hier -regexp {^u_txf/wr_rd_addr_reg\[1\]_syn_3\.mi\[0\]$}] 1
if {[llength [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[3\]_syn_4\.q\[1\]$}]] != 1 || [llength [get_pins -hier -regexp {^u_txf/wr_rd_addr_reg\[3\]_syn_3\.mi\[1\]$}]] != 1} {error "CDC bit3 pin missing"}
set_multicycle_path -setup -start -from [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[3\]_syn_4\.q\[1\]$}] -to [get_pins -hier -regexp {^u_txf/wr_rd_addr_reg\[3\]_syn_3\.mi\[1\]$}] 2
set_multicycle_path -hold -start -from [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[3\]_syn_4\.q\[1\]$}] -to [get_pins -hier -regexp {^u_txf/wr_rd_addr_reg\[3\]_syn_3\.mi\[1\]$}] 1
if {[llength [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[3\]_syn_4\.q\[0\]$}]] != 1 || [llength [get_pins -hier -regexp {^u_txf/wr_rd_addr_reg\[3\]_syn_3\.mi\[0\]$}]] != 1} {error "CDC bit4 pin missing"}
set_multicycle_path -setup -start -from [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[3\]_syn_4\.q\[0\]$}] -to [get_pins -hier -regexp {^u_txf/wr_rd_addr_reg\[3\]_syn_3\.mi\[0\]$}] 2
set_multicycle_path -hold -start -from [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[3\]_syn_4\.q\[0\]$}] -to [get_pins -hier -regexp {^u_txf/wr_rd_addr_reg\[3\]_syn_3\.mi\[0\]$}] 1
if {[llength [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[5\]_syn_4\.q\[1\]$}]] != 1 || [llength [get_pins -hier -regexp {^u_txf/wr_rd_addr_reg\[5\]_syn_4\.mi\[1\]$}]] != 1} {error "CDC bit5 pin missing"}
set_multicycle_path -setup -start -from [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[5\]_syn_4\.q\[1\]$}] -to [get_pins -hier -regexp {^u_txf/wr_rd_addr_reg\[5\]_syn_4\.mi\[1\]$}] 2
set_multicycle_path -hold -start -from [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[5\]_syn_4\.q\[1\]$}] -to [get_pins -hier -regexp {^u_txf/wr_rd_addr_reg\[5\]_syn_4\.mi\[1\]$}] 1
if {[llength [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[5\]_syn_4\.q\[0\]$}]] != 1 || [llength [get_pins -hier -regexp {^u_txf/add2_syn_89\.mi\[0\]$}]] != 1} {error "CDC bit6 pin missing"}
set_multicycle_path -setup -start -from [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[5\]_syn_4\.q\[0\]$}] -to [get_pins -hier -regexp {^u_txf/add2_syn_89\.mi\[0\]$}] 2
set_multicycle_path -hold -start -from [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[5\]_syn_4\.q\[0\]$}] -to [get_pins -hier -regexp {^u_txf/add2_syn_89\.mi\[0\]$}] 1
if {[llength [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[7\]_syn_3\.q\[1\]$}]] != 1 || [llength [get_pins -hier -regexp {^u_txf/add2_syn_89\.mi\[1\]$}]] != 1} {error "CDC bit7 pin missing"}
set_multicycle_path -setup -start -from [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[7\]_syn_3\.q\[1\]$}] -to [get_pins -hier -regexp {^u_txf/add2_syn_89\.mi\[1\]$}] 2
set_multicycle_path -hold -start -from [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[7\]_syn_3\.q\[1\]$}] -to [get_pins -hier -regexp {^u_txf/add2_syn_89\.mi\[1\]$}] 1
if {[llength [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[7\]_syn_3\.q\[0\]$}]] != 1 || [llength [get_pins -hier -regexp {^u_txf/wr_rd_addr_reg\[5\]_syn_4\.mi\[0\]$}]] != 1} {error "CDC bit8 pin missing"}
set_multicycle_path -setup -start -from [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[7\]_syn_3\.q\[0\]$}] -to [get_pins -hier -regexp {^u_txf/wr_rd_addr_reg\[5\]_syn_4\.mi\[0\]$}] 2
set_multicycle_path -hold -start -from [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[7\]_syn_3\.q\[0\]$}] -to [get_pins -hier -regexp {^u_txf/wr_rd_addr_reg\[5\]_syn_4\.mi\[0\]$}] 1
if {[llength [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[10\]_syn_3\.q\[0\]$}]] != 1 || [llength [get_pins -hier -regexp {^u_txf/wr_rd_addr_reg\[10\]_syn_4\.mi\[0\]$}]] != 1} {error "CDC bit9 pin missing"}
set_multicycle_path -setup -start -from [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[10\]_syn_3\.q\[0\]$}] -to [get_pins -hier -regexp {^u_txf/wr_rd_addr_reg\[10\]_syn_4\.mi\[0\]$}] 2
set_multicycle_path -hold -start -from [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[10\]_syn_3\.q\[0\]$}] -to [get_pins -hier -regexp {^u_txf/wr_rd_addr_reg\[10\]_syn_4\.mi\[0\]$}] 1
if {[llength [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[10\]_syn_3\.q\[1\]$}]] != 1 || [llength [get_pins -hier -regexp {^u_txf/wr_rd_addr_reg\[10\]_syn_4\.mi\[1\]$}]] != 1} {error "CDC bit10 pin missing"}
set_multicycle_path -setup -start -from [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[10\]_syn_3\.q\[1\]$}] -to [get_pins -hier -regexp {^u_txf/wr_rd_addr_reg\[10\]_syn_4\.mi\[1\]$}] 2
set_multicycle_path -hold -start -from [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[10\]_syn_3\.q\[1\]$}] -to [get_pins -hier -regexp {^u_txf/wr_rd_addr_reg\[10\]_syn_4\.mi\[1\]$}] 1
if {[llength [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[11\]_syn_4\.q\[0\]$}]] != 1 || [llength [get_pins -hier -regexp {^u_txf/wr_rd_addr_reg\[11\]_syn_4\.mi\[0\]$}]] != 1} {error "CDC bit11 pin missing"}
set_multicycle_path -setup -start -from [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[11\]_syn_4\.q\[0\]$}] -to [get_pins -hier -regexp {^u_txf/wr_rd_addr_reg\[11\]_syn_4\.mi\[0\]$}] 2
set_multicycle_path -hold -start -from [get_pins -hier -regexp {^u_txf/rd_addr_txfer_reg\[11\]_syn_4\.q\[0\]$}] -to [get_pins -hier -regexp {^u_txf/wr_rd_addr_reg\[11\]_syn_4\.mi\[0\]$}] 1
