module r61_fxn_golden_tb #(parameter integer OUTPUT_LIMIT=`ANC_R63_OUTPUT_LIMIT)(input wire clk,rst_n,clear,mode_enabled,stop,
 input wire model_valid,input wire [15:0] model_epoch,
 input wire native_fault,input wire sample_valid,input wire [15:0] frame_id,
 input wire signed [15:0] error_pcm,reference_pcm,
 output wire ready,force_zero,output reg sample_done,command_submit,
 output reg [15:0] command_frame,output reg signed [17:0] command,
 output wire [3:0] guard_state,guard_reason,
 output wire debug_weight_write,output wire [7:0] debug_weight_address,
 output wire signed [31:0] debug_weight,output wire debug_adapt,
 output wire [24:0] debug_gain,output wire signed [15:0] debug_virtual,
 output wire debug_band,debug_clipped,output wire signed [31:0] debug_gradient,
 output wire [47:0] debug_error_power,debug_reference_power,
 output reg [12:0] elapsed_clocks,output reg [12:0] maximum_clocks,
 output reg kernel_fault,
 input wire oracle_clk,oracle_arm,oracle_sample,oracle_band,oracle_hard,oracle_virtual,oracle_commit,
 input wire [47:0] oracle_error_power,oracle_reference_power,
 output wire oracle_zero,oracle_adapt,output wire [24:0] oracle_gain,
 output wire [3:0] oracle_state,oracle_reason);
 wire unused_hold,unused_busy,unused_ratio_valid,unused_ratio_overflow,unused_overrun;wire [31:0] unused_ratio;
anc_fxn_core_r61 #(.OUTPUT_LIMIT(OUTPUT_LIMIT)) dut(.clk(clk),.rst_n(rst_n),.clear(clear),.mode_enabled(mode_enabled),.stop(stop),.model_valid(model_valid),.model_epoch(model_epoch),.native_fault(native_fault),.sample_valid(sample_valid),.frame_id(frame_id),.error_pcm(error_pcm),.reference_pcm(reference_pcm),.ready(ready),.force_zero(force_zero),.sample_done(sample_done),.command_submit(command_submit),.command_frame(command_frame),.command(command),.guard_state(guard_state),.guard_reason(guard_reason),.debug_weight_write(debug_weight_write),.debug_weight_address(debug_weight_address),.debug_weight(debug_weight),.debug_adapt(debug_adapt),.debug_gain(debug_gain),.debug_virtual(debug_virtual),.debug_band(debug_band),.debug_clipped(debug_clipped),.debug_gradient(debug_gradient),.debug_error_power(debug_error_power),.debug_reference_power(debug_reference_power),.elapsed_clocks(elapsed_clocks),.maximum_clocks(maximum_clocks),.kernel_fault(kernel_fault));
r61_guard_default_tb oracle(.clk(oracle_clk),.rst_n(rst_n),.arm(oracle_arm),.stop(1'b0),.sample_valid(oracle_sample),.band_ok(oracle_band),.hard_fault(oracle_hard),.virtual_ready(oracle_virtual),.power_commit(oracle_commit),.error_power(oracle_error_power),.reference_power(oracle_reference_power),.force_zero(oracle_zero),.adapt(oracle_adapt),.hold_arm(unused_hold),.gain(oracle_gain),.state(oracle_state),.reason(oracle_reason),.monitor_busy(unused_busy),.ratio_valid(unused_ratio_valid),.ratio_overflow(unused_ratio_overflow),.overrun(unused_overrun),.ratio(unused_ratio));
endmodule
