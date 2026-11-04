#include "Vnumerator_dot65_tb.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <stdexcept>
void need(bool b,const char*s){if(!b)throw std::runtime_error(s);}
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);try{Vnumerator_dot65_tb d;uint32_t r=12345;auto rnd=[&](){r^=r<<13;r^=r>>17;r^=r<<5;return r;};auto tick=[&](){d.clk=0;d.eval();if(d.rst_n)need(!d.diff,"DOT44_BEFORE");d.clk=1;d.eval();if(d.rst_n)need(!d.diff,"DOT44_AFTER");};
 d.rst_n=0;d.clear=d.request=0;d.length=d.ctx=d.coefficient=d.data=d.gradient=0;tick();d.rst_n=1;
 for(uint32_t n=0;n<(1u<<20);n++){d.gradient=n;d.eval();int32_t g=n&0x80000?int32_t(n)-0x100000:int32_t(n);uint64_t a=g<0?uint64_t(-int64_t(g)):uint64_t(g);need(d.magnitude==((a*8389)<<31)&&bool(d.negative)==(g>0),"NUMERATOR_EXHAUSTIVE20");}
 for(unsigned n=0;n<2500;n++){d.clear=1;tick();d.clear=0;const unsigned lengths[7]={0,1,63,152,255,256,511};unsigned len=n<7?lengths[n]:rnd()%257;int32_t a=int32_t(rnd()&0x3ffff),b=int32_t(rnd()&0x3ffff);if(a&0x20000)a-=0x40000;if(b&0x20000)b-=0x40000;if(n==5)a=b=-131072;
 d.length=len;d.coefficient=uint32_t(a)&0x3ffff;d.data=uint32_t(b)&0x3ffff;d.ctx=rnd();d.request=1;tick();d.request=0;
 bool done=d.valid;for(unsigned k=0;k<270&&!done;k++){d.request=n%11==0&&k==3;tick();done=d.valid;}d.request=0;need(done,"DOT_TIMEOUT");need(int64_t(d.sum)==(len==0||len>256?0:int64_t(a)*int64_t(b)*len),"DOT_INDEPENDENT44_BOUND");}
 std::cout<<"PASS_NUMERATOR_DSP_EXHAUSTIVE20 inputs=1048576 DOT44_jobs=2500 all_DOT_outputs_same_cycle=1 max_positive_2pow42_covered=1"<<std::endl;return 0;
 }catch(const std::exception&e){std::cerr<<e.what()<<std::endl;return 1;}}
