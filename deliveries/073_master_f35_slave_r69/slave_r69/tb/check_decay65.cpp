#include "Vdecay65_tb.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <stdexcept>
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);try{Vdecay65_tb d;uint32_t r=1;for(unsigned n=0;n<1000010;n++){r^=r<<13;r^=r>>17;r^=r<<5;uint32_t w=n<8?uint32_t(int64_t(-2147483648LL)+n):n<10?uint32_t(2147483647-(n-8)):r;d.weight=w;d.clk=n&1;d.eval();uint64_t gold=uint64_t(int64_t(int32_t(w))*1074)&((uint64_t(1)<<43)-1);if(d.actual!=d.original||d.actual!=gold)throw std::runtime_error("DECAY_EXACT32_DOMAIN");}std::cout<<"PASS_DECAY_1074_EXACT32 checks=1000010 no_new_clock=1 signed_low_high_split=1"<<std::endl;return 0;}catch(const std::exception&e){std::cerr<<e.what()<<std::endl;return 1;}}
