#include "Vr61_guard_default_tb.h"
#include "verilated.h"
#include "integer_reference_r06.hpp"
#include <filesystem>
struct Case{int id,low,high;double refamp,primary_gain;int primary_delay,plant,freeze_run;I mu;int recovery;};
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);try{
 std::string outroot=argc>1?argv[1]:"evidence",casefile=argc>2?argv[2]:"inputs/cases.txt";
 auto hp=readvec("inputs/hp.f64"),ohp=readvec("inputs/objhp.f64"),lp=readvec("inputs/lp900.f64"),Sh=readvec("inputs/full_0.f64"),Fh=readvec("inputs/full_1.f64");
 std::ifstream in(casefile);std::ofstream summary(outroot+"/headroom_models.jsonl");Case test;
 while(in>>test.id>>test.low>>test.high>>test.refamp>>test.primary_gain>>test.primary_delay>>test.plant>>test.freeze_run>>test.mu>>test.recovery){
  auto source=readvec("inputs/tone_"+std::to_string(test.low)+"_"+std::to_string(test.high)+".f64");auto S=readvec(test.plant?"inputs/half_0.f64":"inputs/full_0.f64"),F=readvec(test.plant?"inputs/half_1.f64":"inputs/full_1.f64");
  IntegerControl c(Sh,Fh,hp,ohp,lp);c.mu_q24=test.mu;c.clip_recovery=test.recovery;IntegerSOS pe(ohp,lp),pr(ohp,lp);I ep=0,rp=0,pv=0,pp=0;Ring yh;
  Vr61_guard_default_tb g;auto tick=[&](){g.clk=0;g.eval();g.clk=1;g.eval();};g.rst_n=0;g.arm=g.stop=g.sample_valid=g.power_commit=g.hard_fault=0;tick();g.rst_n=1;g.arm=1;tick();g.arm=0;
  unsigned run=0,adapt=0,changed=0,zero_gain=0,clipped=0,rawbad=0;int first_run=-1;double dp=0,er=0,maxy=0;unsigned wrun=0,wadapt=0,wchange=0,wzero=0,wclip=0;
  std::ofstream windows(outroot+"/case"+std::to_string(test.id)+"_windows.jsonl");std::vector<double> powers;size_t window_start=0;Vec residual(source.size()),emitted(source.size()),states(source.size());
  for(size_t n=0;n<source.size();n++){
   double d=n>=size_t(test.primary_delay)?test.refamp*test.primary_gain*source[n-test.primary_delay]:0.;yh.put(0);double e=d+dot(S.data()+1,yh.data()+1,S.size()-1),r=test.refamp*source[n]+dot(F.data()+1,yh.data()+1,F.size()-1);bool bad=std::abs(e)>30000||std::abs(r)>30000;rawbad+=bad;
   I ei=std::llround(std::clamp(e,-32768.,32767.)),ri=std::llround(std::clamp(r,-32768.,32767.));auto previous=c.w;auto before_clip=c.output_clips;c.step(ei,ri);bool did_clip=c.output_clips!=before_clip;
   I clean=ri*4096-rounding(integer_dot(c.f,c.actual.data(),1),3),eq=rounding(pe.step(ei*4096),8),rq=rounding(pr.step(clean),8);ep+=rounding((eq*eq-ep)*436,20);rp+=rounding((rq*rq-rp)*436,20);
   I ve=c.last_virtual_error_q4,pq=c.last_primary_objective_q4;pv+=rounding((ve*ve-pv)*436,20);pp+=rounding((pq*pq-pp)*436,20);
   g.band_ok=c.gate_open;g.virtual_ready=pp>256&&pv*5<pp*4;g.hard_fault=bad||c.filter_saturations()||c.primary_objective.saturations||c.history_saturations||c.weight_bounds||pe.saturations||pr.saturations;g.error_power=std::max(I(0),ep);g.reference_power=std::max(I(0),rp);g.sample_valid=1;g.power_commit=n%256==0;tick();g.sample_valid=g.power_commit=0;
   bool allow=g.adapt&&!(test.freeze_run&&g.state==4);if(!allow)c.w=previous;bool did_change=c.w!=previous;
   I y=g.force_zero?0:rounding(c.virtualy.data()[0]*I(g.gain),24);if(std::abs(y)>12288)throw std::runtime_error("OUTPUT_BOUND");c.actual.set(y);yh.set(y);maxy=std::max(maxy,double(std::abs(y)));residual[n]=e;emitted[n]=y;states[n]=g.state;
   if(g.state==4){if(first_run<0)first_run=int(n);run++;wrun++;}adapt+=allow;changed+=did_change;zero_gain+=c.last_gain==0;clipped+=did_clip;wadapt+=allow;wchange+=did_change;wzero+=c.last_gain==0;wclip+=did_clip;dp+=d*d;er+=e*e;
   for(int k=1;k<72;k++)tick();
   if(n+1==source.size()||n+1>=size_t(std::llround((powers.size()+1)*FS))){double t0=window_start/FS,t1=(n+1)/FS,tm=.5*(t0+t1),f=test.low;if(tm>=10&&tm<30)f+=(test.high-test.low)*(tm-10)/20;else if(tm>=30&&tm<40)f=test.high;else if(tm>=40&&tm<60)f=test.high-(test.high-test.low)*(tm-40)/20;
    double db=10*std::log10(std::max(1e-30,dp)/std::max(1e-30,er));powers.push_back(db);windows<<std::setprecision(12)<<"{\"start_s\":"<<t0<<",\"end_s\":"<<t1<<",\"frequency_mid_Hz\":"<<f<<",\"reduction_RMS_db\":"<<db<<",\"RUN_samples\":"<<wrun<<",\"adapt_samples\":"<<wadapt<<",\"weight_changed_samples\":"<<wchange<<",\"zero_gain_samples\":"<<wzero<<",\"clipped_samples\":"<<wclip<<",\"state_end\":"<<int(g.state)<<",\"reason\":"<<int(g.reason)<<"}\n";
    window_start=n+1;dp=er=0;wrun=wadapt=wchange=wzero=wclip=0;
   }
  }
  auto avg=[&](int a,int b){double s=0;for(int i=a;i<b;i++)s+=powers[i];return s/(b-a);};
  summary<<std::setprecision(12)<<"{\"case\":"<<test.id<<",\"range_Hz\":["<<test.low<<","<<test.high<<"],\"reference_peak_PCM\":"<<test.refamp<<",\"primary_gain_assumed\":"<<test.primary_gain<<",\"primary_delay_frames_assumed\":"<<test.primary_delay<<",\"plant\":"<<test.plant<<",\"mu\":"<<test.mu/double(1<<24)<<",\"freeze_RUN_negative_control\":"<<test.freeze_run<<",\"initial_hold_db\":"<<avg(7,10)<<",\"up_sweep_db\":"<<avg(11,29)<<",\"upper_hold_db\":"<<avg(33,39)<<",\"down_sweep_db\":"<<avg(41,59)<<",\"last_hold_db\":"<<avg(65,69)<<",\"first_RUN_s\":"<<first_run/FS<<",\"RUN_samples\":"<<run<<",\"adapt_samples\":"<<adapt<<",\"weight_changed_samples\":"<<changed<<",\"zero_gain_samples\":"<<zero_gain<<",\"output_clip_samples\":"<<clipped<<",\"raw_fault_samples\":"<<rawbad<<",\"filter_saturations\":"<<c.filter_saturations()+c.primary_objective.saturations+pe.saturations+pr.saturations<<",\"history_saturations\":"<<c.history_saturations<<",\"weight_box_events\":"<<c.weight_box_bounds<<",\"max_output_PCM\":"<<maxy<<",\"final_state\":"<<int(g.state)<<"}\n";summary.flush();
  // 截止前保留逐秒窗口/汇总，省去大体积逐样本数组导出。
  std::cout<<"SWEEP_CASE_COMPLETE="<<test.id<<" up="<<avg(11,29)<<" down="<<avg(41,59)<<" clips="<<clipped<<" final="<<int(g.state)<<std::endl;
 }
 return 0;
}catch(const std::exception&e){std::cerr<<"SWEEP_DIAGNOSTIC_FAIL "<<e.what()<<std::endl;return 1;}}
