`timescale 1ns/1ps
// 256tap整数FxNLMS调度；所有状态50MHz，历史与SOS上下文为独立同步RAM。
// 输入是同相位4抽取样本；输出带原frame_id，交由原生字队列固定排程。
`include "r63_output_limits.vh"
module r64_anc_fxn_core_r61 #(parameter integer OUTPUT_LIMIT=`ANC_R63_OUTPUT_LIMIT)(input wire clk,rst_n,clear,mode_enabled,stop,
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
 output reg kernel_fault);
`include "anc_core_constants_r61.vh"
 localparam [5:0] IDLE=0,FRAME_ZERO=1,DISPATCH=2,DOT_START=3,DOT_WAIT=4,
  SOS_READ0=5,SOS_READ1=6,SOS_LATCH1=7,SOS_START=8,SOS_WAIT=9,SOS_WRITE0=10,SOS_WRITE1=11,SOS_FINISH=12,
  SQUARE_START0=13,SQUARE_WAIT0=14,SQUARE_START1=15,SQUARE_WAIT1=16,
  DIV_START=17,DIV_WAIT=18,GUARD_PULSE=19,GUARD_WAIT=20,GAIN_START=21,GAIN_WAIT=22,UPDATE_START=23,UPDATE_WAIT=24,DONE=25,
  POWER_DIFF=26,POWER_PAIR=27,POWER_ADD=28,POWER_TOTAL=29,POWER_ABS=30,POWER_ROUND=31,POWER_SIGN=32,POWER_SUM=33,POWER_COMMIT=34;
 localparam signed [63:0] LIMIT_INTEGER=64'sd1*OUTPUT_LIMIT;
 localparam signed [31:0] LIMIT_Q12=OUTPUT_LIMIT*4096;
 localparam signed [15:0] LIMIT_WORD=OUTPUT_LIMIT[15:0];
 reg [5:0] state;reg [4:0] operation;reg [7:0] head;reg [15:0] frame_count,stamp;
 reg signed [15:0] ei,ri,vout;reg signed [31:0] primary,clean,model_virtual,filter_value;
 reg signed [31:0] band_q4,primary_q4,virtual_q4,primary_objective_q4,error_q4,reference_q4,gradient_q4;
 reg signed [31:0] nlms_gain;reg band_open,output_clipped,gradient_clipped,frame_adapt;
 reg [24:0] frame_gain;reg [47:0] band_power,total_power,virtual_power,primary_power,error_power,reference_power;
 reg [63:0] energy;reg [6:0] wait_count;
 reg [2:0] dot_kind;reg [8:0] dot_length;
 reg [5:0] sos_base;reg [2:0] sos_count,sos_stage;reg [1:0] sos_kind;
 reg signed [31:0] sos_input,z0_saved,z1_saved,sos_y,z0_new,z1_new;
 reg signed [31:0] square_input;reg signed [63:0] square_low;
 reg [47:0] power_base;
 reg signed [63:0] square_saved,difference_saved,power_a,power_b,power_c,power_ab,power_total;
 reg [63:0] power_abs,power_magnitude;reg power_sign;
 reg signed [44:0] power_delta;reg signed [49:0] power_candidate;
 wire all_ram_ready;wire [31:0] wq,aq,zq;wire [17:0] rq,fq;
 wire wready,aready,zready,rready,fready,wvalid,avalid,zvalid,rvalid,fvalid;
 wire werr,aerr,zerr,rerr,ferr;
 wire dot_ready,dot_read,dot_valid,dot_bad,dot_overrun;wire [7:0] dot_index,dot_context;wire signed [63:0] dot_sum;
 reg signed [17:0] rom_q;reg signed [17:0] dot_coefficient,dot_data;
 wire arithmetic_ready,sos_valid,sos_clipped,weight_valid,weight_fault,dispatch_fault,scalar_valid,scalar_overflow;
 wire signed [31:0] sy,sz0,sz1;wire signed [49:0] scalar_product;wire [7:0] sos_context,weight_context,scalar_context;
 wire [8:0] box_events,overflow_events;wire weight_read,weight_write;wire [7:0] weight_ra,weight_wa;wire signed [31:0] weight_wd;
 reg signed [31:0] scalar_x;reg signed [17:0] scalar_c;
 wire [5:0] context_index=sos_base+{3'd0,sos_stage};
 wire [2:0] coefficient_index=sos_kind==0?3'd0:sos_kind==1?sos_stage+3'd2:sos_stage==0?(sos_kind==2?3'd1:3'd0):sos_stage+3'd1;
 wire [89:0] coefficients=sos_coefficients(coefficient_index);
 wire sos_request=state==SOS_START;wire update_request=state==UPDATE_START;
 wire scalar_request=state==SQUARE_START0||state==SQUARE_START1||state==GAIN_START;
 wire [7:0] expected_scalar_context=state==GAIN_START||state==GAIN_WAIT?8'd2:state==SQUARE_START1||state==SQUARE_WAIT1?8'd1:8'd0;
 wire guard_sample=state==GUARD_PULSE;
 wire monitor_commit=guard_sample&&frame_count[7:0]==0;
 wire monitor_busy,ratio_valid,ratio_ref_ok,ratio_overflow,monitor_overrun;
 wire [31:0] ratio;wire [47:0] ratio_ref,ratio_error;wire guard_adapt,hold_arm,fault_latched,arm_accepted;
 wire [24:0] guard_gain;
 wire virtual_ready=primary_power>48'd256&&({16'd0,virtual_power}<<2)+{16'd0,virtual_power}<({16'd0,primary_power}<<2);
 wire hard_fault=native_fault||(!clear&&(kernel_fault||werr||aerr||zerr||rerr||ferr||dispatch_fault||dot_bad||dot_overrun||ratio_overflow||monitor_overrun));
 assign all_ram_ready=wready&&aready&&zready&&rready&&fready;
 assign ready=state==IDLE&&all_ram_ready&&!kernel_fault;
 assign debug_weight_write=weight_write;assign debug_weight_address=weight_wa;assign debug_weight=weight_wd;
 assign debug_adapt=frame_adapt;assign debug_gain=frame_gain;assign debug_virtual=vout;assign debug_band=band_open;
 assign debug_clipped=output_clipped;assign debug_gradient=gradient_q4;assign debug_error_power=error_power;assign debug_reference_power=reference_power;
 function automatic signed [63:0] round_shift;input signed [63:0] value;input integer bits;reg signed [64:0] rounded;
 begin rounded=($signed({value[63],value})+(65'sd1<<(bits-1))-(value[63]?65'sd1:65'sd0))>>>bits;round_shift=rounded[63:0];end endfunction
 function signed [31:0] sat32;input signed [63:0] value;begin sat32=value>64'sd2147483647 ? 32'sh7fffffff:value< -64'sd2147483648 ? 32'sh80000000:value[31:0];end endfunction
 function outside32;input signed [63:0] value;begin outside32=value>64'sd2147483647||value< -64'sd2147483648;end endfunction
 function outside18;input signed [63:0] value;begin outside18=value>64'sd131071||value< -64'sd131072;end endfunction
 wire signed [63:0] dot_rounded=round_shift(dot_sum,3);
 wire signed [63:0] weight_rounded=round_shift({{32{wq[31]}},wq},13);
 wire signed [63:0] sos_q4=round_shift({{32{sos_y[31]}},sos_y},8);
 wire signed [63:0] sos_integer=round_shift({{32{sos_y[31]}},sos_y},12);
 wire signed [63:0] primary_full=$signed(ei)*64'sd4096-dot_rounded;
 wire signed [63:0] clean_full=$signed(ri)*64'sd4096-dot_rounded;
 wire signed [63:0] gradient_full=round_shift({{32{sos_y[31]}},sos_y},8);
 wire [63:0] numerator_magnitude;wire numerator_negative;
 r64_anc_gain_numerator_r62 numerator(.gradient(gradient_q4[19:0]),.negative(numerator_negative),.magnitude(numerator_magnitude));
 wire [63:0] divider_q,divider_r;wire divider_busy,divider_valid,divide_zero,divider_ready;
 wire signed [63:0] expanded_product={{14{scalar_product[49]}},scalar_product};
 wire signed [63:0] squared=square_low+(expanded_product<<<17);
 reg [47:0] power_old;
 wire signed [63:0] accepted_word=round_shift(expanded_product,24);
 wire [7:0] history_read_index=head+dot_index;
 wire [7:0] gradient_read_index=head+weight_ra;
 wire w_read=(dot_read&&dot_kind==3)||weight_read;
 wire [7:0] w_address=weight_read?weight_ra:dot_index;
 wire r_read=dot_read&&(dot_kind==3||dot_kind==4);
 wire f_read=(dot_read&&dot_kind==5)||weight_read;
 wire a_read=dot_read&&(dot_kind==0||dot_kind==1||dot_kind==2);
 wire z_read=state==SOS_READ0||state==SOS_READ1;
 wire [6:0] z_address={context_index,1'b0}+(state==SOS_READ1?7'd1:7'd0);
 wire z_write=state==SOS_WRITE0||state==SOS_WRITE1;
 wire [6:0] z_write_address={context_index,1'b0}+(state==SOS_WRITE1?7'd1:7'd0);
 wire a_write=state==FRAME_ZERO||(state==DISPATCH&&(operation==12||operation==27));
 wire [31:0] a_write_data=state==FRAME_ZERO?32'd0:operation==12?{vout,16'd0}:{vout,command[15:0]};
 wire r_write=state==SOS_FINISH&&operation==9;
 wire f_write=state==SOS_FINISH&&operation==15;
 r64_anc_work_ram_r61 #(.WIDTH(32),.ADDR_BITS(8)) weights(.clk(clk),.rst_n(rst_n),.clear(clear),.write_request(weight_write),.write_address(weight_wa),.write_data(weight_wd),.read_request(w_read),.read_address(w_address),.ready(wready),.read_valid(wvalid),.read_data(wq),.access_error(werr));
 r64_anc_work_ram_r61 #(.WIDTH(32),.ADDR_BITS(8)) actuator_history(.clk(clk),.rst_n(rst_n),.clear(clear),.write_request(a_write),.write_address(head),.write_data(a_write_data),.read_request(a_read),.read_address(history_read_index),.ready(aready),.read_valid(avalid),.read_data(aq),.access_error(aerr));
 r64_anc_work_ram_r61 #(.WIDTH(32),.ADDR_BITS(7)) sos_states(.clk(clk),.rst_n(rst_n),.clear(clear),.write_request(z_write),.write_address(z_write_address),.write_data(state==SOS_WRITE0?z0_new:z1_new),.read_request(z_read),.read_address(z_address),.ready(zready),.read_valid(zvalid),.read_data(zq),.access_error(zerr));
 r64_anc_work_ram_r61 #(.WIDTH(18),.ADDR_BITS(8)) reference_history(.clk(clk),.rst_n(rst_n),.clear(clear),.write_request(r_write),.write_address(head),.write_data(sos_integer[17:0]),.read_request(r_read),.read_address(history_read_index),.ready(rready),.read_valid(rvalid),.read_data(rq),.access_error(rerr));
 r64_anc_work_ram_r61 #(.WIDTH(18),.ADDR_BITS(8)) gradient_history(.clk(clk),.rst_n(rst_n),.clear(clear),.write_request(f_write),.write_address(head),.write_data(sos_q4[17:0]),.read_request(f_read),.read_address(weight_read?gradient_read_index:history_read_index),.ready(fready),.read_valid(fvalid),.read_data(fq),.access_error(ferr));
 always @(posedge clk)if(dot_read)rom_q<=dot_kind==2?feedback_coefficient(dot_index):secondary_coefficient(dot_index);
 always @*begin
  dot_coefficient=rom_q;dot_data=18'sd0;
  case(dot_kind)
   0,2:dot_data={{2{aq[15]}},aq[15:0]};
   1:dot_data={{2{aq[31]}},aq[31:16]};
   3:begin dot_coefficient=weight_rounded[17:0];dot_data=rq;end
   4:dot_data=rq;
   5:begin dot_coefficient=fq;dot_data=fq;end
   default:begin end
  endcase
 end
 always @*begin
  scalar_x=square_input;scalar_c={1'b0,square_input[16:0]};power_old=0;
  if(state==SQUARE_START1||state==SQUARE_WAIT1)scalar_c={{3{square_input[31]}},square_input[31:17]};
  if(state==GAIN_START||state==GAIN_WAIT)begin scalar_x=$signed({7'd0,frame_gain});scalar_c={{2{vout[15]}},vout};end
  case(operation)6:power_old=band_power;7:power_old=total_power;19:power_old=error_power;20:power_old=reference_power;21:power_old=virtual_power;22:power_old=primary_power;default:begin end endcase
 end
 r64_anc_dot18_engine_r61 dotter(.clk(clk),.rst_n(rst_n),.clear(clear),.request(state==DOT_START),.length(dot_length),.context_id({3'd0,operation}),.ready(dot_ready),.read_enable(dot_read),.read_index(dot_index),.coefficient(dot_coefficient),.data(dot_data),.valid(dot_valid),.invalid_length(dot_bad),.overrun(dot_overrun),.sum(dot_sum),.result_context(dot_context));
 r64_anc_core_arithmetic_r61 arithmetic(.clk(clk),.rst_n(rst_n),.clear(clear),.sos_request(sos_request),.x(sos_input),.z0(z0_saved),.z1(z1_saved),.b0(coefficients[89:72]),.b1(coefficients[71:54]),.b2(coefficients[53:36]),.a1(coefficients[35:18]),.a2(coefficients[17:0]),.sos_context({2'd0,context_index}),.sos_valid(sos_valid),.sos_clipped(sos_clipped),.y(sy),.new_z0(sz0),.new_z1(sz1),.sos_result_context(sos_context),
 .weight_request(update_request),.length(9'd256),.gain(nlms_gain),.weight_context(8'd71),.weight_recovery(output_clipped),.weight_valid(weight_valid),.weight_fault(weight_fault),.weight_result_context(weight_context),.box_events(box_events),.overflow_events(overflow_events),.memory_read(weight_read),.read_address(weight_ra),.memory_valid(wvalid&&fvalid),.weight(wq),.gradient(fq),.memory_write(weight_write),.write_address(weight_wa),.write_weight(weight_wd),
 .scalar_request(scalar_request),.scalar_x(scalar_x),.scalar_c(scalar_c),.scalar_context(expected_scalar_context),.scalar_valid(scalar_valid),.scalar_overflow(scalar_overflow),.scalar_product(scalar_product),.scalar_result_context(scalar_context),.ready(arithmetic_ready),.dispatch_fault(dispatch_fault));
 r64_anc_u64_divider_r61 normalizer(.clk(clk),.rst_n(rst_n),.clear(clear),.request(state==DIV_START),.numerator(numerator_magnitude),.denominator(energy+64'd1),.ready(divider_ready),.busy(divider_busy),.done(divider_valid),.quotient(divider_q),.remainder(divider_r),.divide_by_zero(divide_zero));
 r64_anc_ratio_monitor_r61 monitor(.clk(clk),.rst_n(rst_n),.clear(clear),.power_commit(monitor_commit),.error_power(error_power),.reference_power(reference_power),.busy(monitor_busy),.ratio_valid(ratio_valid),.reference_ok(ratio_ref_ok),.ratio_overflow(ratio_overflow),.overrun(monitor_overrun),.ratio_q16(ratio),.reference_snapshot(ratio_ref),.error_snapshot(ratio_error));
 r64_anc_stability_guard_r61 guard(.clk(clk),.rst_n(rst_n),.mode_enabled(mode_enabled),.arm(clear),.stop(stop),.sample_valid(guard_sample),.band_ok(band_open),.virtual_ready(virtual_ready),.model_valid(model_valid),.model_epoch(model_epoch),.hard_fault(hard_fault),.hard_fault_code(4'd8),.ratio_update(ratio_valid),.reference_ok(ratio_ref_ok),.ratio_q16(ratio),.reference_power(ratio_ref),.error_power(ratio_error),.force_zero(force_zero),.adapt_enable(guard_adapt),.hold_requires_arm(hold_arm),.output_gain_q24(guard_gain),.state(guard_state),.fault_code(guard_reason),.fault_latched(fault_latched),.arm_accepted(arm_accepted));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;operation<=0;head<=0;frame_count<=0;stamp<=0;ei<=0;ri<=0;vout<=0;primary<=0;clean<=0;model_virtual<=0;filter_value<=0;
   band_q4<=0;primary_q4<=0;virtual_q4<=0;primary_objective_q4<=0;error_q4<=0;reference_q4<=0;gradient_q4<=0;nlms_gain<=0;
   band_open<=0;output_clipped<=0;gradient_clipped<=0;frame_adapt<=0;frame_gain<=0;band_power<=0;total_power<=0;virtual_power<=0;primary_power<=0;error_power<=0;reference_power<=0;energy<=0;wait_count<=0;
   dot_kind<=0;dot_length<=0;sos_base<=0;sos_count<=0;sos_stage<=0;sos_kind<=0;sos_input<=0;z0_saved<=0;z1_saved<=0;sos_y<=0;z0_new<=0;z1_new<=0;square_input<=0;square_low<=0;
   power_base<=0;square_saved<=0;difference_saved<=0;power_a<=0;power_b<=0;power_c<=0;power_ab<=0;power_total<=0;power_abs<=0;power_magnitude<=0;power_sign<=0;power_delta<=0;power_candidate<=0;
   sample_done<=0;command_submit<=0;command_frame<=0;command<=0;elapsed_clocks<=0;maximum_clocks<=0;kernel_fault<=0;end
  else if(clear)begin state<=IDLE;operation<=0;head<=0;frame_count<=0;vout<=0;primary<=0;clean<=0;model_virtual<=0;filter_value<=0;band_open<=0;frame_adapt<=0;frame_gain<=0;nlms_gain<=0;
   band_power<=0;total_power<=0;virtual_power<=0;primary_power<=0;error_power<=0;reference_power<=0;sample_done<=0;command_submit<=0;command<=0;elapsed_clocks<=0;maximum_clocks<=0;kernel_fault<=0;end
  else begin
   sample_done<=0;command_submit<=0;
   if(state!=IDLE)elapsed_clocks<=elapsed_clocks+13'd1;
   case(state)
    IDLE:if(sample_valid&&ready)begin ei<=error_pcm;ri<=reference_pcm;stamp<=frame_id;head<=head-8'd1;elapsed_clocks<=0;state<=FRAME_ZERO;operation<=0;frame_adapt<=0;end
    FRAME_ZERO:state<=DISPATCH;
    DISPATCH:case(operation)
     0,1,2,10,13,23:begin
      dot_kind<=operation==0?3'd0:operation==1?3'd1:operation==2?3'd2:operation==10?3'd3:operation==13?3'd4:3'd5;
      dot_length<=operation==10||operation==23?9'd256:9'd152;state<=DOT_START;
     end
     3:begin operation<=4;state<=DISPATCH;end
     4,5,9,11,14,15,16,17,18:begin
      sos_stage<=0;state<=SOS_READ0;
      case(operation)
       4:begin sos_base<=0;sos_count<=6;sos_kind<=2;sos_input<=primary;end
       5:begin sos_base<=6;sos_count<=6;sos_kind<=3;sos_input<=primary;end
       9:begin sos_base<=12;sos_count<=1;sos_kind<=0;sos_input<=clean;end
       11:begin sos_base<=13;sos_count<=5;sos_kind<=1;sos_input<=filter_value;end
       14:begin sos_base<=18;sos_count<=5;sos_kind<=1;sos_input<=filter_value;end
       15:begin sos_base<=23;sos_count<=6;sos_kind<=2;sos_input<=filter_value;end
       16:begin sos_base<=29;sos_count<=6;sos_kind<=2;sos_input<=primary+model_virtual;if(outside32($signed({{32{primary[31]}},primary})+$signed({{32{model_virtual[31]}},model_virtual})))kernel_fault<=1;end
       17:begin sos_base<=35;sos_count<=6;sos_kind<=2;sos_input<=ei*32'sd4096;end
       18:begin sos_base<=41;sos_count<=6;sos_kind<=2;sos_input<=clean;end
       default:begin end
      endcase
     end
     6,7,19,20,21,22:begin
      square_input<=operation==6?band_q4:operation==7?primary_q4:operation==19?error_q4:operation==20?reference_q4:operation==21?virtual_q4:primary_objective_q4;
      power_base<=power_old;
      state<=SQUARE_START0;
     end
     8:begin
      if(({16'd0,band_power}<<4)+({16'd0,band_power}<<2)>({16'd0,total_power}<<1)+{16'd0,total_power}&&total_power!=0)band_open<=1;
      else if(({16'd0,band_power}<<3)+({16'd0,band_power}<<1)<{16'd0,total_power})band_open<=0;
      operation<=9;
     end
     12:operation<=13;
     24:begin
      if(energy==0||output_clipped||gradient_clipped)begin nlms_gain<=0;operation<=25;end
      else state<=DIV_START;
     end
     25:begin state<=GUARD_PULSE;wait_count<=0;end
     26:state<=GAIN_START;
     27:begin command_submit<=1;command_frame<=stamp;operation<=28;end
     28:if(frame_adapt)state<=UPDATE_START;else begin operation<=29;end
     29:state<=DONE;
     default:begin kernel_fault<=1;state<=IDLE;end
    endcase
    DOT_START:if(dot_ready)state<=DOT_WAIT;
    DOT_WAIT:if(dot_valid)begin
     if(dot_context!={3'd0,operation})kernel_fault<=1;
     case(operation)
      0:begin primary<=sat32(primary_full);primary_q4<=sat32(round_shift(primary_full,8));if(outside32(primary_full))kernel_fault<=1;end
      1:begin model_virtual<=sat32(dot_rounded);if(outside32(dot_rounded))kernel_fault<=1;end
      2:begin clean<=sat32(clean_full);if(outside32(clean_full))kernel_fault<=1;end
      10,13:begin filter_value<=sat32(dot_rounded);if(outside32(dot_rounded))kernel_fault<=1;end
      23:begin energy<=dot_sum;if(dot_sum[63])kernel_fault<=1;end
      default:begin end
     endcase
     operation<=operation+5'd1;state<=DISPATCH;
    end
    SOS_READ0:state<=SOS_READ1;
    SOS_READ1:begin if(!zvalid)kernel_fault<=1;z0_saved<=zq;state<=SOS_LATCH1;end
    SOS_LATCH1:begin if(!zvalid)kernel_fault<=1;z1_saved<=zq;state<=SOS_START;end
    SOS_START:if(arithmetic_ready)state<=SOS_WAIT;
    SOS_WAIT:if(sos_valid)begin
     if(sos_clipped||sos_context!={2'd0,context_index})kernel_fault<=1;
     sos_y<=sy;z0_new<=sz0;z1_new<=sz1;state<=SOS_WRITE0;
    end
    SOS_WRITE0:state<=SOS_WRITE1;
    SOS_WRITE1:if(sos_stage+3'd1==sos_count)state<=SOS_FINISH;
     else begin sos_stage<=sos_stage+3'd1;sos_input<=sos_y;state<=SOS_READ0;end
    SOS_FINISH:begin
     case(operation)
      4:primary_objective_q4<=sos_q4[31:0];
      5:band_q4<=sos_q4[31:0];
      9:if(outside18(sos_integer))kernel_fault<=1;
      11:begin vout<=sos_integer>LIMIT_INTEGER?LIMIT_WORD:sos_integer< -LIMIT_INTEGER?-LIMIT_WORD:sos_integer[15:0];output_clipped<=sos_y>LIMIT_Q12||sos_y< -LIMIT_Q12;end
      14:filter_value<=sos_y;
      15:if(outside18(sos_q4))kernel_fault<=1;
      16:begin virtual_q4<=gradient_full[31:0];gradient_q4<=gradient_full>524272?32'sd524272:gradient_full< -524272?-32'sd524272:gradient_full[31:0];gradient_clipped<=gradient_full>524272||gradient_full< -524272;end
      17:error_q4<=sos_q4[31:0];
      18:reference_q4<=sos_q4[31:0];
      default:begin end
     endcase
     operation<=operation+5'd1;state<=DISPATCH;
    end
    SQUARE_START0:if(arithmetic_ready)state<=SQUARE_WAIT0;
    SQUARE_WAIT0:if(scalar_valid)begin
     if(scalar_overflow||scalar_context!=0)kernel_fault<=1;square_low<=expanded_product;state<=SQUARE_START1;
    end
    SQUARE_START1:if(arithmetic_ready)state<=SQUARE_WAIT1;
    SQUARE_WAIT1:if(scalar_valid)begin
     if(scalar_overflow||scalar_context!=1)kernel_fault<=1;
     square_saved<=squared;state<=POWER_DIFF;
    end
    POWER_DIFF:begin difference_saved<=square_saved-$signed({16'd0,power_base});state<=POWER_PAIR;end
    POWER_PAIR:begin power_a<=(difference_saved<<<8)+(difference_saved<<<7);power_b<=(difference_saved<<<5)+(difference_saved<<<4);power_c<=difference_saved<<<2;state<=POWER_ADD;end
    POWER_ADD:begin power_ab<=power_a+power_b;state<=POWER_TOTAL;end
    POWER_TOTAL:begin power_total<=power_ab+power_c;state<=POWER_ABS;end
    POWER_ABS:begin power_abs<=power_total[63]?-power_total:power_total;power_sign<=power_total[63];state<=POWER_ROUND;end
    POWER_ROUND:begin power_magnitude<=power_abs+64'd524288;state<=POWER_SIGN;end
    POWER_SIGN:begin power_delta<=power_sign?-$signed({1'b0,power_magnitude[63:20]}):$signed({1'b0,power_magnitude[63:20]});state<=POWER_SUM;end
    POWER_SUM:begin power_candidate<=$signed({2'd0,power_base})+$signed({{5{power_delta[44]}},power_delta});state<=POWER_COMMIT;end
    POWER_COMMIT:begin
     if(power_candidate[49]||power_candidate[48])kernel_fault<=1;
     case(operation)6:band_power<=power_candidate[47:0];7:total_power<=power_candidate[47:0];19:error_power<=power_candidate[47:0];20:reference_power<=power_candidate[47:0];21:virtual_power<=power_candidate[47:0];22:primary_power<=power_candidate[47:0];default:begin end endcase
     operation<=operation+5'd1;state<=DISPATCH;
    end
    DIV_START:if(!divider_busy)state<=DIV_WAIT;
    DIV_WAIT:if(divider_valid)begin
     if(divide_zero)kernel_fault<=1;
     if(numerator_negative)nlms_gain<=divider_q>64'd2147483648 ? 32'sh80000000:-$signed(divider_q[31:0]);
     else nlms_gain<=divider_q>64'd2147483647 ? 32'sh7fffffff:divider_q[31:0];
     operation<=25;state<=DISPATCH;
    end
    GUARD_PULSE:state<=GUARD_WAIT;
    GUARD_WAIT:begin
     // 当前样本的许可消费上一份比值缓存；本次除法结果供后续样本使用。
     if(wait_count==0)begin frame_gain<=guard_gain;frame_adapt<=guard_adapt;end
     if(wait_count==70)begin operation<=26;state<=DISPATCH;end
     else wait_count<=wait_count+7'd1;
    end
    GAIN_START:if(arithmetic_ready)state<=GAIN_WAIT;
    GAIN_WAIT:if(scalar_valid)begin
     if(scalar_overflow||scalar_context!=2||accepted_word>LIMIT_INTEGER||accepted_word< -LIMIT_INTEGER)kernel_fault<=1;
     command<=force_zero?18'sd0:accepted_word[17:0];operation<=27;state<=DISPATCH;
    end
    UPDATE_START:if(arithmetic_ready)state<=UPDATE_WAIT;
    UPDATE_WAIT:if(weight_valid)begin if(weight_fault||weight_context!=71||overflow_events!=0)kernel_fault<=1;operation<=29;state<=DISPATCH;end
    DONE:begin sample_done<=1;frame_count<=frame_count+16'd1;state<=IDLE;if(elapsed_clocks>maximum_clocks)maximum_clocks<=elapsed_clocks;end
    default:begin kernel_fault<=1;state<=IDLE;end
   endcase
   if((sample_valid&&!ready)||hard_fault)begin kernel_fault<=1;command<=0;command_submit<=0;state<=IDLE;end
   if(state!=IDLE&&elapsed_clocks>=4158)begin kernel_fault<=1;command<=0;command_submit<=0;state<=IDLE;end
  end
 end
endmodule
