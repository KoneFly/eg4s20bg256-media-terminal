#include "Vbudget65_tb.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <stdexcept>
int64_t sx24(uint32_t x){return (x&0x800000)?int64_t(x&0xffffff)-16777216:int64_t(x&0xffffff);}
uint64_t mag(int64_t x){return x<0?uint64_t(-x):uint64_t(x);}
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);try{Vbudget65_tb d;uint64_t r=9173,count=0;auto check=[&](int32_t c,int32_t s,uint32_t wc,uint32_t ws){d.next_c=uint32_t(c);d.next_s=uint32_t(s);d.weight_c=wc&0xffffff;d.weight_s=ws&0xffffff;d.eval();unsigned expected=(mag(int64_t(c))+mag(sx24(ws))<=4194304)|((mag(int64_t(s))+mag(sx24(wc))<=4194304)<<1);if(d.old_flags!=expected||d.new_flags!=expected)throw std::runtime_error("BUDGET_EXACT_OLD_AND_UINT64");count++;};int32_t edges[]={INT32_MIN,INT32_MAX,-8388608,8388607,-4194305,-4194304,-4194303,-1,0,1,4194303,4194304,4194305};for(auto c:edges)for(auto s:edges)for(auto w:edges)check(c,s,uint32_t(w),uint32_t(-int64_t(w)));for(unsigned n=0;n<1000000;n++){r^=r<<13;r^=r>>7;r^=r<<17;uint32_t wc=uint32_t(r)&0xffffff,ws=uint32_t(r>>24)&0xffffff;check(int32_t(r),int32_t(r>>32),wc,ws);int64_t gap=4194304-int64_t(mag(sx24(ws)));for(int dlt=-1;dlt<=1;dlt++){check(int32_t(gap+dlt),int32_t(-gap+dlt),wc,ws);check(int32_t(-gap+dlt),int32_t(gap+dlt),wc,ws);}}std::cout<<"PASS_R10_FIXED_BUDGET pairs="<<count<<" old_RTL_and_uint64=1 full32_candidates_full24_other_weights=1"<<std::endl;return 0;}catch(const std::exception&e){std::cerr<<e.what()<<std::endl;return 1;}}
