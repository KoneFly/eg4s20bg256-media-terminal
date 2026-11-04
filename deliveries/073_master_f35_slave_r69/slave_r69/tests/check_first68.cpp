#include "Vanc_first_fault_snapshot_r68.h"
#include "verilated.h"
#include <iostream>
#include <stdexcept>
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);try{Vanc_first_fault_snapshot_r68 d;unsigned cases=0;
auto tick=[&](){d.clk=0;d.eval();d.clk=1;d.eval();};auto pattern=[&](unsigned p){for(unsigned j=0;j<4;j++)d.live_payload[j]=p+j*12345u;};auto check=[&](unsigned p){if(!d.first_valid)throw std::runtime_error("FIRST_MISSING");for(unsigned j=0;j<4;j++)if(d.first_payload[j]!=p+j*12345u)throw std::runtime_error("FIRST_NOT_ATOMIC_OR_OVERWRITTEN");};
d.rst_n=0;d.enabled=0;d.fault_bits=0;pattern(0);tick();d.rst_n=1;tick();
for(unsigned bit=0;bit<31;bit++){
 d.enabled=0;d.fault_bits=0;tick();d.enabled=1;d.fault_bits=0x80000000;pattern(999);for(int k=0;k<3;k++)tick();if(d.first_valid)throw std::runtime_error("SOFT_STOP_STOLE_FIRST_HARD_FAULT");
 d.fault_bits=1u<<bit;pattern(100+bit);tick();d.fault_bits=2;pattern(700);tick();check(100+bit);for(int k=0;k<5;k++){tick();check(100+bit);}cases++;
}
d.enabled=0;d.fault_bits=0;tick();d.enabled=1;d.fault_bits=1;pattern(44);tick();d.enabled=0;tick();d.enabled=1;d.fault_bits=0;tick();tick();if(d.first_valid)throw std::runtime_error("CANCELLED_EVENT_REAPPEARED");cases++;
d.fault_bits=1;pattern(33);tick();d.rst_n=0;tick();d.rst_n=1;d.fault_bits=0;tick();tick();if(d.first_valid)throw std::runtime_error("RESET_PENDING_EVENT");cases++;
std::cout<<"PASS_R68_FIRST_FAULT_RECORDER cases="<<cases<<" all31_hard_bits=1 soft_stop_excluded=1 atomic_freeze=1 rearm_and_reset=1"<<std::endl;return 0;
}catch(const std::exception&e){std::cerr<<e.what()<<std::endl;return 1;}}
