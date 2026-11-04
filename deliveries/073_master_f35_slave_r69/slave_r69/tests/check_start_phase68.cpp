#include "Vstart_phase68_tb.h"
#include "verilated.h"
#include <array>
#include <iostream>
#include <stdexcept>
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);try{Vstart_phase68_tb d;unsigned phase=0,trial=0;uint64_t cycles=0,jobs=0;std::array<bool,1040> seen{};
auto tick=[&](){d.clk=0;d.eval();d.clk=1;d.eval();cycles++;phase=d.capture_valid?0:(phase+1)%1040;};auto run=[&](unsigned n){while(n--)tick();};
d.key1=0;d.key2=d.key3=d.key4=1;d.sw=12;d.mic_sd=0;d.inject=d.loopback=d.diagnostic_override=d.diagnostic_command=0;run(100);d.key1=1;run(80000);
d.key2=0;run(1100000);d.key2=1;run(1100000);if(!d.armed||!d.fx_selected)throw std::runtime_error("ARM_PRECONDITION");d.diagnostic_override=1;d.diagnostic_command=0;tick();
auto command=[&](){d.diagnostic_command=1;tick();d.diagnostic_command=0;tick();};
for(trial=0;trial<1040;trial++){
 if(d.fx_running){command();if(d.fx_running)throw std::runtime_error("STOP_TRANSACTION");}
 run(1024);unsigned wait=0;while(phase!=trial){tick();if(++wait>1040)throw std::runtime_error("ADC_PHASE_ALIGNMENT");}
 command();if(!d.fx_running)throw std::runtime_error("START_TRANSACTION");seen[phase]=true;
 unsigned completed=0;
 for(wait=0;completed<8;wait++){
  tick();if(d.core_done){completed++;jobs++;}
  if(d.core_fault||d.actuator_fault||d.pair_overrun||d.guard_state==6||d.guard_state==7)throw std::runtime_error("START_PHASE_FAULT trial="+std::to_string(trial)+" phase="+std::to_string(phase)+" reason="+std::to_string(d.guard_reason));
  if(wait>50000)throw std::runtime_error("START_COMPLETION_DEADLINE");
 }
}
unsigned covered=0;for(bool b:seen)covered+=b;if(covered!=1040)throw std::runtime_error("PHASE_COVERAGE");
std::cout<<"PASS_R68_START_PHASE_SWEEP phases="<<covered<<" complete_frames="<<jobs<<" clocks="<<cycles<<" injection=debounced_command_only no_native_tick_injection=1"<<std::endl;return 0;
}catch(const std::exception&e){std::cerr<<e.what()<<std::endl;return 1;}}
