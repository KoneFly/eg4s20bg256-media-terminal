#include "Vr61_fxn_golden_tb.h"
#include "verilated.h"
#include "integer_reference_r06.hpp"
Vec effective(const std::string&root,int channel,int plant=0){auto h=path(root,plant,channel,0),g=readvec("tb/native_effective_kernel.f64");Vec out(h.size()+g.size()-1);for(size_t a=0;a<h.size();a++)for(size_t b=0;b<g.size();b++)out[a+b]+=h[a]*g[b];return out;}
void require(bool b,const std::string&s){if(!b)throw std::runtime_error(s);}
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);Vr61_fxn_golden_tb d;uint64_t clocks=0,oracle_clocks=0,weight_terms=0;size_t n=0;
 auto tick=[&](){d.clk=0;d.eval();d.clk=1;d.eval();clocks++;};
 auto golden_tick=[&](){d.oracle_clk=0;d.eval();d.oracle_clk=1;d.eval();oracle_clocks++;};
 try{
  std::string root=argc>1?argv[1]:"../measured_motor01_20261031";size_t count=argc>2?std::stoul(argv[2]):1024;
  unsigned plant=argc>3?std::stoul(argv[3]):0;bool negative=argc>4&&std::stoul(argv[4])!=0;
  auto base=readvec(root+"/inputs/d.f64"),ref=readvec(root+"/inputs/x.f64"),hp=readvec(root+"/inputs/hp.f64"),ohp=readvec(root+"/inputs/objhp.f64"),lp=readvec(root+"/inputs/lp900.f64");auto Sh=effective(root,0),Fh=effective(root,1),S=effective(root,0,plant==1),F=effective(root,1,plant==1);if(plant==2)for(auto&v:S)v=-v;
  IntegerControl c(Sh,Fh,hp,ohp,lp);IntegerSOS pe(ohp,lp),pr(ohp,lp);I ep=0,rp=0,pv=0,pp=0;Ring output_history;
  d.clk=d.oracle_clk=0;d.rst_n=0;d.clear=d.oracle_arm=d.sample_valid=d.oracle_sample=d.oracle_commit=d.native_fault=d.oracle_hard=0;d.mode_enabled=d.model_valid=1;d.model_epoch=1;d.stop=0;tick();golden_tick();
  d.rst_n=1;d.clear=d.oracle_arm=1;tick();golden_tick();d.clear=d.oracle_arm=0;while(!d.ready)tick();
  unsigned max_latency=0,run_frames=0;int first_run=-1;I maximum_output=0;uint64_t limited_frames=0;
  for(n=0;n<count;n++){
   output_history.put(0);double observed_error=base[n]+dot(S.data()+1,output_history.data()+1,S.size()-1),observed_ref=ref[n]+dot(F.data()+1,output_history.data()+1,F.size()-1);
   I ei=std::llround(std::clamp(observed_error,-32768.,32767.)),ri=std::llround(std::clamp(observed_ref,-32768.,32767.));auto previous_weights=c.w;auto previous_clips=c.output_clips;c.step(ei,ri);bool expected_clip=c.output_clips!=previous_clips;
   I clean=ri*4096-rounding(integer_dot(c.f,c.actual.data(),1),3);I eq4=rounding(pe.step(ei*4096),8),rq4=rounding(pr.step(clean),8);
   ep+=rounding((eq4*eq4-ep)*436,20);rp+=rounding((rq4*rq4-rp)*436,20);I ve=c.last_virtual_error_q4,pq=c.last_primary_objective_q4;pv+=rounding((ve*ve-pv)*436,20);pp+=rounding((pq*pq-pp)*436,20);
   bool hard=std::abs(observed_error)>30000||std::abs(observed_ref)>30000||c.filter_saturations()||c.history_saturations||c.weight_bounds||pe.saturations||pr.saturations||c.primary_objective.saturations;
   d.oracle_hard=hard;d.oracle_band=c.gate_open;d.oracle_virtual=pp>256&&pv*5<pp*4;d.oracle_error_power=ep;d.oracle_reference_power=rp;d.oracle_sample=1;d.oracle_commit=n%256==0;golden_tick();d.oracle_sample=d.oracle_commit=0;
   bool expected_adapt=d.oracle_adapt;uint32_t expected_gain=d.oracle_gain;unsigned expected_state=d.oracle_state,expected_reason=d.oracle_reason;
   if(!expected_adapt)c.w=previous_weights;if(negative&&n==512&&expected_adapt)c.w[0]++;I accepted=d.oracle_zero?0:rounding(c.virtualy.data()[0]*I(expected_gain),24);c.actual.set(accepted);output_history.set(accepted);
   for(int i=1;i<72;i++)golden_tick();
   require(d.ready&&!d.kernel_fault,"not ready for input");d.error_pcm=uint16_t(ei);d.reference_pcm=uint16_t(ri);d.frame_id=n&65535;d.sample_valid=1;tick();d.sample_valid=0;
   unsigned latency=0,writes=0,submits=0;
   while(!d.sample_done){
    d.clk=0;d.eval();
    if(d.debug_weight_write){require(expected_adapt&&d.debug_weight_address==writes&&int32_t(d.debug_weight)==c.w[writes],"CORE_WEIGHT_GOLDEN index="+std::to_string(writes)+" got="+std::to_string(int32_t(d.debug_weight))+" expected="+std::to_string(c.w[writes]));writes++;}
    if(d.command_submit){require(d.command_frame==(n&65535),"output timestamp");submits++;}
    tick();require(!d.kernel_fault,"kernel fault latency="+std::to_string(latency)+" guard_reason="+std::to_string(d.guard_reason));require(++latency<4160,"frame deadline");
   }
   require(writes==(expected_adapt?256u:0u)&&submits==1,"update or output count");
   require(int16_t(d.debug_virtual)==c.virtualy.data()[0],"CORE_VIRTUAL_OUTPUT_GOLDEN got="+std::to_string(int16_t(d.debug_virtual))+" expected="+std::to_string(c.virtualy.data()[0]));
   require(bool(d.debug_clipped)==expected_clip,"CORE_CLIP_TELEMETRY_GOLDEN");
   require(d.debug_band==c.gate_open&&d.debug_adapt==expected_adapt&&d.debug_gain==expected_gain,"CORE_PERMISSION_GOLDEN");
   require(d.debug_error_power==uint64_t(ep)&&d.debug_reference_power==uint64_t(rp),"CORE_MONITOR_POWER_GOLDEN");
   require(d.guard_state==expected_state&&d.guard_reason==expected_reason,"CORE_GUARD_STATE_GOLDEN");
   int32_t actual=int32_t(d.command);if(actual&0x20000)actual|=~0x3ffff;require(actual==accepted,"CORE_ACCEPTED_COMMAND_GOLDEN");maximum_output=std::max(maximum_output,I(std::abs(actual)));limited_frames+=d.debug_clipped;
   weight_terms+=writes;if(latency>max_latency)max_latency=latency;if(d.guard_state==4){run_frames++;if(first_run<0)first_run=n;}
   if(n%8192==8191)std::cout<<"CORE_FRAME_COMPLETE="<<n+1<<" max_latency="<<max_latency<<" guard="<<int(d.guard_state)<<std::endl;
  }
  if(argc>5&&std::stoul(argv[5]))require(maximum_output>8192&&maximum_output<=12288,"NEW_HEADROOM_PATH_NOT_EXERCISED");
  std::cout<<"PASS_R65_FULL_KERNEL_INTEGER_GOLDEN frames="<<count<<" weight_terms="<<weight_terms<<" max_request_to_done_clocks="<<max_latency<<" first_RUN_frame="<<first_run<<" RUN_frames="<<run_frames<<" max_output_PCM="<<maximum_output<<" limit_frames="<<limited_frames<<" clocks="<<clocks<<" independent_guard_clocks="<<oracle_clocks<<std::endl;return 0;
 }catch(const std::exception&e){std::cerr<<"FAIL_R61_FULL_KERNEL "<<e.what()<<" frame="<<n<<" clocks="<<clocks<<std::endl;return 1;}}
