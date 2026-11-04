#include "Vpcb_particle_overlay.h"
#include "Vpcb_particle_overlay___024root.h"
#include "verilated.h"
#include <array>
#include <cmath>
#include <cstdint>
#include <deque>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

static std::vector<uint8_t> read(const std::string& file) {
    std::ifstream in(file,std::ios::binary);if(!in)throw std::runtime_error("missing "+file);
    return {(std::istreambuf_iterator<char>(in)),{}};
}
static uint32_t word32(const std::vector<uint8_t>& v,size_t i){return uint32_t(v.at(i))|uint32_t(v.at(i+1))<<8|uint32_t(v.at(i+2))<<16|uint32_t(v.at(i+3))<<24;}
struct Expected{bool valid=false,hit=false,sof=false,eol=false;uint16_t rgb=0;uint8_t alpha=0;unsigned pixel=0;};
struct Bench{
    Vpcb_particle_overlay dut;
    std::array<uint32_t,140> misc{};
    std::deque<Expected> pipe;
    uint64_t clocks=0;
    unsigned outputs=0;
    std::string scenario;
    void fail(const std::string& s){throw std::runtime_error(scenario+" cycle="+std::to_string(clocks)+" "+s);}
    void cycle(Expected input={}){
        dut.clk=0;dut.eval();const auto read_addr=dut.st_misc_addr;
        pipe.push_back(input);Expected expected;
        if(pipe.size()>647){expected=pipe.front();pipe.pop_front();}
        dut.clk=1;dut.eval();clocks++;
        dut.st_misc_rdata=read_addr<140?misc[read_addr]:0;dut.eval();
        if(dut.overlay_valid!=expected.valid)fail("valid D=647 失配");
        if(dut.rootp->pcb_particle_overlay__DOT__sof_delayed!=expected.sof||dut.rootp->pcb_particle_overlay__DOT__eol_delayed!=expected.eol)fail("SOF/EOL D=647 失配");
        if(expected.valid){
            outputs++;
            if(dut.overlay_hit!=expected.hit||dut.overlay_alpha!=expected.alpha||(expected.hit&&dut.overlay_rgb565!=expected.rgb))
                fail("pixel="+std::to_string(expected.pixel)+" expected hit="+std::to_string(expected.hit)+" rgb="+std::to_string(expected.rgb)+" alpha="+std::to_string(expected.alpha)+" actual hit="+std::to_string(dut.overlay_hit)+" rgb="+std::to_string(dut.overlay_rgb565)+" alpha="+std::to_string(dut.overlay_alpha));
        }
        if(dut.bucket_overflow_sticky)fail("bucket overflow");
    }
    void reset(){
        dut.rst_n=0;dut.in_valid=0;dut.in_sof=0;dut.in_eol=0;dut.state_commit_toggle=0;dut.clk=0;dut.eval();dut.clk=1;dut.eval();
        pipe.clear();dut.rst_n=1;for(unsigned n=0;n<1000;n++)cycle();
    }
    void run(const std::string& root,const std::string& name,bool bubbles){
        scenario=name;const auto dir=root+"/"+name;
        const auto words=read(dir+"/state_misc.bin"),hit=read(dir+"/overlay_hit.bin"),rgb=read(dir+"/overlay_rgb565.bin"),alpha=read(dir+"/overlay_alpha.bin");
        for(unsigned n=0;n<140;n++)misc[n]=word32(words,n*4);
        const auto start=clocks;dut.state_commit_toggle^=1;
        unsigned prefetch_cycles=0;
        while(dut.snapshot_ack_toggle!=dut.state_commit_toggle){if(clocks-start>200000)fail("ack 超时");cycle();}
        prefetch_cycles=clocks-start;
        while(!dut.rootp->pcb_particle_overlay__DOT__publish_pulse){if(clocks-start>200000)fail("构建超时");cycle();}
        const unsigned build_cycles=clocks-start;for(unsigned n=0;n<20;n++)cycle();outputs=0;
        for(unsigned p=0;p<640*480;p++){
            if(bubbles&&p%997==13){dut.in_valid=0;dut.in_sof=0;dut.in_eol=0;for(unsigned n=0;n<7;n++)cycle();}
            const unsigned x=p%640,y=p/640;
            dut.in_valid=1;dut.in_sof=p==0;dut.in_eol=x==639;dut.in_x=x;dut.in_y=y;
            const int dx=int(x)-320,dy=int(y)-224;dut.in_ridx=std::min(63,int(std::sqrt(double(dx*dx+dy*dy)))>>2);
            Expected e;e.valid=true;e.hit=hit.at(p)!=0;e.rgb=uint16_t(rgb.at(p*2))|uint16_t(rgb.at(p*2+1))<<8;e.alpha=alpha.at(p);e.pixel=p;e.sof=p==0;e.eol=x==639;cycle(e);
        }
        dut.in_valid=0;dut.in_sof=0;dut.in_eol=0;for(unsigned n=0;n<700;n++)cycle();
        if(outputs!=640*480)fail("输出计数失配");
        std::cout<<"{\"status\":\"PASS\",\"scenario\":\""<<name<<"\",\"pixels\":307200,\"delay\":647,\"bubbles\":"<<(bubbles?"true":"false")<<",\"prefetch_cycles\":"<<prefetch_cycles<<",\"build_cycles\":"<<build_cycles<<",\"fits_36000_vblank_cycles\":"<<(build_cycles<=36000?"true":"false")<<"}\n";
    }
};
int main(int argc,char** argv){
    Verilated::commandArgs(argc,argv);if(argc<3)return 2;
    try{Bench b;b.reset();for(int i=2;i<argc;i++)b.run(argv[1],argv[i],i%2==0);b.dut.final();}
    catch(const std::exception& e){std::cerr<<"FAIL: "<<e.what()<<'\n';return 1;}
}
