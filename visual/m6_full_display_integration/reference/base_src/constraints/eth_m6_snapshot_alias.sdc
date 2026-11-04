# bank描述符与front_bank在同一事件更新，TD会合并等价寄存器。
# 补充合并后的两个真实入口；仍只到第一级descriptor_meta，绝不包括descriptor_sync。
set_false_path -from [get_regs {u_display/u_snapshot/front_bank[0]}] -to [get_regs {u_display/u_snapshot/descriptor_meta[0]}]
set_false_path -from [get_regs {u_display/u_snapshot/front_bank[1]}] -to [get_regs {u_display/u_snapshot/descriptor_meta[1]}]
