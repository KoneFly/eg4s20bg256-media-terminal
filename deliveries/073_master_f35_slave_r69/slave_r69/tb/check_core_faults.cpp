#include "Vanc_fxn_core_r61.h"
#include "verilated.h"
#include <iostream>
#include <stdexcept>
#include <string>
void require(bool b,const std::string&s){if(!b)throw std::runtime_error(s);}
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);Vanc_fxn_core_r61 d;uint64_t clocks=0;unsigned scenarios=0;
 auto tick=[&](){d.clk=0;d.eval();d.clk=1;d.eval();clocks++;};
 auto arm=[&](){d.sample_valid=d.native_fault=d.stop=0;d.mode_enabled=d.model_valid=1;d.model_epoch=1;d.clear=1;d.eval();require((d.diagnostic_fault_bits&0x60000000u)==0,"OLD_FAULT_FLAGS_DURING_ARM");tick();d.clear=0;unsigned wait=0;while(!d.ready){tick();require(++wait<=260,"RAM rearm deadline");}require(d.guard_state==1&&!d.kernel_fault&&d.force_zero,"rearm did not restart muted learning");};
 auto frame=[&](){d.error_pcm=100;d.reference_pcm=200;d.frame_id=0;d.sample_valid=1;tick();d.sample_valid=0;};
 try{
  d.rst_n=0;d.clear=d.sample_valid=d.native_fault=d.stop=0;d.mode_enabled=d.model_valid=1;d.model_epoch=1;tick();d.rst_n=1;arm();
  d.model_valid=0;tick();require(d.force_zero&&d.guard_state==6&&d.guard_reason==2,"invalid model accepted");d.model_valid=1;tick();require(d.force_zero&&d.guard_state==6,"invalid model automatically retried");scenarios++;
  arm();d.model_epoch=2;tick();require(d.force_zero&&d.guard_state==6&&d.guard_reason==3,"epoch mismatch accepted");scenarios++;
  arm();d.native_fault=1;d.clear=1;d.eval();require(d.diagnostic_fault_bits&1,"NATIVE_FAULT_MASKED_BY_CLEAR");tick();require(d.force_zero&&d.guard_state==6&&d.guard_reason==8,"native fault lost to ARM");d.clear=d.native_fault=0;tick();require(d.force_zero&&d.guard_state==6,"native fault retried without ARM");scenarios++;
  arm();d.sample_valid=1;tick();tick();d.sample_valid=0;tick();require(d.kernel_fault&&d.force_zero&&d.guard_state==6,"input overrun not muted");scenarios++;
  arm();frame();for(int k=0;k<50;k++)tick();d.clear=1;tick();d.clear=0;while(!d.ready)tick();for(int k=0;k<32;k++){tick();require(!d.sample_done&&!d.command_submit&&!d.kernel_fault&&d.command==0,"old epoch survived clear");}scenarios++;
  arm();frame();for(int k=0;k<40;k++)tick();d.mode_enabled=0;tick();require(d.force_zero&&d.guard_state==0,"mode exit not muted");unsigned wait=0;while(!d.sample_done){tick();require(++wait<4160&&!d.kernel_fault,"mode exit completion");}require(d.command==0,"mode exit emitted output");d.mode_enabled=1;tick();require(d.force_zero&&d.guard_state==0,"mode entry started without ARM");scenarios++;
  arm();frame();for(int k=0;k<40;k++)tick();d.stop=1;tick();require(d.force_zero&&d.guard_state==0,"STOP not muted");d.stop=0;wait=0;while(!d.sample_done){tick();require(++wait<4160&&!d.kernel_fault,"stop completion");}require(d.command==0,"STOP emitted output");scenarios++;
  std::cout<<"PASS_R61_FULL_KERNEL_FAULTS scenarios="<<scenarios<<" clocks="<<clocks<<std::endl;return 0;
 }catch(const std::exception&e){std::cerr<<"FAIL_R61_FULL_KERNEL_FAULTS "<<e.what()<<" clocks="<<clocks<<std::endl;return 1;}}
