`timescale 1ns/1ps
// 只读观察完整生产封装；输入走实际 I2S ADC，不伪造 native tick。
module fx_unified_tb(
 input wire clk,key1,key2,key3,key4,input wire [3:0] sw,mic_sd,
 input wire inject,inject_submit,inject_zero,loopback,
 input wire [15:0] inject_frame,input wire [17:0] inject_word,
 output wire bclk,lrck,din,reset_n,capture_valid,frontend_ready,fv,fx_clear,fx_selected,fx_running,
 output wire [15:0] mic0,mic1,fe,fr,control_id,native_group,command_frame,
 output wire [1:0] native_phase,active_mode,
 output wire [3:0] led,guard_state,guard_reason,
 output wire armed,pending,submit,core_done,core_zero,core_fault,actuator_fault,pair_overrun,overlap,
 output wire [12:0] core_elapsed,core_maximum,
 output wire [15:0] tx_word,fx_word,output wire tx_valid,frame_start,native_clip,
 output wire active_auto,anc_enabled,conflict,ref_phase_mismatch,
 output wire [7:0] seg_data,output wire [5:0] seg_sel,
 output wire diag_uart_tx,diag_first_valid,output wire [31:0] diag_first_fault,output wire [7:0] diag_first_native,
 output wire [15:0] diag_crc_s_out,diag_crc_f_out,output wire [7:0] diag_s_words,diag_f_words,
 output wire [1:0] tone,output wire [13:0] fixed_hz,
 output wire [31:0] packets,groups,output wire group_done,bin_valid,
 output wire [3:0] filter_clipped,
 output wire frontend_enable,output wire [15:0] filter_phase,
 output wire [7:0] slots_valid,output wire [15:0] due,arrival_group,
 output wire [1:0] arrival_phase,output wire arrival_valid,
 output wire actuator_pending,output wire [17:0] command
);
 wire link_tx;wire [3:0] returns;
 wire [3:0] actual_mic=loopback?{4{din}}:mic_sd;
 slave_demo_physical_wrapper #(.PANEL_SWITCH_LAST(20'd16),.PANEL_KEY_LONG_LAST(27'd2000000),.SEG_SCAN_LAST(16'd20)) dut(
 .clk_50(clk),.key1(key1),.key2(key2),.key3(key3),.key4(key4),.sw(sw),.mic_sd(actual_mic),.link_rx_data(1'b0),
 .mic_bclk(bclk),.mic_lrck(lrck),.audio_din(din),.link_tx_data(link_tx),.return_low(returns),.led(led),.seg_data(seg_data),.seg_sel(seg_sel),.uart_tx(diag_uart_tx));
 assign diag_first_valid=dut.diag_first_valid,diag_first_fault=dut.diag_first[32+:32],diag_first_native=dut.diag_first[80+:8];
 assign diag_crc_s_out=dut.diag_crc_s,diag_crc_f_out=dut.diag_crc_f,diag_s_words=dut.diag_count_s,diag_f_words=dut.diag_count_f;
 assign reset_n=dut.reset_release_n,capture_valid=dut.mic_capture_valid;
 assign mic0=dut.mic0_pcm,mic1=dut.mic1_pcm,fe=dut.fe,fr=dut.fr;
 assign frontend_ready=dut.frontend_ready,fv=dut.fv,fx_clear=dut.fx_clear,fx_selected=dut.fx_selected,fx_running=dut.fx_running;
 assign control_id=dut.control_id,native_group=dut.unused_native_group,native_phase=dut.unused_native_phase;
 assign command_frame=dut.command_frame,submit=dut.submit,command=dut.command;
 assign active_mode=dut.mode_active,active_auto=dut.active_auto,armed=dut.anc_armed,pending=dut.audio_mode_pending;
 assign guard_state=dut.guard_state,guard_reason=dut.guard_reason;
 assign core_done=dut.core_done,core_zero=dut.core_zero,core_fault=dut.core_fault;
 assign actuator_fault=dut.actuator_fault,pair_overrun=dut.pair_overrun,overlap=dut.filter_overlap;
 assign core_elapsed=dut.unused_elapsed,core_maximum=dut.unused_maximum;
 assign tx_word=dut.anc_tx_left,tx_valid=dut.anc_tx_valid,fx_word=dut.fx_word,frame_start=dut.anc_frame_start;
 assign anc_enabled=dut.anc_enabled,conflict=dut.mode_conflict,native_clip=dut.native_clip;
 assign fixed_hz=dut.fixed_frequency_hz,tone=dut.anc_tone_select;
 assign packets=dut.spectrum_sent_packets_total,groups=dut.spectrum_sent_groups_total,group_done=dut.fft_group_done,bin_valid=dut.fft_bin_valid;
 assign filter_clipped={2'd0,dut.filter_clipped},filter_phase={14'd0,dut.frontend.phase};
 assign frontend_enable=dut.fx_selected&&dut.fx_running;
 assign slots_valid=dut.actuator.slots_valid,due=dut.actuator.due,arrival_group=dut.actuator.arrival_group,
 arrival_phase=dut.actuator.arrival_phase,arrival_valid=dut.actuator.arrival_valid,actuator_pending=dut.actuator.pending;
 // 与正式 R61 独立 native pipeline 相同复位的实际 ADC/TX 相位对照。
 wire rb,rw,rv,rc,rd;wire [15:0] r0,r1,r2,r3;wire ro;
 i2s_mic4_rx_50m reference_adc(.clk_50m(clk),.rst_n(reset_n),.mic_sd(actual_mic),.mic_bclk(rb),.mic_lrck(rw),
 .pcm_valid(rv),.pcm0(r0),.pcm1(r1),.pcm2(r2),.pcm3(r3),.pcm_capture_event(rc));
 audio_i2s_stereo_tx_r12 reference_tx(.clk_50m(clk),.rst_n(reset_n),.mic_bclk(rb),.mic_lrck(rw),
 .mic_pair_valid(tx_valid),.mic_pair_raw(tx_word),.mic_pair_filtered(tx_word),.audio_din(rd),.pair_overrun(ro));
 assign ref_phase_mismatch=reset_n&&({rb,rw,rv,r0,r1,rd,ro}!={bclk,lrck,capture_valid,mic0,mic1,din,pair_overrun});
 // 明确限定测试边界：只注入核心提交口，不改生产源、ADC/FIR/队列/TX。
 // 非注入阶段 release 后仍由真实 R61 核驱动。
 always @(posedge clk)begin
  if(inject)begin
   force dut.submit=inject_submit;
   force dut.command_frame=inject_frame;
   force dut.command=inject_word;
   force dut.core_zero=inject_zero;
  end else begin
   release dut.submit;release dut.command_frame;release dut.command;release dut.core_zero;
  end
 end
endmodule
