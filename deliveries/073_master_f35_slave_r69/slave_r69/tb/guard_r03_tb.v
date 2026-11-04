`timescale 1ns/1ps
// 只管保护与输出授权；既有单频链不在此模块内改写，不自动切到未校准单频。
module anc_stability_guard_r61 #(
 parameter integer WARM_FRAMES=48077,FADE_FRAMES=12019,BAND_CONFIRM=6010,
 parameter integer VERIFY_FRAMES=4808,STALE_FRAMES=1024,SUSPECT_EVENTS=2,READY_CONFIRM=6010
)(input wire clk,rst_n,mode_enabled,arm,stop,sample_valid,
 input wire band_ok,virtual_ready,model_valid,input wire [15:0] model_epoch,
 input wire hard_fault,input wire [3:0] hard_fault_code,
 input wire ratio_update,reference_ok,input wire [31:0] ratio_q16,input wire [47:0] reference_power,error_power,
 output wire force_zero,adapt_enable,hold_requires_arm,output wire [24:0] output_gain_q24,
 output wire [3:0] state,fault_code,output wire fault_latched,arm_accepted,output wire [15:0] equiv_mask);
 wire [0:0] old_force_zero;
 wire [0:0] old_adapt_enable;
 wire [0:0] old_hold_requires_arm;
 wire [24:0] old_output_gain_q24;
 wire [3:0] old_state;
 wire [3:0] old_fault_code;
 wire [0:0] old_fault_latched;
 wire [0:0] old_arm_accepted;
compact_guard65 #(.WARM_FRAMES(WARM_FRAMES),.FADE_FRAMES(FADE_FRAMES),.BAND_CONFIRM(BAND_CONFIRM),.VERIFY_FRAMES(VERIFY_FRAMES),.STALE_FRAMES(STALE_FRAMES),.SUSPECT_EVENTS(SUSPECT_EVENTS),.READY_CONFIRM(READY_CONFIRM)) candidate(.clk(clk),.rst_n(rst_n),.mode_enabled(mode_enabled),.arm(arm),.stop(stop),.sample_valid(sample_valid),.band_ok(band_ok),.virtual_ready(virtual_ready),.model_valid(model_valid),.model_epoch(model_epoch),.hard_fault(hard_fault),.hard_fault_code(hard_fault_code),.ratio_update(ratio_update),.reference_ok(reference_ok),.ratio_q16(ratio_q16),.reference_power(reference_power),.error_power(error_power),.force_zero(force_zero),.adapt_enable(adapt_enable),.hold_requires_arm(hold_requires_arm),.output_gain_q24(output_gain_q24),.state(state),.fault_code(fault_code),.fault_latched(fault_latched),.arm_accepted(arm_accepted));
original_guard64 #(.WARM_FRAMES(WARM_FRAMES),.FADE_FRAMES(FADE_FRAMES),.BAND_CONFIRM(BAND_CONFIRM),.VERIFY_FRAMES(VERIFY_FRAMES),.STALE_FRAMES(STALE_FRAMES),.SUSPECT_EVENTS(SUSPECT_EVENTS),.READY_CONFIRM(READY_CONFIRM)) reference_guard(.clk(clk),.rst_n(rst_n),.mode_enabled(mode_enabled),.arm(arm),.stop(stop),.sample_valid(sample_valid),.band_ok(band_ok),.virtual_ready(virtual_ready),.model_valid(model_valid),.model_epoch(model_epoch),.hard_fault(hard_fault),.hard_fault_code(hard_fault_code),.ratio_update(ratio_update),.reference_ok(reference_ok),.ratio_q16(ratio_q16),.reference_power(reference_power),.error_power(error_power),.force_zero(old_force_zero),.adapt_enable(old_adapt_enable),.hold_requires_arm(old_hold_requires_arm),.output_gain_q24(old_output_gain_q24),.state(old_state),.fault_code(old_fault_code),.fault_latched(old_fault_latched),.arm_accepted(old_arm_accepted));
assign equiv_mask={(force_zero!=old_force_zero),(adapt_enable!=old_adapt_enable),(hold_requires_arm!=old_hold_requires_arm),(output_gain_q24!=old_output_gain_q24),(state!=old_state),(fault_code!=old_fault_code),(fault_latched!=old_fault_latched),(arm_accepted!=old_arm_accepted),(candidate.warm_count_value!=reference_guard.warm_count),(candidate.band_count_value!=reference_guard.band_count),(candidate.verify_count_value!=reference_guard.verify_count),(candidate.age_value!=(reference_guard.age>STALE_FRAMES?STALE_FRAMES:reference_guard.age)),(candidate.suspect_count_value!=reference_guard.suspect_count),(candidate.ready_count_value!=reference_guard.ready_count),(candidate.verified_rebases!=reference_guard.verified_rebases),(candidate.warm_done!=reference_guard.warm_done)};
endmodule
