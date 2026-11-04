`timescale 1ns/1ps
module r61_guard_default_tb(input clk,rst_n,arm,stop,sample_valid,band_ok,hard_fault,virtual_ready,
 input power_commit,input [47:0] error_power,reference_power,
 output force_zero,adapt,hold_arm,output [24:0] gain,output [3:0] state,reason,
 output monitor_busy,ratio_valid,ratio_overflow,overrun,output [31:0] ratio);
 wire ref_ok;wire [47:0] rp,ep;wire fault,accepted;
 anc_ratio_monitor_r61 m(.clk(clk),.rst_n(rst_n),.clear(arm),.power_commit(power_commit),.error_power(error_power),.reference_power(reference_power),.busy(monitor_busy),.ratio_valid(ratio_valid),.reference_ok(ref_ok),.ratio_overflow(ratio_overflow),.overrun(overrun),.ratio_q16(ratio),.reference_snapshot(rp),.error_snapshot(ep));
 original_guard64 g(.clk(clk),.rst_n(rst_n),.mode_enabled(1'b1),.arm(arm),.stop(stop),.sample_valid(sample_valid),.band_ok(band_ok),.virtual_ready(virtual_ready),.model_valid(1'b1),.model_epoch(16'd1),.hard_fault(hard_fault||ratio_overflow||overrun),.hard_fault_code(4'd8),.ratio_update(ratio_valid),.reference_ok(ref_ok),.ratio_q16(ratio),.reference_power(rp),.error_power(ep),.force_zero(force_zero),.adapt_enable(adapt),.hold_requires_arm(hold_arm),.output_gain_q24(gain),.state(state),.fault_code(reason),.fault_latched(fault),.arm_accepted(accepted));
endmodule
