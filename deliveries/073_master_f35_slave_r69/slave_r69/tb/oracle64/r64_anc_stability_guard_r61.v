`timescale 1ns/1ps
// 只管保护与输出授权；既有单频链不在此模块内改写，不自动切到未校准单频。
module r64_anc_stability_guard_r61 #(
 parameter integer WARM_FRAMES=48077,FADE_FRAMES=12019,BAND_CONFIRM=6010,
 parameter integer VERIFY_FRAMES=4808,STALE_FRAMES=1024,SUSPECT_EVENTS=2,READY_CONFIRM=6010
)(input wire clk,rst_n,mode_enabled,arm,stop,sample_valid,
 input wire band_ok,virtual_ready,model_valid,input wire [15:0] model_epoch,
 input wire hard_fault,input wire [3:0] hard_fault_code,
 input wire ratio_update,reference_ok,input wire [31:0] ratio_q16,input wire [47:0] reference_power,error_power,
 output wire force_zero,adapt_enable,hold_requires_arm,output wire [24:0] output_gain_q24,
 output reg [3:0] state,fault_code,output reg fault_latched,arm_accepted);
 localparam [3:0] IDLE=0,LEARN=1,WAIT_BAND=2,RAMP=3,RUN=4,VERIFY_OFF=5,FAULT=6,WAIT_SOURCE=7;
 localparam [24:0] ONE=25'd16777216;
 localparam integer STEP_VALUE=(16777216+FADE_FRAMES-1)/FADE_FRAMES;
 localparam [24:0] STEP=STEP_VALUE[24:0];
 reg [24:0] gain;
 reg [31:0] warm_count,band_count,verify_count,age,suspect_count,ready_count;
 // 每次ARM最多两次参考重确认/有证据基线更新，避免无界静音/重启循环。
 reg [1:0] verified_rebases;
 reg warm_done,have_ratio,pending,ref_ok;
 reg [15:0] epoch;
 reg [31:0] latest_ratio,baseline_ratio,on_ratio;
 reg [47:0] latest_ref,on_ref,latest_error,baseline_error,on_error;
 wire [31:0] current_ratio=ratio_update?ratio_q16:latest_ratio;
 wire [47:0] current_ref=ratio_update?reference_power:latest_ref;
 wire [47:0] current_error=ratio_update?error_power:latest_error;
 wire current_ref_ok=ratio_update?reference_ok:ref_ok;
 wire ratio_event=ratio_update||pending;
 wire ratio_increased,target_error_increased,verified_ratio_increase,verified_error_increase;
 r64_anc_rise_compare_r62 #(.WIDTH(32)) ratio_check(.sample(current_ratio),.baseline(baseline_ratio),.increased(ratio_increased));
 r64_anc_rise_compare_r62 #(.WIDTH(48)) target_check(.sample(current_error),.baseline(baseline_error),.increased(target_error_increased));
 r64_anc_rise_compare_r62 #(.WIDTH(32)) verified_ratio_check(.sample(on_ratio),.baseline(current_ratio),.increased(verified_ratio_increase));
 r64_anc_rise_compare_r62 #(.WIDTH(48)) verified_error_check(.sample(on_error),.baseline(current_error),.increased(verified_error_increase));
 wire ref_stable={1'b0,current_ref}>=({1'b0,on_ref}>>1)&&{1'b0,current_ref}<=({1'b0,on_ref}<<1);
 // 只有ON的误差功率和归一化误差均至少比OFF低3.01dB，才允许更新基线。
 // 扩一位再移位，不能让大功率左移溢出后被误认为有收益。
 wire verified_benefit=current_ratio!=0&&current_error!=0&&
     ({1'b0,on_ratio}<<1)<={1'b0,current_ratio}&&
     ({1'b0,on_error}<<1)<={1'b0,current_error};
 wire active=state!=IDLE&&state!=FAULT&&state!=WAIT_SOURCE;
 assign force_zero=!mode_enabled||stop||arm||hard_fault||!model_valid||!band_ok||!current_ref_ok||fault_latched||state!=RAMP&&state!=RUN||model_epoch!=epoch;
 assign output_gain_q24=force_zero?25'd0:gain;
 assign adapt_enable=mode_enabled&&!stop&&!arm&&!hard_fault&&model_valid&&model_epoch==epoch&&!fault_latched&&band_ok&&have_ratio&&current_ref_ok&&(state==LEARN||state==WAIT_BAND||state==RAMP||state==RUN);
 assign hold_requires_arm=state==FAULT||state==WAIT_SOURCE;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;fault_code<=0;fault_latched<=0;arm_accepted<=0;gain<=0;warm_count<=0;band_count<=0;verify_count<=0;age<=0;suspect_count<=0;ready_count<=0;warm_done<=0;have_ratio<=0;pending<=0;ref_ok<=0;epoch<=0;latest_ratio<=0;baseline_ratio<=0;on_ratio<=0;latest_ref<=0;on_ref<=0;latest_error<=0;baseline_error<=0;on_error<=0;verified_rebases<=0;end
  else begin
   arm_accepted<=0;
   if(ratio_update)begin latest_ratio<=ratio_q16;latest_ref<=reference_power;latest_error<=error_power;ref_ok<=reference_ok;have_ratio<=1;pending<=1;age<=0;end
   else if(sample_valid&&age<32'hffffffff)age<=age+1'b1;
   if(!mode_enabled)begin verified_rebases<=0;state<=IDLE;gain<=0;warm_count<=0;band_count<=0;ready_count<=0;baseline_ratio<=0;end
   else if(hard_fault)begin state<=FAULT;gain<=0;if(!fault_latched)fault_code<=hard_fault_code==0?4'd1:hard_fault_code;fault_latched<=1;end
   else if(stop)begin verified_rebases<=0;state<=IDLE;gain<=0;warm_count<=0;band_count<=0;baseline_ratio<=0;end
   else if(arm)begin
    verified_rebases<=0;gain<=0;warm_count<=0;band_count<=0;verify_count<=0;suspect_count<=0;ready_count<=0;warm_done<=0;baseline_ratio<=0;have_ratio<=0;pending<=0;age<=0;epoch<=model_epoch;
    if(model_valid)begin state<=LEARN;fault_code<=0;fault_latched<=0;arm_accepted<=1;end
    else begin state<=FAULT;fault_code<=2;fault_latched<=1;end
   end
   else if(active&&(!model_valid||model_epoch!=epoch))begin state<=FAULT;gain<=0;if(!fault_latched)fault_code<=model_valid?4'd3:4'd2;fault_latched<=1;end
   else if(active&&age>=STALE_FRAMES&&!ratio_update)begin state<=FAULT;gain<=0;if(!fault_latched)fault_code<=6;fault_latched<=1;end
   else if(sample_valid)begin
    if(ratio_event)pending<=0;
    if(virtual_ready&&band_ok&&have_ratio&&current_ref_ok)begin if(ready_count<READY_CONFIRM)ready_count<=ready_count+1'b1;end
    else ready_count<=0;
    case(state)
     IDLE:gain<=0;
     LEARN:begin
      gain<=0;
      if(!band_ok)begin state<=WAIT_BAND;warm_count<=0;band_count<=0;end
      else if(!have_ratio||!current_ref_ok||current_ratio==0)warm_count<=0;
      else begin
       if(warm_count<WARM_FRAMES)warm_count<=warm_count+1'b1;
       if(warm_count+1>=WARM_FRAMES&&virtual_ready&&ready_count+1>=READY_CONFIRM)begin warm_done<=1;baseline_ratio<=current_ratio;baseline_error<=current_error;fault_code<=0;state<=RAMP;suspect_count<=0;end
      end
     end
     WAIT_BAND:begin
      gain<=0;
      if(!band_ok||!have_ratio||!current_ref_ok||current_ratio==0)begin band_count<=0;if(!warm_done)warm_count<=0;end
      else begin
       if(band_count<BAND_CONFIRM)band_count<=band_count+1'b1;
       if(!warm_done&&warm_count<WARM_FRAMES)warm_count<=warm_count+1'b1;
       if(!warm_done&&warm_count+1>=WARM_FRAMES)warm_done<=1;
       if((warm_done||warm_count+1>=WARM_FRAMES)&&band_count+1>=BAND_CONFIRM&&virtual_ready&&ready_count+1>=READY_CONFIRM)begin baseline_ratio<=current_ratio;baseline_error<=current_error;fault_code<=0;state<=RAMP;suspect_count<=0;end
      end
     end
     RAMP,RUN:begin
      if(!band_ok)begin state<=WAIT_BAND;gain<=0;band_count<=0;baseline_ratio<=0;suspect_count<=0;end
      else if(!current_ref_ok)begin
       gain<=0;fault_code<=5;
       if(verified_rebases<2'd2)begin
        // 参考跌落立即静音且停止学习；复用原等待资格，不降低参考幅度门槛。
        // 恢复须连续满足原频带/参考/虚拟收敛确认，再经过原1秒斜坡。
        verified_rebases<=verified_rebases+2'd1;state<=WAIT_BAND;
        band_count<=0;ready_count<=0;baseline_ratio<=0;suspect_count<=0;
       end else state<=WAIT_SOURCE;
      end
      else begin
       if(state==RAMP)begin if(gain>=ONE-STEP)begin gain<=ONE;state<=RUN;end else gain<=gain+STEP;end
       if(ratio_event)begin
        if(ratio_increased||target_error_increased)begin
         if(suspect_count+1>=SUSPECT_EVENTS)begin state<=VERIFY_OFF;gain<=0;verify_count<=0;on_ratio<=current_ratio;on_ref<=current_ref;on_error<=current_error;end
         else suspect_count<=suspect_count+1'b1;
        end else suspect_count<=0;
       end
      end
     end
     VERIFY_OFF:begin
      gain<=0;
      if(!band_ok)begin state<=WAIT_BAND;band_count<=0;baseline_ratio<=0;end
      else begin
       if(verify_count<VERIFY_FRAMES)verify_count<=verify_count+1'b1;
       if(verify_count+1>=VERIFY_FRAMES&&ratio_event)begin
        if(current_ref_ok&&ref_stable&&verified_ratio_increase&&verified_error_increase)begin state<=FAULT;fault_code<=4;fault_latched<=1;end
        else if(current_ref_ok&&ref_stable&&virtual_ready&&verified_benefit&&verified_rebases<2'd2)begin
         // 先完成原静音核查；收益明确才保存新的OFF基线，并沿原斜坡恢复。
         baseline_ratio<=current_ratio;baseline_error<=current_error;
         verified_rebases<=verified_rebases+2'd1;suspect_count<=0;fault_code<=0;state<=RAMP;
        end
        else begin state<=WAIT_SOURCE;fault_code<=5;end
       end
      end
     end
     FAULT:gain<=0;
     WAIT_SOURCE:gain<=0;
     default:begin gain<=0;state<=FAULT;fault_code<=7;fault_latched<=1;end
    endcase
   end
  end
 end
endmodule
