#include "Vpcb_frame_updater.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

// 对外真实写口逐拍检查；不读写 DUT 内部状态。
static uint32_t le32(const std::vector<uint8_t>& b, size_t p) {
    return uint32_t(b.at(p)) | uint32_t(b.at(p+1))<<8 | uint32_t(b.at(p+2))<<16 | uint32_t(b.at(p+3))<<24;
}
static uint16_t le16(const std::vector<uint8_t>& b, size_t p) { return uint16_t(b.at(p)) | uint16_t(b.at(p+1))<<8; }
struct Bench {
    Vpcb_frame_updater dut;
    uint64_t clocks=0;
    std::array<uint32_t,512> trace{};
    std::array<uint32_t,256> misc{};
    std::array<uint16_t,2048> particles{};
    const std::vector<uint8_t>* vectors=nullptr;
    size_t frame_base=0;
    unsigned writes=0, commits=0, frame=0, max_cycles=0;
    bool checking=false;
    std::string scenario;
    void fail(const std::string& message) { throw std::runtime_error(scenario+" frame="+std::to_string(frame)+" cycle="+std::to_string(clocks)+" "+message); }
    void cycle() {
        dut.clk=0;dut.eval();
        const bool old_commit=dut.state_commit_toggle;
        if(dut.rst_n && dut.state_wr_en) {
            if(dut.part_wr_en) fail("两个写口同时有效");
            if(!dut.state_wr_sel) trace.at(dut.state_wr_addr*4+dut.state_wr_lane)=dut.state_wr_data;
            else misc.at(dut.state_wr_addr)=dut.state_wr_data;
            if(checking) {
                const unsigned expected_addr=writes<512?writes/4:writes-512;
                if(writes>=652 || unsigned(dut.state_wr_sel)!=(writes>=512) || dut.state_wr_addr!=expected_addr || (writes<512&&dut.state_wr_lane!=(writes&3))) fail("T1/T2 写序失配，write="+std::to_string(writes));
                const auto expected=le32(*vectors,frame_base+128+writes*4);
                if(dut.state_wr_data!=expected) fail("T"+std::to_string(writes<512?1:2)+" addr="+std::to_string(expected_addr)+" lane="+std::to_string(dut.state_wr_lane)+" expected="+std::to_string(expected)+" actual="+std::to_string(dut.state_wr_data));
                writes++;
            }
        }
        if(dut.rst_n && dut.part_wr_en) {
            particles.at(dut.part_wr_addr)=dut.part_wr_data;
            if(checking) {
                if(writes<652||writes>=2188||dut.part_wr_addr!=writes-652)fail("P 写序失配");
                const auto expected=le16(*vectors,frame_base+128+652*4+(writes-652)*2);
                if(dut.part_wr_data!=expected)fail("P addr="+std::to_string(dut.part_wr_addr)+" expected="+std::to_string(expected)+" actual="+std::to_string(dut.part_wr_data));
                writes++;
            }
        }
        dut.clk=1;dut.eval();clocks++;
        if(checking && old_commit!=bool(dut.state_commit_toggle)) {
            if(++commits!=1||writes!=2188||dut.state_wr_en||dut.part_wr_en||!dut.frame_done)fail("提交边界或计数失配");
        }
    }
    void reset() {
        checking=false;dut.rst_n=0;dut.frame_tick=0;dut.cfg_wr_en=0;dut.snapshot_ack_toggle=0;
        cycle();cycle();
        if(dut.state_wr_en||dut.part_wr_en||dut.state_commit_toggle) fail("复位写口/提交未清零");
        dut.rst_n=1;
        for(unsigned n=0;!dut.frame_ready;n++) {
            if(n>256) fail("复位初始化超时");cycle();
            if(dut.state_wr_en||dut.part_wr_en)fail("初始化时对外写口有效");
        }
    }
    void spectrum(const std::vector<uint8_t>& data,size_t offset) {
        for(unsigned n=0;n<32;n++) dut.spec_frame[n]=le32(data,offset+n*4);
    }
    void rejected_tick() {
        dut.frame_tick=1;cycle();dut.frame_tick=0;
        if(dut.frame_accept||!dut.err_valid||dut.err_code!=1)fail("overrun 未拒绝或错误码失配");
        cycle();
    }
    void run(const std::vector<uint8_t>& data,bool overrun,bool reentry) {
        vectors=&data;reset();
        if(reentry) {
            spectrum(data,4);dut.frame_tick=1;cycle();dut.frame_tick=0;
            for(unsigned n=0;n<200;n++)cycle();reset();
            spectrum(data,4);dut.frame_tick=1;cycle();dut.frame_tick=0;
            for(unsigned n=0;!(dut.part_wr_en&&dut.part_wr_addr==100);n++) {
                if(n>833333)fail("找不到 P 序列化复位点");cycle();
            }
            reset();
        }
        const auto frames=le32(data,0);
        for(frame=0;frame<frames;frame++) {
            frame_base=4+size_t(frame)*5808;writes=0;commits=0;checking=true;
            if(!dut.frame_ready)fail("接受前未 ready");
            spectrum(data,frame_base);dut.frame_tick=1;cycle();dut.frame_tick=0;
            if(!dut.frame_accept)fail("frame_accept 缺失");
            const auto accepted=clocks;
            // 接受后立即扰动现场输入；当前帧必须继续使用已锁存频谱。
            for(unsigned n=0;n<32;n++)dut.spec_frame[n]^=0xffffffffu;
            if(overrun&&frame==0)rejected_tick();
            unsigned count=0;
            while(!dut.frame_done) {cycle();if(++count>833333)fail("超过一帧控制域预算");}
            max_cycles=std::max(max_cycles,unsigned(clocks-accepted));
            if(writes!=2188||commits!=1)fail("提交时写/提交计数不完整");
            if(dut.frame_ready)fail("未收到 ack 就 ready");
            cycle();if(dut.frame_done)fail("frame_done 不是单拍");
            if(overrun&&frame==0)rejected_tick();
            for(unsigned n=0;n<5;n++)cycle();
            dut.snapshot_ack_toggle=dut.state_commit_toggle;
            for(unsigned n=0;!dut.frame_ready;n++){if(n>4)fail("ack 同步超时");cycle();}
            if(dut.err_valid && !overrun)fail("正常帧错误码="+std::to_string(dut.err_code));
        }
        dut.final();
        std::cout<<"{\"status\":\"PASS\",\"scenario\":\""<<scenario<<"\",\"frames\":"<<frames<<",\"max_update_cycles\":"<<max_cycles<<",\"overrun\":"<<(overrun?"true":"false")<<",\"reset_reentry\":"<<(reentry?"true":"false")<<"}\n";
    }
};
int main(int argc,char** argv) {
    Verilated::commandArgs(argc,argv);
    if(argc<3)return 2;
    try {
        std::ifstream file(argv[1],std::ios::binary);
        if(!file)throw std::runtime_error("黄金文件不存在");
        std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(file)),{});
        Bench bench;bench.scenario=argv[2];bench.run(bytes,argc>3&&std::string(argv[3])=="overrun",argc>3&&std::string(argv[3])=="reset");
    } catch(const std::exception& e) { std::cerr<<"FAIL: "<<e.what()<<'\n';return 1; }
}
