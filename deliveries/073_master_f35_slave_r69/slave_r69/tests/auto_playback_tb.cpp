// 真实媒体/ADC/DIN独立黄金；固定预设功能取舍，不声明R57追频等价/声学dB。
#include "Vauto_playback_tb.h"
#include "verilated.h"
#include "fixed_preset_golden.h"
#include <array>
#include <deque>
#include <vector>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>

struct Bench{
 FixedPresetGolden anc_golden;
 std::array<uint64_t,3> fixed_run_samples{};bool negative_fixed=false;
 uint64_t independent_anc_samples=0;
 double noise_phase=0,drift_time=0,drift_primary_power=0,drift_error_power=0,drift_db=0,drift_final_hz=0;
 uint64_t drift_frames=0;uint32_t adc_noise_rng=20261030;bool drifting=false;
 double noise_frequency=500.;int noise_amplitude=700,mic_dc=0;
 Vauto_playback_tb d;uint64_t cycles=0,frames=0,source_start=0,live_pairs=0,anc_pairs=0,core_checks=0,adc_checks=0,raw_checks=0,groups=0,run_valid=0;
 unsigned block=0,packet=0,mic_rises=0,decoder_rises=0;
 uint64_t tf_pairs=0,tf_samples_checked=0,tf_words_checked=0,silent_pairs=0,cal_windows=0;
 bool pending_silent=false,current_silent=false,previous_cal=false;
 bool pending_tf=false,current_tf=false,model_receiving=false,model_high_pending=false,model_playing=false,model_fault=false;
 bool tf_gold_valid=false;
 uint16_t tf_gold_sample=0,model_high=0;
 uint32_t model_first=0;unsigned model_word=0;
 std::deque<uint16_t> tf_fifo;std::vector<uint16_t> tf_block;
 static uint16_t tf_source(uint32_t i){return uint16_t(i*73u+0x1234u);}
 void clear_tf_model(){tf_fifo.clear();tf_block.clear();model_receiving=model_high_pending=model_playing=false;}
 void step_tf_model(){
  tf_gold_valid=d.reset_n&&d.player_selected&&d.capture_valid;tf_gold_sample=0;
  bool failure=d.pb_input_fault||(!d.pb_reset&&((d.pb_start&&(model_receiving||tf_fifo.size()>1760))||
      (d.pb_word_valid&&model_receiving&&model_high_pending)||(d.capture_valid&&model_playing&&tf_fifo.empty())));
  if(!d.reset_n||!d.player_selected){clear_tf_model();model_fault=false;}
  else if(failure||model_fault){model_fault=true;clear_tf_model();}
  else if(d.pb_reset){clear_tf_model();model_receiving=d.pb_start;model_first=d.pb_first;model_word=0;}
  else{
   if(d.capture_valid&&(model_playing||tf_fifo.size()>=1152)&&!tf_fifo.empty()){
    tf_gold_sample=tf_fifo.front();tf_fifo.pop_front();model_playing=true;++tf_samples_checked;
   }
   bool previous=model_receiving;
   if(d.pb_start){model_receiving=true;tf_block.clear();model_word=0;model_first=d.pb_first;model_high_pending=false;}
   if(model_high_pending&&previous){
    tf_block.push_back(model_high);model_high_pending=false;
    if(tf_block.size()==288){tf_fifo.insert(tf_fifo.end(),tf_block.begin(),tf_block.end());tf_block.clear();model_receiving=false;}
   }else if(d.pb_word_valid&&previous){
    uint16_t lo=tf_source(model_first+2*model_word),hi=tf_source(model_first+2*model_word+1);
    require(uint16_t(d.pb_word_data)==lo&&uint16_t(d.pb_word_data>>16)==hi,"TF_RX_FULL16_SOURCE_GOLDEN");
    tf_block.push_back(lo);model_high=hi;model_high_pending=true;++model_word;++tf_words_checked;
   }
  }
 }
 uint16_t crc=0xffff,left=0,right=0,ref_left=0,ref_right=0;
 bool packet_sent=false,prior_b=false,prior_w=true,decoder_w=true,tx_b=false,tx_w=true,pending=false,current=false,pending_anc=false,current_anc=false;
 bool noise=false,negative=false,pulse_noise=false;
 int mean_gold=0,plant_y=0,pending_pcm=0,current_pcm=0,max_y=0;
 std::array<uint32_t,3> words{};std::array<uint16_t,4> held{};
 std::array<uint8_t,128> raw_spectrum{};unsigned raw_bins=0,post_bins=0;
 void require(bool okay,const std::string&s){if(!okay)throw std::runtime_error(s+" cycle="+std::to_string(cycles));}
 Bench(){d.clk=0;d.key1=0;d.key2=d.key3=d.key4=1;d.sw=0;d.mic_sd=0;d.packet_valid=0;d.packet_kind=1;for(int i=0;i<3;i++)d.packet_data[i]=0;d.eval();}
 static uint16_t crc_byte(uint16_t c,uint8_t b){c^=uint16_t(b)<<8;for(int j=0;j<8;j++)c=uint16_t(c&0x8000?(c<<1)^0x1021:c<<1);return c;}
 void drive_packet(){
  d.packet_valid=0;packet_sent=false;
  if(!d.key1||cycles<source_start+120000+uint64_t(block)*288*1040||!d.packet_ready)return;
  if(packet<48){for(unsigned j=0;j<3;j++){
   unsigned i=block*288+packet*6+j*2;words[j]=tf_source(i)|(uint32_t(tf_source(i+1))<<16);
  }d.packet_kind=1;}else{words={1u,block*288u,(288u<<16)|crc};d.packet_kind=3;}
  for(int j=0;j<3;j++)d.packet_data[j]=words[j];d.packet_valid=1;packet_sent=true;
 }
 void commit_packet(){if(!packet_sent)return;if(packet<48){for(uint32_t w:words)for(int b=0;b<4;b++)crc=crc_byte(crc,uint8_t(w>>(8*b)));++packet;}else{++block;packet=0;crc=0xffff;}}
 void drive_mic(){unsigned bits=0;if(!d.lrck&&mic_rises>=1&&mic_rises<=16)for(unsigned k=0;k<4;k++)bits|=((held[k]>>(16-mic_rises))&1)<<k;d.mic_sd=bits;}
 void tick(){
  d.clk=0;d.eval();drive_packet();d.eval();
  bool pre_reset=d.reset_n,pre_b=d.bclk,pre_w=d.lrck,pre_valid=d.tx_pair_valid,pre_anc=d.anc_active;
  bool pre_tf=d.tf_active,pre_silent=d.active_mode==0||(d.active_mode==3&&!pre_anc);
  int pre_pcm=pre_anc?anc_golden.published:pre_tf?int(int16_t(tf_gold_sample)):pre_silent?0:mean_gold;
  bool start=tx_b&&!pre_b&&tx_w&&!pre_w;
  if(!pre_reset||!pre_anc)anc_golden.reset();
  else if(d.core_command){
   anc_golden.automatic=d.auto_mode;anc_golden.override_enabled=d.core_override;anc_golden.requested_increment=d.auto_increment;
   anc_golden.command(d.manual_tone);
  }else if(d.capture_valid){
   if(d.anc_ready){require(d.manual_tone<3&&d.fll_increment==independent_anc::INC[d.manual_tone]&&d.fll_increment==anc_golden.selected_increment&&!d.fll_busy,"FIXED_SELECTED_PRESET_PHASE_BINDING");++fixed_run_samples[d.manual_tone];} anc_golden.wrong_phase_negative=negative_fixed;
   if(drifting&&d.anc_ready){++drift_frames;if(drift_frames>48077){
    double original=noise_amplitude*std::sin(noise_phase);double residual=int(int16_t(d.mic0))-mic_dc;
    drift_primary_power+=original*original;drift_error_power+=residual*residual;}}
   anc_golden.sample(int(int16_t(d.mic0)));++independent_anc_samples;}
  step_tf_model();
  d.clk=1;d.eval();commit_packet();++cycles;
  require(bool(d.tf_sample_valid)==tf_gold_valid,"TF_FRAME_VALID_GOLDEN");
  if(d.tf_sample_valid)require(uint16_t(d.tf_sample)==tf_gold_sample,"TF_FIFO_SAMPLE_GOLDEN");
  require(d.tf_level==tf_fifo.size()&&bool(d.tf_fault)==model_fault,"TF_LEVEL_OR_FAULT_GOLDEN");
  require(!d.guard_fault,std::string("UNEXPECTED_R57_RUN_GUARD_ON_NORMAL_SESSION code=")+std::to_string(d.guard_code)+" ready="+std::to_string(d.anc_ready)+" auto="+std::to_string(d.auto_mode)+" command="+std::to_string(d.core_command));
  require(!d.anc_mismatch,"ANC_CORE_OR_MIC1_DIFF_VS_R40");++core_checks;
  if(d.anc_valid)require(int(int16_t(d.anc_sample))==anc_golden.published,"INDEPENDENT_ANC_SAMPLE_GOLDEN");
  if(d.anc_cal&&!previous_cal)++cal_windows;previous_cal=d.anc_cal;
  if(d.reset_n){
   require(!d.demo_fault&&!d.ref_demo_fault,"INTEGRATED_DEMO_FAULT");require(!d.tx_overrun&&!d.packet_fault,"TRANSPORT_OR_I2S_OVERRUN");
   if(d.capture_valid){
    require(d.mic0==held[0]&&d.mic1==held[1]&&d.mic2==held[2]&&d.mic3==held[3],"REAL_MIC_CAPTURE_GOLDEN");++adc_checks;
    int sum=int(int16_t(held[1]))+int(int16_t(held[2]))+int(int16_t(held[3]));int64_t p=int64_t(sum)*21846;
    mean_gold=int(p>=0?p/65536:-((-p+65535)/65536));
   }
   if(d.pair_valid){require(int(int16_t(d.pair_raw))==mean_gold&&d.pair_post==d.pair_raw,"LIVE_RAW_POST_MUST_BOTH_BE_MEAN");++raw_checks;}
   if(d.anc_valid){plant_y=int(int16_t(d.anc_sample));max_y=std::max(max_y,std::abs(plant_y));if(d.anc_ready)++run_valid;}
   require(!d.anc_fault,"ANC_FAULT");
   if(d.bin_valid){unsigned i=d.bin_index;if(d.path==1){if(i==0)raw_bins=0;raw_spectrum[i]=d.bin_data;++raw_bins;}
    if(d.path==2){if(i==0)post_bins=0;require(raw_bins==128&&d.bin_data==raw_spectrum[i],"POST_SPECTRUM_NOT_RAW_AFTER_TONE_REMOVAL");++post_bins;}}
   if(d.group_done){require(raw_bins==128&&post_bins==128,"MISSING_THREE_PATH_GROUP");++groups;}
  }
  if(pre_reset&&d.reset_n){
   if(start){current=pending;current_pcm=pending_pcm;current_anc=pending_anc;current_tf=pending_tf;current_silent=pending_silent;pending=false;}
   if(pre_valid){require(!pending,"GOLDEN_PAIR_QUEUE_OVERFLOW");pending=true;pending_pcm=pre_pcm;pending_anc=pre_anc;pending_tf=pre_tf&&!pre_anc;pending_silent=pre_silent;}
   tx_b=pre_b;tx_w=pre_w;
  }else{pending=current=false;tx_b=false;tx_w=true;decoder_rises=0;decoder_w=true;left=right=ref_left=ref_right=0;}
  if(prior_w&&!d.lrck){
   ++frames;mic_rises=0;double x=double(frames)/(50000000.0/1040.0);
   double instantaneous=noise_frequency;
   if(drifting){drift_time+=1./(50000000.0/1040.0);instantaneous+=.4*std::sin(2*3.141592653589793*.3*drift_time);}
   noise_phase+=2*3.141592653589793*instantaneous/(50000000.0/1040.0);if(noise_phase>2*3.141592653589793)noise_phase-=2*3.141592653589793;
   int perturb=0;if(drifting){adc_noise_rng=adc_noise_rng*1664525u+1013904223u;perturb=int(adc_noise_rng%11)-5;}
   int err=mic_dc+plant_y/2+perturb+(noise?(pulse_noise?(std::fmod(noise_frequency*x,1.0)<.15?25000:-25000):int(std::lround(noise_amplitude*std::sin(noise_phase)))):0);
   held={uint16_t(int16_t(err)),uint16_t(int16_t(600+plant_y/20+(noise?(pulse_noise?(std::fmod(noise_frequency*x,1.0)<.15?25000:-25000):int(std::lround(noise_amplitude*std::sin(noise_phase)))):0))),
         uint16_t(int16_t(1200*std::sin(2*3.141592653589793*1000*x+.2))),uint16_t(int16_t(1000*std::sin(2*3.141592653589793*1200*x+.5)))};
  }
  if(bool(d.lrck)!=prior_w)mic_rises=0;
  if(bool(d.lrck)!=decoder_w){decoder_w=d.lrck;decoder_rises=0;}
  bool rise=!prior_b&&d.bclk,fall=prior_b&&!d.bclk;
  if(rise){if(decoder_rises>=1&&decoder_rises<=16){
    if(!d.lrck){left=uint16_t((left<<1)|d.din);ref_left=uint16_t((ref_left<<1)|d.ref_din);}
    else{right=uint16_t((right<<1)|d.din);ref_right=uint16_t((ref_right<<1)|d.ref_din);
     if(decoder_rises==16){uint16_t expected=uint16_t(current?current_pcm:0);if(negative&&current_tf&&expected!=0)expected^=1;
      require(left==expected&&right==expected,"COMPLETE_STEREO_FRAME_GOLDEN");
      if(current){if(current_anc)++anc_pairs;else if(current_tf)++tf_pairs;else if(current_silent)++silent_pairs;else ++live_pairs;}
     }}
   }++decoder_rises;++mic_rises;}
  if(fall)drive_mic();prior_b=d.bclk;prior_w=d.lrck;
 }
 void run(uint64_t n){for(uint64_t i=0;i<n;i++)tick();}
 void set_sw(unsigned s){d.sw=s;run(10000);}
 void long_key(){d.key2=0;run(3600000);d.key2=1;run(1200000);}
 void short_key(unsigned key){
  if(key==2)d.key2=0;else if(key==3)d.key3=0;else d.key4=0;
  run(1200000);d.key2=d.key3=d.key4=1;run(1200000);
 }
 void wait_run(){for(unsigned i=0;i<25000000&&!d.anc_ready;i++)tick();require(d.anc_ready,"CALIBRATION_NOT_READY");}
 void execute(){
  run(100);d.key1=1;source_start=cycles;run(300000);
  require(d.active_mode==0&&!d.armed,"RESET_ALL_OFF_MUTE");
  set_sw(1);run(1500000);require(d.active_mode==1&&live_pairs>1000,"SW1_LIVE");
  for(unsigned k=0;k<5;k++){
   set_sw(2);run(4000000);require(d.tf_active&&d.tf_playing&&!d.anc_active,"SW2_REAL_TF");
   set_sw(1);run(300000);require(d.active_mode==1&&!d.tf_active,"SW1_RETURN_LIVE");
  }
  require(tf_samples_checked>10000,"TF_PLAYBACK_COVERAGE");
  set_sw(4);require(d.active_mode==3&&!d.armed&&d.frequency==500,"SW3_DEFAULT500_DISABLED");
  short_key(3);require(!d.armed&&!d.anc_cal&&!d.anc_ready,"KEY3_NEEDS_ARM");
  short_key(2);require(d.armed&&d.anc_active&&!d.anc_cal&&!d.anc_ready,"KEY2_ARM");
  short_key(3);wait_run();noise=true;run(3000000);
  require(run_valid>2000&&max_y>100&&max_y<=8192,"ANC_NONTRIVIAL_COVERAGE");
  noise=false;uint64_t before=cal_windows;short_key(4);wait_run();require(cal_windows==before+1,"KEY4_RECALIBRATION");
  short_key(2);require(d.armed&&!d.anc_ready&&!d.anc_cal,"KEY2_STOP_ARM");
  long_key();require(d.frequency==750&&d.armed&&!d.anc_ready&&!d.anc_cal,"KEY2_LONG_FREQUENCY");
  noise_frequency=750;noise_amplitude=6000;noise=false;short_key(3);wait_run();
  noise=true;run(18000000);require(d.anc_ready&&d.limit_seen,"750_HIGH_SOURCE_BOUNDED_RUN_AND_LIMIT_STATUS");
  noise_amplitude=700;run(12000000);require(d.anc_ready,"750_VOLUME_REDUCTION_RECOVERS_WITHOUT_RECAL");
  noise=false;short_key(2);require(!d.anc_ready,"750_STOP_AFTER_BUDGET");
  long_key();require(d.frequency==250,"THREE_TONES_SKIP_1000_GO_TO_250");
  noise_frequency=250;noise_amplitude=700;noise=false;short_key(3);wait_run();noise=true;run(4000000);
  noise=false;short_key(2);require(!d.anc_ready&&!d.anc_cal,"250_STOP_TO_ARM");
  require(fixed_run_samples[0]>2000&&fixed_run_samples[1]>2000&&fixed_run_samples[2]>2000,"ALL_THREE_FIXED_RUN_MATH_COVERAGE");
  long_key();require(d.frequency==500,"THREE_TONES_RETURN_500");
  noise_frequency=500;noise_amplitude=700;
  set_sw(5);require(d.conflict&&d.active_mode==0&&!d.armed&&!d.anc_active,"MULTI_SW_MUTE");
  set_sw(4);require(!d.conflict&&d.frequency==500&&!d.armed,"ANC_REENTRY_DEFAULT500");
  set_sw(0);require(d.active_mode==0&&!d.anc_active&&!d.tf_active,"ALL_OFF_MUTE");run(10000);
  require(groups>=30&&raw_checks>30000&&silent_pairs>2000,"INTEGRATION_COVERAGE");
 }
};

