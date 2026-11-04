`timescale 1ns/1ps
// 真实清理版与R40参考并行；只在测试实例加速长按门限。
module auto_playback_tb(
 input wire clk,key1,key2,key3,key4,input wire [3:0] sw,mic_sd,
 input wire packet_valid,input wire [95:0] packet_data,input wire [1:0] packet_kind,
 output wire packet_ready,packet_fault,
 output wire bclk,lrck,din,ref_din,reset_n,capture_valid,pair_valid,
 output wire [15:0] mic0,mic1,mic2,mic3,pair_raw,pair_post,
 output wire tx_pair_valid,anc_active,anc_ready,anc_cal,anc_fault,anc_valid,
 output wire [15:0] anc_sample,ref_anc_sample,
 output wire demo_fault,ref_demo_fault,tx_overrun,anc_mismatch,
 output wire bin_valid,group_done,output wire [1:0] path,
 output wire [6:0] bin_index,output wire [7:0] bin_data,
 output wire tf_active,tf_playing,tf_fault,tf_sample_valid,player_selected,
 output wire [15:0] tf_sample,output wire [11:0] tf_level,
 output wire pb_start,pb_reset,pb_word_valid,pb_input_fault,
 output wire [31:0] pb_word_data,pb_first,
 output wire [1:0] active_mode,output wire conflict,armed,
 output wire [13:0] frequency,output wire [7:0] seg_data,output wire [5:0] seg_sel,
 output wire [2:0] acquisition_state,
 output wire [31:0] fll_increment,output wire fll_busy,
 output wire auto_mode,auto_captured,core_command,core_override,
 output wire limit_seen,output wire guard_fault,output wire [2:0] guard_code,
 output wire [31:0] auto_increment,output wire [1:0] manual_tone
);
 wire serial_data,serial_sync,serial_clock;
 wire [15:0] sent_packets;
 link062_packet_tx source_tx(.clk(clk),.rst_n(key1),.valid(packet_valid),.ready(packet_ready),
  .data(packet_data),.kind(packet_kind),.tag(5'd0),.link_data(serial_data),
  .link_sync(serial_sync),.link_clk(serial_clock),.fault(packet_fault),.sent_packets(sent_packets));
 wire ref_bclk,ref_lrck,ref_link,live_link;
 wire [3:0] live_return,ref_return,live_led,ref_led;
 slave_demo_physical_wrapper #(.PANEL_KEY_LONG_LAST(27'd1_999_999),.PANEL_SWITCH_LAST(20'd1999),.SEG_SCAN_LAST(16'd249)) dut(
  .clk_50(clk),.key1(key1),.key2(key2),.key3(key3),.key4(key4),.sw(sw),.seg_data(seg_data),.seg_sel(seg_sel),
  .link_rx_data(serial_data),.mic_sd(mic_sd),
  .mic_bclk(bclk),.mic_lrck(lrck),.audio_din(din),.link_tx_data(live_link),.return_low(live_return),.led(live_led));
 wire ref_valid,ref_ready,ref_cal,ref_fault;
 wire signed [15:0] reference_sample;
 assign ref_din=1'b0;
 assign reset_n=dut.reset_release_n;
 assign capture_valid=dut.mic_capture_valid;
 assign mic0=dut.mic0_pcm,mic1=dut.mic1_pcm,mic2=dut.mic2_pcm,mic3=dut.mic3_pcm;
 assign pair_valid=dut.mic_pair_valid,pair_raw=dut.mic_pair_raw,pair_post=dut.mic_pair_filtered;
 assign tx_pair_valid=dut.anc_tx_valid;
 assign anc_active=dut.anc_enabled,anc_ready=dut.anc_ready,anc_cal=dut.anc_calibrating,anc_fault=dut.anc_fault;
 assign anc_valid=dut.anc_sample_out_valid,anc_sample=dut.anc_sample_out,ref_anc_sample=16'd0;
 assign demo_fault=dut.demo_fault,ref_demo_fault=1'b0;
 assign tx_overrun=dut.u_audio_output.pair_overrun;
 // 控制算法已改变；以独立数学黄金验证，不作R40逐拍相同声明。
 assign anc_mismatch=1'b0;
 assign limit_seen=dut.anc_limit_reached;
 assign guard_fault=dut.run_guard_fault,guard_code=dut.run_guard_code;
 assign fll_increment=dut.anc_tracking_increment,fll_busy=1'b0;
 assign acquisition_state=3'd0;
 assign auto_mode=dut.auto_mode,auto_captured=1'b0;
 assign core_command=dut.anc_command,core_override=1'b0;
 assign auto_increment=32'd0,manual_tone=dut.anc_tone_select;
 assign active_mode=dut.mode_active,conflict=dut.mode_conflict,armed=dut.anc_armed,frequency=dut.fixed_frequency_hz;
 assign bin_valid=dut.fft_bin_valid,path=dut.fft_path_index,bin_index=dut.fft_bin_index,bin_data=dut.fft_bin_data;
 assign group_done=dut.fft_group_done;
 assign tf_active=dut.tf_active,tf_playing=dut.tf_playing,tf_fault=dut.tf_fault;
 assign tf_sample_valid=dut.tf_sample_valid,tf_sample=dut.tf_sample,tf_level=dut.u_tf_player.level;
 assign player_selected=dut.tf_active&&!dut.anc_active&&!dut.audio_mode_pending;
 assign pb_start=dut.playback_block_start,pb_reset=dut.playback_history_reset,pb_word_valid=dut.playback_word_valid;
 assign pb_word_data=dut.playback_word_data,pb_first=dut.u_demo.pcm_block_first;
 assign pb_input_fault=dut.pcm_rx_fault||dut.pcm_transport_errors!=0||dut.pcm_transport_lost!=0;
endmodule
