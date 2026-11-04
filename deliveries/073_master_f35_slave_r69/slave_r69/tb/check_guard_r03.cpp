#include "Vanc_stability_guard_r61.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>
static void need(bool ok,const char*why){if(!ok)throw std::runtime_error(why);}
struct Bench{
 Vanc_stability_guard_r61 d;uint64_t frames=0;unsigned verifies=0;
 void tick(){d.clk=0;d.eval();if(d.rst_n)need(d.equiv_mask==0,"COUNTER_EQUIVALENCE_BEFORE");d.clk=1;d.eval();if(d.rst_n)need(d.equiv_mask==0,"COUNTER_EQUIVALENCE_AFTER");}
 void power(uint64_t e,uint64_t r){uint64_t ep=e*e,rp=r*r;d.error_power=ep*256;d.reference_power=rp*256;d.ratio_q16=(ep<<16)/rp;d.reference_ok=1;}
 void frame(){d.sample_valid=1;d.ratio_update=frames%256==0;tick();frames++;verifies+=d.state==5;}
 void many(unsigned n){while(n--)frame();}
 void init(){d.rst_n=0;d.mode_enabled=d.model_valid=d.band_ok=d.virtual_ready=1;d.model_epoch=64;d.hard_fault=d.arm=d.stop=d.sample_valid=d.ratio_update=0;d.hard_fault_code=8;power(100,1000);tick();d.rst_n=1;d.arm=1;tick();d.arm=0;while(d.state!=4){frame();need(frames<70000,"initial RUN timeout");}power(50,1000);many(1200);}
 void restored(){power(50,1000);d.virtual_ready=1;for(unsigned n=0;n<21000&&d.state!=4;n++)frame();need(d.state==4,"qualified source did not return RUN");}
 void badref(){power(50,1000);d.reference_ok=0;many(512);}
};
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);bool baseline=argc>1&&std::string(argv[1])=="--baseline";try{
 unsigned cases=0;
 {
  Bench b;b.init();for(unsigned n=0;n<24000;n++){if(b.d.state==5)b.power(300,3000);else b.power(150,3000);b.frame();if(b.d.state==6||b.d.state==7)break;}
  if(baseline)need(b.d.state==7&&b.d.fault_code==5,"R63 counterexample missing");else need(b.d.state==4&&!b.d.force_zero,"beneficial changed source must resume");
  need(b.verifies>0,"OFF verification bypassed");std::cout<<"CASE=beneficial_source state="<<int(b.d.state)<<" reason="<<int(b.d.fault_code)<<" OFF_frames="<<b.verifies<<std::endl;cases++;
 }
 {
  Bench b;b.init();b.badref();
  if(baseline)need(b.d.state==7&&b.d.fault_code==5,"R63 weak-reference stop missing");else{
   need(b.d.state==2&&b.d.force_zero&&!b.d.adapt_enable,"reference pause must mute/freeze");
   b.power(50,1000);b.many(5000);need(b.d.state==2&&b.d.force_zero,"original qualification shortened");
   b.restored();need(!b.d.hold_requires_arm,"qualified reference still manual ARM");
  }
  std::cout<<"CASE=temporary_reference state="<<int(b.d.state)<<" reason="<<int(b.d.fault_code)<<std::endl;cases++;
 }
 if(baseline){std::cout<<"PASS_R63_ORIGINAL_5555_REPRODUCTION cases="<<cases<<std::endl;return 0;}
 {
  Bench b;b.init();b.badref();b.many(30000);need(b.d.state==2&&b.d.force_zero&&!b.d.adapt_enable,"persistent weak reference output");
  b.power(50,1000);b.d.virtual_ready=0;b.many(21000);need(b.d.state==2&&b.d.force_zero,"virtual qualification bypass");b.restored();cases++;
 }
 {
  Bench b;b.init();for(int k=0;k<2;k++){b.badref();need(b.d.state==2,"retry budget consumed early");b.restored();}
  b.badref();need(b.d.state==7&&b.d.fault_code==5&&b.d.force_zero,"unbounded reference retry");
  b.power(100,1000);b.d.arm=1;b.tick();b.d.arm=0;for(unsigned n=0;n<62000&&b.d.state!=4;n++)b.frame();need(b.d.state==4,"manual ARM restart");b.badref();need(b.d.state==2,"manual ARM did not reset bounded budget");cases++;
 }
 {
  Bench b;b.init();for(unsigned n=0;n<8000;n++){b.power(b.d.state==5?100:150,1000);b.frame();if(b.d.state==6)break;}
  need(b.d.state==6&&b.d.fault_code==4&&b.d.force_zero,"confirmed increase protection weakened");b.power(10,1000);b.many(21000);need(b.d.state==6,"confirmed increase auto restart");cases++;
 }
 {
  Bench b;b.init();for(unsigned n=0;n<8000;n++){b.power(b.d.state==5?110:115,1000);b.frame();if(b.d.state==7||b.d.state==6)break;}
  need(b.d.state==7&&b.d.fault_code==5&&b.d.force_zero,"ambiguous OFF comparison restarted");cases++;
 }
 {
  Bench b;b.init();for(unsigned n=0;n<8000;n++){b.power(b.d.state==5?300:150,b.d.state==5?9000:3000);b.frame();if(b.d.state==7)break;}
  need(b.d.state==7&&b.d.fault_code==5,"unstable reference not held");cases++;
 }
 {
  Bench b;b.init();b.badref();b.d.hard_fault=1;b.tick();need(b.d.state==6&&b.d.fault_code==8&&b.d.force_zero,"hard protection during pause");b.d.hard_fault=0;b.power(50,1000);b.many(21000);need(b.d.state==6,"hard fault auto restart");cases++;
 }
 {
  Bench b;b.init();b.d.band_ok=0;b.many(6000);need(b.d.state==2&&b.d.force_zero&&!b.d.adapt_enable,"out-of-band not muted");b.d.band_ok=1;b.restored();cases++;
 }
 {
  Bench b;b.init();b.d.ratio_update=0;b.d.sample_valid=1;for(int n=0;n<1100;n++)b.tick();need(b.d.state==6&&b.d.fault_code==6&&b.d.force_zero,"stale snapshot protection lost");cases++;
 }
 {
  Bench b;b.init();b.d.sample_valid=0;b.d.ratio_update=1;b.d.reference_ok=0;b.d.eval();need(b.d.force_zero&&!b.d.adapt_enable,"invalid snapshot did not mute immediately");b.tick();b.d.ratio_update=0;b.frame();need(b.d.state==2,"pending invalid ratio lost");cases++;
 }
 {
  Bench b;b.init();for(unsigned n=0;n<8000;n++){
   b.d.reference_ok=1;b.d.reference_power=256000000;
   if(b.d.state==5){b.d.error_power=(uint64_t(1)<<48)-1;b.d.ratio_q16=0xffffffff;}
   else{b.d.error_power=(uint64_t(1)<<47)+16;b.d.ratio_q16=0x80000008;}
   b.frame();if(b.d.state==7||b.d.state==6)break;
  }
  need(b.d.state==7&&b.d.fault_code==5,"benefit double-power overflow");cases++;
 }
 {Bench b;b.init();uint64_t r=1234567;for(unsigned n=0;n<500000;n++){r^=r<<13;r^=r>>7;r^=r<<17;b.d.arm=(r&8191)==0;b.d.stop=(r&4095)==1;b.d.hard_fault=(r&1023)==2;b.d.model_valid=(r&255)!=3;b.d.band_ok=(r&31)!=4;b.d.virtual_ready=(r&63)!=5;b.d.reference_ok=(r&15)!=6;b.d.error_power=r&((uint64_t(1)<<48)-1);b.d.reference_power=(r>>3)&((uint64_t(1)<<48)-1);b.d.ratio_q16=uint32_t(r);b.frame();}}
 std::cout<<"PASS_R64_GUARD_CONTRACT cases="<<cases<<" original_thresholds=1 bounded_restarts=2 confirmed_increase_and_hard_fault_latched=1"<<std::endl;return 0;
}catch(const std::exception&e){std::cerr<<"FAIL_R64_GUARD "<<e.what()<<std::endl;return 1;}}