int main(int argc,char**argv){try{
 Bench b;b.negative=argc>2&&std::string(argv[2])=="negative_tf";b.negative_fixed=argc>2&&std::string(argv[2])=="negative_fixed";b.execute();if(b.negative||b.negative_fixed)throw std::runtime_error("NEGATIVE_NOT_DETECTED");
 std::ofstream f(argv[1]);f<<"{\"status\":\"PASS_CLEAN_FIXED_PRESETS_FULL_MEDIA_SCOPE\",\"cycles\":"<<b.cycles
  <<",\"ANC_cycle_comparisons\":"<<b.core_checks<<",\"ADC_checks\":"<<b.adc_checks<<",\"RAW_mean_pairs\":"<<b.raw_checks
  <<",\"LIVE_DIN_pairs\":"<<b.live_pairs<<",\"ANC_DIN_pairs\":"<<b.anc_pairs<<",\"complete_3path_groups\":"<<b.groups
  <<",\"TF_DIN_pairs\":"<<b.tf_pairs<<",\"TF_samples_independently_checked\":"<<b.tf_samples_checked<<",\"TF_words_checked\":"<<b.tf_words_checked<<",\"silent_DIN_pairs\":"<<b.silent_pairs<<",\"independent_ANC_samples\":"<<b.independent_anc_samples<<",\"calibration_windows\":"<<b.cal_windows<<",\"RUN_valid_samples\":"<<b.run_valid<<",\"synthetic_max_abs_y\":"<<b.max_y
  <<",\"fixed_250_RUN_samples\":"<<b.fixed_run_samples[0]<<",\"fixed_500_RUN_samples\":"<<b.fixed_run_samples[1]<<",\"fixed_750_RUN_samples\":"<<b.fixed_run_samples[2]<<",\"drift55_RMS_attenuation_db\":"<<b.drift_db<<",\"drift55_frames\":"<<b.drift_frames<<",\"drift55_final_hz\":"<<b.drift_final_hz<<",\"not_board_measurement\":true,\"full_machine_regression\":false}\n";
 std::cout<<"PASS_CLEAN_FIXED_PRESETS groups="<<b.groups<<" pairs="<<b.live_pairs+b.anc_pairs<<"\n";
 }catch(const std::exception&e){std::cerr<<e.what()<<"\n";return 1;}}
