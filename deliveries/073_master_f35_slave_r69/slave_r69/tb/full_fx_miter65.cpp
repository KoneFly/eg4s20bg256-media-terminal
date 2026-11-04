#include "diag_expected.h"
// 20ns真实时钟，I2S位流/独立FIR/非零数字回环；不修改正式保护门限。
#include "Vfx_unified_tb.h"
#include "verilated.h"
#include "../tests/fir_coefficients.h"
#include <array>
#include <cmath>
#include <cstdint>
#include <deque>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>

struct Bench {
 Vfx_unified_tb d;
 uint64_t clocks=0,native_checks=0,fir_checks=0,phase_checks=0,submit_checks=0,real_jobs=0,stereo_checks=0,nonzero_stereo=0,nonzero_loop=0,mode_checks=0,muted_loop_checks=0,raw_clip_checks=0;
 unsigned mute_native_start=0,real_maximum=0;int clip_source=0,source_r=0;bool sine_source=false;uint64_t tone_n=0,first_run_clock=0,run_clocks=0,miter_checks=0;
 uint64_t last_native=0,last_fv=0,expected_fv_cycle=0,inject_due=0;
 unsigned native_index=0,model_phase=0,model_group=0,inject_count=0,decoder_rises=0;
 uint16_t next_frame=0,left=0,right=0,pending_word=0,current_word=0;
 bool decoder_w=true,prior_b=false,negative=false,expect_hard_fault=false,pending_pair=false,current_pair=false;
 bool old_mode_pending=false;unsigned old_mode=0;bool old_auto=false;
 std::deque<std::array<int,2>> history;
 std::array<int,2> expected_fir{};
 std::array<unsigned,6> digits{};
 void need(bool x,const std::string&s){if(!x)throw std::runtime_error(s+" clock="+std::to_string(clocks));}
 static int command(unsigned n){
  if(n==0)return 4096;if(n==2)return -4095;if(n==5)return 8192;if(n==8)return -8192;
  if(n>=20&&n<400)return int((n*7919u+1109u)%12001)-6000;return 0;
 }
 static int half(int x){return (x>=0?1:-1)*((std::abs(x)+1)/2);}
 static int native_expected(unsigned n){
  if(n<34)return 0;unsigned j=(n-34)/4,offset=(n-34)%4;
  return offset?command(j):half(command(j)+(j?command(j-1):0));
 }
 Bench(){d.clk=0;d.key1=0;d.key2=d.key3=d.key4=1;d.sw=d.mic_sd=0;
  d.inject=d.inject_submit=d.loopback=0;d.inject_zero=1;d.inject_frame=d.inject_word=0;d.eval();}
 void tick(){
  d.clk=0;d.eval();
  if(!d.bclk){
   bool slot=!d.lrck&&decoder_rises>=1&&decoder_rises<=16;
   d.mic_sd=slot?(((uint16_t(clip_source)>>(16-decoder_rises))&1)?1:0)|(((uint16_t(sine_source?source_r:clip_source)>>(16-decoder_rises))&1)?2:0):0;
  }
  d.inject_submit=d.inject&&inject_due&&clocks==inject_due;
  if(d.inject_submit){d.inject_frame=next_frame;d.inject_word=uint32_t(command(next_frame))&0x3ffff;inject_due=0;++inject_count;}
  d.eval();
  bool reset=d.reset_n,clear=d.fx_clear,ready=d.frontend_ready,nv=d.capture_valid,enabled=d.frontend_enable;
  bool frame=d.frame_start,pre_valid=d.tx_valid,pre_fv=d.fv,pre_submit=d.submit;
  unsigned pre_mode=d.active_mode;bool pre_auto=d.active_auto;int pre_word=int16_t(d.tx_word);
  if(reset){
   if(d.fx_selected&&d.fx_running&&!d.fx_clear&&d.frontend_ready){need(d.r64_mismatch==0,"R64_FULL_PRIVATE_HIERARCHY_MITER mask="+std::to_string(d.r64_mismatch));++miter_checks;}
   if(d.guard_state==4&&d.fx_selected&&d.fx_running){if(!first_run_clock)first_run_clock=clocks;++run_clocks;}

   need(!d.ref_phase_mismatch,"ACTUAL_SHARED_ADC_TX_PHASE_IDENTITY");
   need(!d.pair_overrun,"STICKY_TX_OVERRUN");
   if(d.pending)need(!d.tx_valid,"MODE_PENDING_IMMEDIATE_VALID_MUTE");
   if(d.active_auto&&d.active_mode==3&&!d.pending&&d.fx_selected) {
    need(bool(d.tx_valid)==bool(d.capture_valid),"FX_NATIVE_TX_VALID_DIRECT_NO_DECIMATION");
    need(d.tx_word==d.fx_word,"FX_NATIVE_TX_WORD_IDENTITY");
    need(!d.anc_enabled,"FIXED_DISABLED_WHILE_FX");
   }
   if(d.core_done&&!d.inject){need(d.diag_s_words==152&&d.diag_f_words==152&&d.diag_crc_s_out==EXPECTED_S_CRC&&d.diag_crc_f_out==EXPECTED_F_CRC,"ACTUAL_ROM_READ_CRC_GOLDEN");need(d.core_elapsed<=3563,"REAL_CORE_DEADLINE");real_maximum=std::max(real_maximum,unsigned(d.core_elapsed));++real_jobs;}
   if(d.native_clip){need(expect_hard_fault&&std::abs(clip_source)>30000,"RAW_CLIP_UNSIGNED_CAST_GOLDEN");++raw_clip_checks;}
   if(!clear&&d.fx_running&&!expect_hard_fault)need(!d.core_fault&&!d.actuator_fault&&!d.overlap,"REAL_FX_PIPELINE_FAULT reason="+std::to_string(d.guard_reason));
  }
  if(!reset||clear||!ready){
   history.clear();model_phase=model_group=native_index=0;last_fv=0;expected_fv_cycle=0;
   if(d.inject){inject_due=0;inject_count=0;next_frame=0;}
  }else{
   unsigned expected_phase=model_phase;
   if(negative&&native_checks>10)expected_phase=(expected_phase+1)%4;
   need(d.native_phase==expected_phase&&d.native_group==model_group,"NATIVE_PHASE_GOLDEN");++phase_checks;
   if(nv){
    if(sine_source){double phase=6.2831853071795864769*500.*double(tone_n++)/(50000000./1040.);clip_source=int(std::llround(200.*std::sin(phase)));source_r=int(std::llround(600.*std::sin(phase+.4)));}

    if(last_native)need(clocks-last_native==1040,"ACTUAL_ADC_NATIVE_INTERVAL_1040");last_native=clocks;
    if(enabled){
     history.push_front({int16_t(d.mic0),int16_t(d.mic1)});if(history.size()>63)history.pop_back();
     if(d.inject&&d.loopback){int expected=native_expected(native_index);
      if(!d.inject_zero||native_index>=mute_native_start+4){
       if(d.inject_zero){expected=0;++muted_loop_checks;}
       need(int16_t(d.mic0)==expected&&int16_t(d.mic1)==expected,"NONZERO_SHARED_WRAPPER_I2S_LOOP_GOLDEN n="+std::to_string(native_index)+" got="+std::to_string(int16_t(d.mic0))+" expected="+std::to_string(expected));
       if(expected)++nonzero_loop;
      }
     }
     ++native_checks;++native_index;
     if(model_phase==3){
      need(!expected_fv_cycle,"FIR_JOB_OVERLAP");
      for(unsigned ch=0;ch<2;ch++){int64_t sum=0;for(unsigned k=0;k<history.size();k++)sum+=int64_t(fir_q15[k])*history[k][ch];
       int v=int((sum>=0?1:-1)*((std::abs(sum)+16384)/32768));expected_fir[ch]=v>32767?32767:v< -32768?-32768:v;}
      // 此处在接受沿之前，fv在其后134拍产生；下一次pre-edge观察为+135。
      expected_fv_cycle=clocks+1+134;
     }
    }
    model_phase=(model_phase+1)%4;if(!model_phase)model_group=(model_group+1)&65535;
   }
   if(pre_fv){
    need(clocks==expected_fv_cycle,"REAL_FIR_LATENCY_134 got="+std::to_string(clocks)+" due="+std::to_string(expected_fv_cycle));
    need(int16_t(d.fe)==expected_fir[0]&&int16_t(d.fr)==expected_fir[1],"INDEPENDENT_DUAL_FIR_GOLDEN");
    need(!d.filter_clipped,"FIR_UNEXPECTED_CLIP");expected_fv_cycle=0;++fir_checks;
    if(last_fv)need(clocks-last_fv==4160,"CONTROL_INTERVAL_4160");last_fv=clocks;
    if(d.inject){need(!inject_due,"INJECT_JOB_OVERLAP");next_frame=d.control_id;inject_due=clocks+3900;}
   }
   if(pre_submit){
    unsigned ahead=uint16_t(d.command_frame+8-d.native_group);
    need(ahead<=8&&(ahead||(!nv&&d.native_phase==0)),"ACTUAL_SUBMIT_FRAME_DEADLINE");
    int signed_command=d.command&0x20000?int(d.command)-0x40000:int(d.command);
    need(signed_command>=-12288&&signed_command<=12288,"R64_SUBMIT_SIGNED_RANGE_12288");++submit_checks;
   }
  }
  // 独立完整pair队列与DIN位序黄金，不读DUT pending寄存器。
  if(!reset){pending_pair=current_pair=false;pending_word=current_word=0;decoder_rises=0;decoder_w=true;left=right=0;prior_b=false;}
  else{
   if(frame){current_pair=pending_pair;current_word=pending_pair?pending_word:0;pending_pair=false;}
   if(pre_valid){need(!pending_pair,"INDEPENDENT_TX_ONE_PAIR_OVERFLOW");pending_pair=true;pending_word=uint16_t(pre_word);}
  }
  Verilated::timeInc(10);d.clk=1;d.eval();++clocks;
  if(reset&&d.reset_n){
   if(d.active_mode!=pre_mode||d.active_auto!=pre_auto){need(frame,"MODE_CHANGE_OUTSIDE_R_TO_L");++mode_checks;}
   if(d.lrck!=decoder_w){decoder_w=d.lrck;decoder_rises=0;}
   if(!prior_b&&d.bclk){
    if(decoder_rises>=1&&decoder_rises<=16){
     if(!d.lrck)left=uint16_t((left<<1)|d.din);
     else{right=uint16_t((right<<1)|d.din);if(decoder_rises==16){
      need(left==current_word&&right==current_word,"NONZERO_COMPLETE_STEREO_WORD_GOLDEN");++stereo_checks;if(current_word)++nonzero_stereo;
     }}
    }++decoder_rises;
   }prior_b=d.bclk;
  }
  for(unsigned i=0;i<6;i++)if(d.seg_sel==(63^(1<<i)))digits[i]=d.seg_data;
  Verilated::timeInc(10);
 }
 void run(unsigned n){for(unsigned i=0;i<n;i++)tick();}
 void sw(unsigned s){d.sw=s;run(5000);}
 void press(unsigned key){if(key==2)d.key2=0;else if(key==3)d.key3=0;else d.key4=0;run(1100000);d.key2=d.key3=d.key4=1;run(1100000);}
 void boot(){d.key1=0;run(100);d.key1=1;run(300000);last_native=0;}
 void execute(){
  boot();sw(12);need(d.fx_selected&&!d.armed&&!d.fx_running,"FX_ENTRY_DISARMED");
  press(3);need(!d.fx_running,"KEY3_REQUIRES_ARM");
  press(2);need(d.armed&&!d.fx_running,"KEY2_ARM");
  press(3);need(d.fx_running&&(d.guard_state==1||d.guard_state==2),"KEY3_NO_OLD_CAPTURE_GATE");
  run(500000);need(d.core_maximum>0&&d.core_maximum<=3563&&real_jobs>100,"REAL_R61_CORE_JOBS max="+std::to_string(d.core_maximum)+" jobs="+std::to_string(real_jobs));
  need(d.core_zero&&d.fx_word==0,"SILENT_SOURCE_LEARN_STAYS_MUTED");
  press(2);need(!d.fx_running&&d.armed,"KEY2_STOP_TO_ARM");
  press(4);need(d.fx_running,"KEY4_RESTART_FROM_ARM");
  press(4);need(d.fx_running,"KEY4_RESTART_WHILE_LEARNING");
  sw(4);need(!d.fx_selected&&!d.armed&&!d.fx_running&&d.anc_enabled==0,"SW4_FIXED_CLEARS_FX");
  need(d.fixed_hz==500,"FIXED500_REENTRY");
  sw(1);need(d.active_mode==1&&!d.fx_selected,"FX_TO_LIVE");
  sw(2);need(d.active_mode==2&&!d.fx_selected,"LIVE_TO_TF");
  sw(5);need(d.conflict&&d.active_mode==0&&!d.armed,"SW_CONFLICT_MUTE");
  // 新epoch，生产ADC/TX真实回环；仅核心提交口作非零命令诊断注入。
  d.sw=0;boot();sw(12);press(2);
  d.inject=1;d.loopback=1;d.inject_zero=0;press(3);run(1000000);
  need(nonzero_loop>100&&nonzero_stereo>100&&inject_count>200,"NONZERO_G16_DIAGNOSTIC_COVERAGE loop="+std::to_string(nonzero_loop)+" stereo="+std::to_string(nonzero_stereo)+" injected="+std::to_string(inject_count)+" running="+std::to_string(d.fx_running)+" armed="+std::to_string(d.armed)+" phase="+std::to_string(d.native_phase));
  mute_native_start=native_index;d.inject_zero=1;run(20000);need(d.fx_word==0&&muted_loop_checks>=10,"FORCE_ZERO_CANCELS_QUEUED_WORDS");
  d.inject=0;d.loopback=0;run(100000);need(d.core_zero&&d.fx_word==0,"RELEASE_RETURNS_TO_REAL_CORE");
  sw(4);need(!d.fx_selected&&!d.fx_running&&!d.armed,"DIAGNOSTIC_EXIT_FIXED");
  sw(1);run(5000);need(!d.pair_overrun&&!d.actuator_fault,"NORMAL_MODE_NO_STICKY_OVERRUN");
  sw(0);run(5000);
  // 真实物理输入位流的正/负削顶，验证 unsigned 外壳到 signed 保护比较。
  for(int source:{30001,-30001}){
   clip_source=0;expect_hard_fault=false;d.sw=0;boot();sw(12);press(2);press(3);
   uint64_t before=raw_clip_checks;expect_hard_fault=true;clip_source=source;run(6000);
   need(raw_clip_checks>before&&d.core_fault&&d.core_zero&&d.fx_word==0,"SIGNED_RAW_CLIP_HARD_MUTE source="+std::to_string(source));
   need(d.diag_first_valid&&(d.diag_first_fault&1)&&(d.diag_first_native&3),"FIRST_NATIVE_CLIP_SNAPSHOT");
   clip_source=0;sw(0);
  }
 }
};
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);try{
 Bench b;b.boot();b.sine_source=true;b.sw(12);b.press(2);b.press(3);b.run(270000000);
 b.need(b.d.guard_state==4&&!b.d.core_zero&&!b.d.core_fault&&!b.d.actuator_fault,"REAL_CORE_NONZERO_RUN_REQUIRED state="+std::to_string(b.d.guard_state)+" reason="+std::to_string(b.d.guard_reason));
 b.need(b.nonzero_stereo>1000&&b.run_clocks>5000000&&b.miter_checks>250000000,"REAL_RUN_MITER_COVERAGE");
 b.press(2);b.run(5000);b.need(!b.d.fx_running&&b.d.fx_word==0,"RUN_STOP_CANCELS_ACTUATOR");
 std::ofstream f(argv[1]);f<<"{\"status\":\"PASS_REAL_FULL_BUSINESS_NONZERO_RUN_R64_HIERARCHY_MITER\",\"clock_period_ns\":20,\"clocks\":"<<b.clocks
 <<",\"miter_clocks\":"<<b.miter_checks<<",\"first_RUN_clock\":"<<b.first_run_clock<<",\"RUN_clocks\":"<<b.run_clocks<<",\"nonzero_stereo_pairs\":"<<b.nonzero_stereo
 <<",\"core_maximum_clocks\":"<<b.real_maximum<<",\"submit_injection\":false,\"acoustic_closed_loop_or_reduction_measurement\":false}\n";
 std::cout<<"PASS_R65_FULL_RUN_R64_MITER clocks="<<b.clocks<<" miter="<<b.miter_checks<<" RUN="<<b.run_clocks<<" nonzero_stereo="<<b.nonzero_stereo<<std::endl;return 0;
}catch(const std::exception&e){std::cerr<<"FAIL_R65_FULL_RUN "<<e.what()<<std::endl;return 1;}}
