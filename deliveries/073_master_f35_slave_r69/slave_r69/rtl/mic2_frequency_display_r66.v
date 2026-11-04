`timescale 1ns/1ps
// 仅供显示的MIC2低频主峰；复用公共FFT的私有作业口，不参与ANC控制。
// 原生Fs=50MHz/1040；4096样本窗后等待4096样本，为公共三谱整组留出计算时间。
module mic2_frequency_display_r66 #(
 parameter [25:0] STALE_CLOCKS=26'd25000000
)(input wire clk,rst_n,enable,sample_valid,
 input wire signed [15:0] sample_data,
 output reg capture_request,input wire capture_accept,capture_done,capture_abort,
 input wire [11:0] capture_read_address,output wire signed [15:0] capture_sample,
 input wire fft_valid,input wire [11:0] fft_index,
 input wire signed [15:0] fft_re,fft_im,
 output reg frequency_valid,frequency_update,output reg [9:0] frequency_hz);
 localparam [3:0] COLLECT=0,SCALE=1,WAIT_FFT=2,SCAN=3,PREPARE=4,DIVIDE=5,CONVERT=6,RESULT=7,WAIT_DONE=8,REST=9;
 reg [3:0] state;
 reg [11:0] sample_index;
 reg signed [27:0] sample_sum;
 reg signed [15:0] frame_min,frame_max,frame_mean;
 reg [16:0] scaled_span;
 reg [3:0] scale_shift;
 reg attenuate;
 reg [25:0] age;
 (* ram_style="bram_32k" *) reg [15:0] history[0:4095];
 reg signed [15:0] history_q;
 wire signed [16:0] centered=$signed({history_q[15],history_q})-$signed({frame_mean[15],frame_mean});
 wire signed [31:0] wide={{15{centered[16]}},centered};
 wire signed [31:0] normalized=attenuate?wide>>>1:wide<<<scale_shift;
 assign capture_sample=normalized>32767?16'sh7fff:normalized< -32768?16'sh8000:normalized[15:0];
 always @(posedge clk)begin
  history_q<=history[capture_read_address];
  if(rst_n&&enable&&!capture_abort&&state==COLLECT&&sample_valid)history[sample_index]<=sample_data;
 end
 wire signed [15:0] min_next=sample_data<frame_min?sample_data:frame_min;
 wire signed [15:0] max_next=sample_data>frame_max?sample_data:frame_max;
 wire signed [27:0] sum_next=sample_sum+{{12{sample_data[15]}},sample_data};
 wire [16:0] span_next=$signed({max_next[15],max_next})-$signed({min_next[15],min_next});
 wire [15:0] abs_re=fft_re[15]?-fft_re:fft_re;
 wire [15:0] abs_im=fft_im[15]?-fft_im:fft_im;
 wire [16:0] magnitude=abs_re>abs_im?{1'b0,abs_re}+{2'b0,abs_im[15:1]}:{1'b0,abs_im}+{2'b0,abs_re[15:1]};
 reg [16:0] previous,best_left,best_mid,best_right;
 reg [6:0] best_bin;
 wire [17:0] difference=best_right>best_left?{1'b0,best_right}-{1'b0,best_left}:{1'b0,best_left}-{1'b0,best_right};
 wire [18:0] denominator={2'b0,best_left}+{1'b0,best_mid,1'b0}+{2'b0,best_right};
 reg [26:0] dividend;
 reg [18:0] divisor;
 reg [19:0] remainder;
 reg [9:0] quotient;
 reg [4:0] divide_count;
 reg negative;
 wire [19:0] shifted_remainder={remainder[18:0],dividend[26]};
 wire quotient_bit=shifted_remainder>={1'b0,divisor};
 wire [9:0] quotient_next={quotient[8:0],quotient_bit};
 wire [19:0] remainder_next=quotient_bit?shifted_remainder-{1'b0,divisor}:shifted_remainder;
 wire [7:0] delta=quotient_next>10'd128 ? 8'd128 : quotient_next[7:0];
 wire [15:0] bin_q8=negative?{1'b0,best_bin,8'd0}-{8'd0,delta}:{1'b0,best_bin,8'd0}+{8'd0,delta};
 // Hz=bin_q8*48077/2^20；48077近似真实采样率，1kHz内比例误差<0.002Hz。
 reg [31:0] hz_sum,hz_value;
 reg [15:0] hz_factor;
 wire [31:0] hz_next=hz_sum+(hz_factor[0]?hz_value:32'd0);
 reg [11:0] candidate_hz;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   state<=COLLECT;sample_index<=0;sample_sum<=0;frame_min<=32767;frame_max<=-32768;frame_mean<=0;
   scaled_span<=0;scale_shift<=0;attenuate<=0;age<=0;capture_request<=0;
   frequency_valid<=0;frequency_update<=0;frequency_hz<=0;
   previous<=0;best_left<=0;best_mid<=0;best_right<=0;best_bin<=0;
   dividend<=0;divisor<=0;remainder<=0;quotient<=0;divide_count<=0;negative<=0;
   hz_sum<=0;hz_value<=0;hz_factor<=0;candidate_hz<=0;
  end else if(!enable||capture_abort)begin
   state<=COLLECT;sample_index<=0;sample_sum<=0;frame_min<=32767;frame_max<=-32768;
   capture_request<=0;frequency_valid<=0;frequency_update<=0;age<=0;
  end else begin
   frequency_update<=0;
   if(age<STALE_CLOCKS)age<=age+26'd1;else frequency_valid<=0;
   case(state)
    COLLECT:if(sample_valid)begin
     sample_sum<=sum_next;frame_min<=min_next;frame_max<=max_next;
     if(sample_index==4095)begin
      frame_mean<=sum_next[27:12];scaled_span<=span_next;scale_shift<=0;attenuate<=span_next>=32768;
      sample_index<=0;
      if(span_next<8)begin frequency_valid<=0;state<=REST;end else state<=SCALE;
     end else sample_index<=sample_index+12'd1;
    end
    SCALE:if(scaled_span<16384&&scale_shift<10)begin scaled_span<=scaled_span<<1;scale_shift<=scale_shift+4'd1;end
     else begin capture_request<=1;state<=WAIT_FFT;end
    WAIT_FFT:if(capture_accept)begin
     capture_request<=0;previous<=0;best_left<=0;best_mid<=0;best_right<=0;best_bin<=0;state<=SCAN;
    end
    SCAN:if(fft_valid)begin
     previous<=magnitude;
     if(fft_index>=3&&fft_index<=85)begin
      if(magnitude>best_mid)begin best_bin<=fft_index[6:0];best_left<=previous;best_mid<=magnitude;best_right<=0;end
      else if(fft_index=={5'd0,best_bin}+12'd1)best_right<=magnitude;
     end else if(fft_index==86)begin
      if(best_bin==85)best_right<=magnitude;
      state<=PREPARE;
     end
    end
    PREPARE:begin
     if(best_mid<32||best_mid<best_left||best_mid<best_right||denominator==0)begin frequency_valid<=0;state<=WAIT_DONE;end
     else begin
      dividend<={difference,9'd0};divisor<=denominator;remainder<=0;quotient<=0;
      negative<=best_right<best_left;divide_count<=26;state<=DIVIDE;
     end
    end
    DIVIDE:begin
     dividend<={dividend[25:0],1'b0};quotient<=quotient_next;remainder<=remainder_next;
     if(divide_count==0)begin hz_sum<=32'd524288;hz_value<={16'd0,bin_q8};hz_factor<=16'd48077;state<=CONVERT;end
     else divide_count<=divide_count-5'd1;
    end
    CONVERT:begin
     hz_sum<=hz_next;hz_value<=hz_value<<1;hz_factor<=hz_factor>>1;
     if(hz_factor==1)begin candidate_hz<=hz_next[31:20];state<=RESULT;end
    end
    RESULT:begin
     if(candidate_hz>=40&&candidate_hz<=999)begin frequency_hz<=candidate_hz[9:0];frequency_valid<=1;frequency_update<=1;age<=0;end
     else frequency_valid<=0;
     state<=WAIT_DONE;
    end
    WAIT_DONE:if(capture_done)begin sample_index<=0;state<=REST;end
    REST:if(sample_valid)begin
     if(sample_index==4095)begin sample_index<=0;sample_sum<=0;frame_min<=32767;frame_max<=-32768;state<=COLLECT;end
     else sample_index<=sample_index+12'd1;
    end
    default:begin state<=COLLECT;sample_index<=0;sample_sum<=0;frame_min<=32767;frame_max<=-32768;capture_request<=0;frequency_valid<=0;end
   endcase
  end
 end
endmodule
