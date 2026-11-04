#include "Vleaf_miter65_tb.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <stdexcept>
void need(bool b,const char*s){if(!b)throw std::runtime_error(s);}
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);try{
 Vleaf_miter65_tb d;uint64_t cycles=0,r=0x123456789abcdefULL;auto rnd=[&](){r^=r<<13;r^=r>>7;r^=r<<17;return r;};
 auto tick=[&](){d.clk=0;d.eval();if(d.rst_n)need(!d.bdiff&&!d.ddiff,"LEAF_MITER_BEFORE");d.clk=1;d.eval();cycles++;if(d.rst_n)need(!d.bdiff&&!d.ddiff,"LEAF_MITER_AFTER");};
 d.rst_n=0;d.clear=d.breq=d.dreq=0;d.x=d.z0=d.z1=d.b0=d.b1=d.b2=d.a1=d.a2=d.ctx=0;d.numerator=d.denominator=0;tick();d.rst_n=1;
 for(unsigned n=0;n<6010;n++){
  d.clear=1;tick();d.clear=0;d.x=uint32_t(rnd());d.z0=uint32_t(rnd());d.z1=uint32_t(rnd());d.b0=rnd()&0x3ffff;d.b1=rnd()&0x3ffff;d.b2=rnd()&0x3ffff;d.a1=rnd()&0x3ffff;d.a2=rnd()&0x3ffff;d.ctx=uint8_t(rnd());
  if(n<10){d.x=1;d.z0=d.z1=d.a1=d.a2=0;d.b0=n&1?32768:0x38000;d.b1=n&2?32768:0x38000;d.b2=n&4?32768:0x38000;}
  d.breq=1;tick();d.breq=0;
  bool finished=false;for(unsigned k=0;k<80;k++){
   d.x=uint32_t(rnd());d.z0=uint32_t(rnd());d.z1=uint32_t(rnd());d.b0=rnd()&0x3ffff;d.b1=rnd()&0x3ffff;d.b2=rnd()&0x3ffff;d.a1=rnd()&0x3ffff;d.a2=rnd()&0x3ffff;d.ctx=uint8_t(rnd());
   d.breq=n%7==0&&k==3;d.clear=n%5==0&&k==4;tick();d.breq=0;
   if(d.clear){d.clear=0;tick();finished=true;break;}if(d.bvalid){finished=true;break;}
  }need(finished,"SOS_TIMEOUT");
 }
 d.clear=1;tick();d.clear=0;
 for(unsigned n=0;n<12000;n++){
  uint64_t a=rnd(),b=rnd();if(n%5==0)b=uint64_t(1)<<(n%64);if(n%41==0)b=0;if(n%37==0)a=~uint64_t(0);if(n%31==0)b=~uint64_t(0);
  d.numerator=a;d.denominator=b;d.dreq=1;tick();d.dreq=0;
  if(b==0)need(d.ddone&&d.dzero&&d.quotient==~uint64_t(0)&&d.remainder==a,"DIV_ZERO");
  else{for(unsigned k=1;k<=64;k++){d.numerator=rnd();d.denominator=rnd();d.dreq=k==5;tick();need(bool(d.ddone)==(k==64),"DIV_EXACT_64_CYCLES");}d.dreq=0;need(d.quotient==a/b&&d.remainder==a%b,"DIV_INDEPENDENT_UNSIGNED64_GOLDEN");}
  tick();
 }
 for(unsigned k=1;k<=64;k++){d.numerator=rnd();d.denominator=rnd()|1;d.dreq=1;tick();d.dreq=0;for(unsigned j=0;j<k;j++)tick();d.clear=1;tick();d.clear=0;tick();need(d.dready&&!d.ddone,"DIV_CANCEL");}
 std::cout<<"PASS_R03_REAL_PROVIDER_SOS_AND_COMPACT_DIVIDER SOS_jobs=6010 DIV_jobs=12000 cancel_phases=64 all_SOS_outputs_same_cycle=1 DIV_data_qualified_by_done=1 cycles="<<cycles<<std::endl;return 0;
 }catch(const std::exception&e){std::cerr<<e.what()<<std::endl;return 1;}}
