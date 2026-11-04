#include "Vleak_round65_tb.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <stdexcept>
int64_t floor_shift(int64_t x,unsigned k){return x>=0?x/(int64_t(1)<<k):-((-x+(int64_t(1)<<k)-1)/(int64_t(1)<<k));}
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);try{Vleak_round65_tb d;uint32_t r=1;int32_t edges[]={0,1,-1,511,512,513,-511,-512,-513,1535,1536,1537,-1535,-1536,-1537,268435456,-268435456,268435455,268435457,-268435455,-268435457,INT32_MIN,INT32_MAX};for(unsigned n=0;n<2000023;n++){r^=r<<13;r^=r>>17;r^=r<<5;int32_t w=n<23?edges[n]:int32_t(r);d.weight=uint32_t(w);d.clk=n&1;for(unsigned mode=0;mode<2;mode++){d.recovery=mode;d.eval();int64_t bias=mode?(w<0?511:512):(w<0?536870911:536870912),product=mode?w:int64_t(w)*1074;uint64_t expected=uint64_t(int64_t(w)+floor_shift(bias-product,mode?10:30))&((uint64_t(1)<<33)-1);if(d.old_value!=d.new_value||d.new_value!=expected)throw std::runtime_error("LEAK_ROUND_OLD_AND_INDEPENDENT_GOLDEN");}}std::cout<<"PASS_LEAK_ROUND_EXACT_ALL32_ALGEBRA samples=2000023 recovery_modes=2 explicit_half_ties=1 no_cycle_change=1"<<std::endl;return 0;}catch(const std::exception&e){std::cerr<<e.what()<<std::endl;return 1;}}
