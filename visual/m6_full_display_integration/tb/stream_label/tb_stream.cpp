#include "Vfdi_label_stream.h"
#include "verilated.h"
#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <vector>

static std::vector<uint16_t> label_physical;
static void require(bool ok, const char *message) {
    if (!ok) throw std::runtime_error(message);
}
static void load_bmp(const char *path) {
    std::ifstream in(path, std::ios::binary);
    std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(in)), {});
    require(bytes.size()==921654, "BMP fixture size");
    label_physical.resize(640*480);
    for (size_t i=0;i<label_physical.size();++i) {
        const auto *p=&bytes[54+i*3];
        label_physical[i]=uint16_t((p[2]>>3)<<11 | (p[1]>>2)<<5 | p[0]>>3);
    }
}

class Sim {
public:
    Vfdi_label_stream dut;
    uint64_t now=0, ctrl_next=10000, pixel_next=3173;
    uint64_t reads=0, bursts=0, ctrl_cycles=0, pixel_cycles=0;
    bool active=false, started=false, pause_memory=false;
    int delay=0, beat=0, fault=0;
    uint32_t burst_addr=0, h=0, v=0;
    bool same_cycle_done=false, continuous=false;
    Sim() {
        dut.clk=0; dut.pixel_clk=0; dut.rst_n=0; dut.pixel_rst=1;
        dut.label_ready=0; dut.pixel_take=0; dut.rd_req_ready=0;
        dut.rd_beat_valid=0; dut.rd_done=0; dut.rd_beat_addr=0; dut.rd_beat_data=0;
        dut.eval();
    }
    void reset() {
        dut.rst_n=0; dut.pixel_rst=1; dut.label_ready=0; dut.pixel_take=0;
        active=false; started=false; reads=0; h=0; v=0;
        for(int i=0;i<40;++i)step();
        dut.rst_n=1; dut.pixel_rst=0;
        for(int i=0;i<60;++i)step();
        require(!dut.pixel_ready && !dut.rd_req_valid, "no service before label ready");
        dut.label_ready=1;
    }
    void step() {
        now=std::min(ctrl_next,pixel_next);
        bool ctrl_edge=ctrl_next==now, pixel_edge=pixel_next==now;
        bool ctrl_rise=ctrl_edge && !dut.clk, pixel_rise=pixel_edge && !dut.pixel_clk;
        bool accepted_request=false, send_beat=false, send_done=false;
        if(ctrl_rise) {
            ++ctrl_cycles;
            dut.rd_req_ready=!active && dut.label_ready;
            dut.rd_beat_valid=0; dut.rd_done=0;
            if(active && !pause_memory && delay==0) {
                send_beat=beat<8;
                send_done=(same_cycle_done && beat==7) || (!same_cycle_done && beat==8);
                if(fault==2 && beat==2)send_done=true;
                dut.rd_beat_valid=send_beat; dut.rd_done=send_done;
                dut.rd_beat_addr=burst_addr+uint32_t(beat);
                if(fault==1 && beat==3)dut.rd_beat_addr^=1;
                const auto word=burst_addr+uint32_t(beat)-0x40000;
                if(send_beat) {
                    require(word<153600, "SDRAM read address outside label");
                    dut.rd_beat_data=uint32_t(label_physical[word*2]) |
                        (uint32_t(label_physical[word*2+1])<<16);
                }
            }
            dut.eval();
            accepted_request=dut.rd_req_valid && dut.rd_req_ready;
            if(accepted_request) {
                burst_addr=dut.rd_req_addr;
                require((burst_addr&7)==0, "burst address not BL8 aligned");
            }
        }
        if(pixel_rise) {
            ++pixel_cycles;
            if(!started && dut.pixel_ready)started=true;
            dut.pixel_take=started && (continuous || (h>=144 && h<784 && v>=33 && v<513));
        }
        if(ctrl_edge) { dut.clk=!dut.clk; ctrl_next+=10000; }
        if(pixel_edge) { dut.pixel_clk=!dut.pixel_clk; pixel_next+=19841; }
        dut.eval();
        if(ctrl_rise) {
            if(accepted_request) {
                active=true; delay=10+int(bursts%7); beat=0;
                same_cycle_done=(bursts&1)!=0; ++bursts;
            } else if(active && !pause_memory) {
                if(delay) --delay;
                else {
                    if(send_beat) ++beat;
                    if(send_done) active=false;
                }
            }
        }
        if(pixel_rise && started) {
            if(dut.pixel_valid) {
                const uint32_t index=uint32_t(reads%(640*480));
                const uint32_t y=index/640,x=index%640;
                const uint16_t expected=y>=451 ? 0 : label_physical[(479-y)*640+x];
                if(dut.pixel_data!=(uint32_t(expected)<<16)) {
                    std::cerr<<"mismatch pixel="<<reads<<" x="<<x<<" y="<<y
                        <<" expected="<<std::hex<<(uint32_t(expected)<<16)
                        <<" actual="<<dut.pixel_data<<std::dec<<"\n";
                    throw std::runtime_error("label/image scan order");
                }
                ++reads;
            }
            if(h==799) { h=0; v=v==524 ? 0 : v+1; } else ++h;
        }
    }
    void until_reads(uint64_t count) {
        const auto deadline=now+uint64_t(60000000000);
        while(reads<count && now<deadline) {
            step(); require(dut.error_code==0, "unexpected stream error");
        }
        require(reads==count,"stream timeout");
    }
    void until_error(uint8_t expected) {
        for(int i=0;i<30000 && dut.error_code==0;++i)step();
        require(dut.error_code==expected,"wrong sticky error code");
        for(int i=0;i<100;++i)step();
        require(dut.error_code==expected,"error not sticky");
    }
};

int main(int argc,char **argv) {
    Verilated::commandArgs(argc,argv);
    try {
        require(argc==2,"need BMP fixture path"); load_bmp(argv[1]);
        Sim normal; normal.reset(); normal.until_reads(2*640*480);
        std::cout<<"PASS normal: 614400 pixel words, bursts="<<normal.bursts<<"\n";
        normal.reset(); normal.until_reads(640*480);
        std::cout<<"PASS mid-stream reset: 307200 pixel words\n";
        Sim bad; bad.fault=1; bad.reset(); bad.until_error(0x33);
        std::cout<<"PASS wrong beat address: error 33\n";
        Sim short_burst; short_burst.fault=2; short_burst.reset(); short_burst.until_error(0x34);
        std::cout<<"PASS premature burst done: error 34\n";
        Sim starve; starve.continuous=true; starve.reset();
        while(!starve.started)starve.step();
        starve.pause_memory=true; starve.until_error(0x31);
        require(!starve.dut.pixel_ready,"underflow must close ready");
        std::cout<<"PASS memory starvation: error 31, no fabricated pixel\n";
    } catch(const std::exception &e) {
        std::cerr<<"FAIL: "<<e.what()<<"\n"; return 1;
    }
    return 0;
}
