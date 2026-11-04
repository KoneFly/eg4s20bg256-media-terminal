#include "Vanc_uart_snapshot_r68.h"
#include "verilated.h"
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <vector>
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);try{
 Vanc_uart_snapshot_r68 d;std::vector<unsigned char> bytes;unsigned rx=0,wait=0,bit=0,value=0;bool previous=true;
 for(unsigned n=0;n<900000;n++){
  d.rst_n=n>=8;d.first_valid=n>=1000;
  for(unsigned j=0;j<4;j++){uint32_t a=0,b=0;for(unsigned k=0;k<4;k++){a|=((4*j+k)^(n<1000?0x11u:0x22u))<<(8*k);b|=((4*j+k)^0xa5u)<<(8*k);}d.live_payload[j]=a;d.first_payload[j]=b;}
  d.clk=0;d.eval();d.clk=1;d.eval();bool line=d.tx;
  if(!d.rst_n){rx=0;previous=true;continue;}
  if(rx==0){if(previous&&!line){rx=1;wait=75;bit=0;value=0;}}
  else if(--wait==0){if(rx==1){value|=unsigned(line)<<bit;if(++bit==8)rx=2;wait=50;}else{if(!line)throw std::runtime_error("UART_STOP_BIT");bytes.push_back(value);rx=0;}}
  previous=line;
 }
 std::ofstream out(argv[1],std::ios::binary);out.write((char*)bytes.data(),bytes.size());out.close();
 if(bytes.size()<26*10)throw std::runtime_error("UART_COVERAGE");
 std::cout<<"PASS_UART_WIRE_1MBPS bytes="<<bytes.size()<<" clocks=900000"<<std::endl;return 0;
 }catch(const std::exception&e){std::cerr<<e.what()<<std::endl;return 1;}}
