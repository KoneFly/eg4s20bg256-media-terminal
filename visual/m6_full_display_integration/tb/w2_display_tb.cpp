#include "Vw2_display_tb.h"
#include "verilated.h"
#include <algorithm>
#include <array>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

static std::vector<uint8_t> read_file(const char* path){
    std::ifstream f(path,std::ios::binary);if(!f)throw std::runtime_error(std::string("cannot open ")+path);
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)),{});
}
static uint32_t le32(const std::vector<uint8_t>& b,size_t p){
    return uint32_t(b.at(p))|uint32_t(b.at(p+1))<<8|uint32_t(b.at(p+2))<<16|uint32_t(b.at(p+3))<<24;
}
int main(int argc,char** argv){
    Verilated::commandArgs(argc,argv);
    if(argc<5)return 2;
    try{
        const auto golden=read_file(argv[1]),labels=read_file(argv[2]);
        const std::string scenario=argv[3];const unsigned frames=std::stoul(argv[4]);
        const unsigned ready_delay=argc>5?std::stoul(argv[5]):5000;
        const std::string fault=argc>7?argv[7]:"";
        const uint64_t ctrl_half=fault=="slow_ctrl"?250000:10000;
        if(labels.size()!=614400)throw std::runtime_error("label length mismatch");
        Vw2_display_tb d;
        std::array<uint32_t,512> trace{};std::array<uint32_t,256> misc{};
        std::vector<uint16_t> rendered;
        std::vector<uint8_t> rgb_expect;
        const std::string rgb_dir=argc>6?argv[6]:"";
        unsigned writes=0,batches=0,video_pixels=0,input_pixels=0,displayed=0,source_frame=0;
        unsigned pixel_cycles=0,ctrl_cycles=0,snapshot_wait=0,label_index=0,requests=0;
        unsigned blank_write_checks=0,read_checks=0,pixel_checks=0,rgb_gold_pixels=0,rgb_gold_frames=0;
        unsigned update_start=0,max_update_cycles=0;
        unsigned error_sync_cycle=0;
        uint64_t now=0,next_ctrl=ctrl_half,next_pixel=19841;
        bool committed=false,first_before_ready=false;
        auto fail=[&](const std::string& s){throw std::runtime_error(scenario+" pcycle="+std::to_string(pixel_cycles)+" "+s);};
        d.clk=0;d.ctrl_clk=0;d.rst=1;d.ctrl_rst_n=0;d.snapshot_done=0;
        d.energy_data=0;d.label_ready=0;d.pixel_ready=0;d.pixel_valid=0;d.pixel_data=0;d.eval();
        while(displayed<frames){
            now=std::min(next_ctrl,next_pixel);
            const bool ce=now==next_ctrl,pe=now==next_pixel;
            const bool cr=ce&&!d.ctrl_clk,pr=pe&&!d.clk;
            const bool old_commit=d.commit,old_ready=d.frame_ready;const unsigned old_display=d.display_frames;
            const unsigned ra=d.trace_addr,ma=d.misc_addr;
            const bool take=pr&&d.pixel_take;
            const unsigned energy_address=d.energy_addr;
            if(cr){
                ctrl_cycles++;
                if(ctrl_cycles>8)d.ctrl_rst_n=1;
                if(d.ctrl_rst_n&&d.wr_en){
                    if(!(d.scan_v>=515||d.scan_v<33)&&fault!="slow_ctrl")fail("write outside postflush VBLANK");
                    blank_write_checks++;
                    const unsigned ea=writes<512?writes/4:writes-512;
                    if(writes>=652||unsigned(d.wr_sel)!=(writes>=512)||d.wr_addr!=ea||
                      (writes<512&&d.wr_lane!=(writes&3)))fail("T1/T2 write order mismatch");
                    const auto expect=le32(golden,4+size_t(batches)*2736+128+writes*4);
                    if(d.wr_data!=expect)fail("gold write="+std::to_string(writes)+" batch="+std::to_string(batches)+
                      " expected="+std::to_string(expect)+" actual="+std::to_string(d.wr_data));
                    if(writes<512)trace.at(d.wr_addr*4+d.wr_lane)=d.wr_data;
                    else misc.at(d.wr_addr)=d.wr_data;
                    writes++;
                }
            }
            if(pr){
                pixel_cycles++;
                if(pixel_cycles>8)d.rst=0;
                if(pixel_cycles==1000)d.label_ready=1;
                if(pixel_cycles==ready_delay)d.pixel_ready=1;
                if(d.frame_request){
                    if(!d.label_ready)fail("request before label verified");
                    if(d.scan_v!=515)fail("snapshot request outside VBLANK");
                    source_frame=batches;snapshot_wait=7;requests++;
                }
                if(d.rendered_valid){rendered.push_back(d.rendered);}
                if(d.video_de){
                    if(video_pixels>=rendered.size())fail("display before renderer pixel ready");
                    if(d.video_rgb!=rendered.at(video_pixels))fail("two-line retiming RGB mismatch index="+std::to_string(video_pixels));
                    if(!rgb_expect.empty()){
                        const uint16_t expected=uint16_t(rgb_expect.at(video_pixels*2))|uint16_t(rgb_expect.at(video_pixels*2+1))<<8;
                        if(d.video_rgb!=expected)fail("JS RGB golden mismatch state_frame="+std::to_string(batches-1)+
                          " index="+std::to_string(video_pixels)+" expected="+std::to_string(expected)+" actual="+std::to_string(d.video_rgb));
                        rgb_gold_pixels++;
                    }
                    video_pixels++;pixel_checks++;
                }
                if(take){
                    if(input_pixels==0&&!rgb_dir.empty()){
                        const std::string file=rgb_dir+"/"+std::to_string(batches-1)+".bin";
                        std::ifstream check(file,std::ios::binary);rgb_expect.clear();
                        if(check){rgb_expect=read_file(file.c_str());rgb_gold_frames++;}
                    }
                    input_pixels++;
                }
                if(pixel_cycles>420000*(frames+8))fail("startup/scan timeout");
            }
            if(ce){d.ctrl_clk=!d.ctrl_clk;next_ctrl+=ctrl_half;}
            if(pe){d.clk=!d.clk;next_pixel+=19841;}
            d.eval();
            if(cr&&old_ready&&!d.frame_ready)update_start=ctrl_cycles;
            if(cr&&old_commit!=bool(d.commit)){
                if(writes!=652||!d.frame_done||d.frame_ready)fail("commit/done/ack ordering mismatch");
                if(!d.pixel_ready)first_before_ready=true;
                max_update_cycles=std::max(max_update_cycles,ctrl_cycles-update_start);
                writes=0;batches++;committed=true;
            }
            if(pr){
                if(committed&&take){
                    for(unsigned lane=0;lane<4;lane++)if(d.trace_data[lane]!=trace.at((ra&127)*4+lane))fail("T1 synchronous read mismatch");
                    if(d.misc_data!=misc.at(ma))fail("T2 synchronous read mismatch");read_checks++;
                }
                d.energy_data=golden.at(4+size_t(source_frame)*2736+energy_address);
                d.snapshot_done=fault!="snapshot_timeout"&&snapshot_wait==1;if(snapshot_wait)snapshot_wait--;
                d.pixel_valid=take && !(fault=="drop_pixel"&&label_index==100);
                if(take){
                    const unsigned y=label_index/640;
                    const uint16_t label=y>=451?0:uint16_t(labels.at(label_index*2))|uint16_t(labels.at(label_index*2+1))<<8;
                    d.pixel_data=uint32_t(label)<<16;label_index=(label_index+1)%307200;
                }
                d.eval();
                if(d.ctrl_error_sync&&!error_sync_cycle)error_sync_cycle=pixel_cycles;
                if(d.error_code){
                    const unsigned expected=fault=="slow_ctrl"?0xa2:fault=="drop_pixel"?0xa3:fault=="snapshot_timeout"?0xa1:0;
                    if(!expected||d.error_code!=expected)fail("DUT error="+std::to_string(d.error_code));
                    if(fault=="slow_ctrl"&&(!error_sync_cycle||pixel_cycles-error_sync_cycle<2))fail("fault code locked before two stable samples");
                    d.final();std::cout<<"{\"status\":\"PASS\",\"scenario\":\""<<scenario
                      <<"\",\"injected_fault\":\""<<fault<<"\",\"error_code\":"<<expected
                      <<",\"stable_sample_delay\":"<<(error_sync_cycle?pixel_cycles-error_sync_cycle:0)<<"}\n";return 0;
                }
                if(old_display!=d.display_frames){
                    if(input_pixels!=307200||video_pixels!=307200||rendered.size()!=307200)
                      fail("frame completeness in="+std::to_string(input_pixels)+" out="+std::to_string(video_pixels)+" S2="+std::to_string(rendered.size()));
                    displayed++;input_pixels=0;video_pixels=0;rendered.clear();
                }
            }
        }
        if(!fault.empty())fail("injected fault was not diagnosed");
        if(ready_delay>420000&&!first_before_ready)fail("delayed-ready case missed commit/ack before FIFO ready");
        d.final();
        std::cout<<"{\"status\":\"PASS\",\"scenario\":\""<<scenario<<"\",\"display_frames\":"<<displayed
          <<",\"golden_write_batches\":"<<batches<<",\"snapshot_requests\":"<<requests
          <<",\"blank_write_checks\":"<<blank_write_checks<<",\"state_read_cycles\":"<<read_checks
          <<",\"rgb_retiming_pixels\":"<<pixel_checks<<",\"js_rgb_golden_frames\":"<<rgb_gold_frames
          <<",\"js_rgb_golden_pixels\":"<<rgb_gold_pixels<<",\"max_w2_update_cycles\":"<<max_update_cycles
          <<",\"commit_before_pixel_ready\":"<<(first_before_ready?"true":"false")<<"}\n";
    }catch(const std::exception& e){std::cerr<<"FAIL: "<<e.what()<<'\n';return 1;}
}
