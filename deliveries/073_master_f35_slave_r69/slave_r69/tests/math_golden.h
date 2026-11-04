#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#ifndef ANC_VARIANT
#define ANC_VARIANT 2
#endif
namespace independent_anc {
constexpr double FS=50000000.0/1040.0;
constexpr uint32_t MIN_INC=3573413,MAX_INC=(ANC_VARIANT==0?134002979:89245984);
constexpr std::array<uint32_t,4> INC={22333830u,44667660u,67001490u,(ANC_VARIANT==0?89335320u:44667660u)};

constexpr double PI=3.1415926535897932384626433832795;
constexpr int SETTLE=8192, CAL=10000, MU_SHIFT=11;
constexpr int64_t COEFF=(ANC_VARIANT==0?2097152:8388607), MIN_CORR=1638400000LL;

int64_t nearest_shift(int64_t v, int s) {
    int64_t m=v<0 ? -v:v;
    int64_t r=(m+(int64_t(1)<<(s-1)))>>s;
    return v<0 ? -r:r;
}
int64_t arithmetic_shift(int64_t v) {
    return v>=0 ? v/2 : -((-v+1)/2);
}
int pcm(double value) {return int(std::round(value));}

std::array<int,256> trig() {
    std::array<int,256> t{};
    // 独立从数学定义生成整张表，不复制 RTL case 表。
    for(int k=0;k<256;++k) t[k]=int(std::round(32767*std::sin(2*PI*k/256)));
    return t;
}
const auto LUT=trig();

struct FLLGolden{
 uint32_t base,inc;unsigned warm=0,count=0,display=0;int hz;bool previous=false;
 std::array<int64_t,2> old{};bool automatic;int profile;
 FLLGolden():FLLGolden(500.,false,1){}
 FLLGolden(double f,bool a,int p):base(uint32_t(std::llround(f/FS*4294967296.0))),inc(base),hz(int(std::lround(f))),automatic(a),profile(p){}
 uint32_t bound()const{const uint32_t fixed[]={223338,446676,670014,893353};return automatic?std::min(base>>6,446676u):fixed[profile];}
 void sample(int64_t wc,int64_t ws){
  if(warm<24000){++warm;return;}if(++count<512)return;count=0;
  bool good=wc*wc+ws*ws>100000000;
  int shift=0;int64_t mag=std::max(std::llabs(wc),std::llabs(ws));while(mag>=16384){mag>>=1;++shift;}
  std::array<int64_t,2> cur={wc>>shift,ws>>shift};
  if(good&&previous){int64_t cross=old[0]*cur[1]-old[1]*cur[0],dot=old[0]*cur[0]+old[1]*cur[1];
   if(dot>0&&std::llabs(cross)<=(dot>>2)){
    int64_t dn=dot,cn=std::llabs(cross);while(dn>=65536){dn>>=1;cn>>=1;}
    const int rcp[]={4908,4392,3973,3628,3338,3091,2877,2692};int64_t delta=(cn*rcp[(dn>>12)&7])>>8;
    if(delta>=128){delta=std::min(delta,int64_t(8192));if(cross>=0)delta=-delta;
     int64_t lo=std::max(int64_t(MIN_INC),int64_t(base)-bound()),hi=std::min(int64_t(MAX_INC),int64_t(base)+bound());
     inc=uint32_t(std::clamp(int64_t(inc)+delta,lo,hi));}}
  }
  old=cur;previous=good;
  if(++display==16){display=0;hz=int((uint64_t(inc)*12019+(uint64_t(1)<<29))>>30);}
 }
};
struct LegacyGolden {
    enum Mode {ARM,SETTLING,CALIBRATING,RUN,FAULT};
    Mode mode=ARM;
    bool force_legacy500=false;bool limited=false;
    int selected=1,norm_steps=0,error_scale_pow2=0;
    uint32_t phase=0,selected_increment=INC[1],requested_increment=0;
    bool override_enabled=false,automatic=false;
    int64_t dc_q8=0;FLLGolden fll;
    int settle=0,count=0,offset=0,y=0,published=0;
    int64_t cacc=0,sacc=0,wc=0,ws=0;
    void reset() {mode=ARM;phase=0;settle=count=offset=y=published=0;cacc=sacc=wc=ws=0;norm_steps=error_scale_pow2=0;dc_q8=0;fll=FLLGolden(double(selected_increment)*FS/4294967296.,automatic,selected);}
    void command(int requested) {
        Mode old=mode;limited=false;
        int64_t old_dc=dc_q8;reset();dc_q8=old_dc;
        mode=old==ARM ? SETTLING:ARM;
        if(old==ARM){
            selected=requested;
            if(override_enabled&&(requested_increment<3573413u||requested_increment>MAX_INC))mode=FAULT;
            else selected_increment=override_enabled?requested_increment:INC[selected];
            fll=FLLGolden(double(selected_increment)*FS/4294967296.,automatic,selected);
        }
    }
    int sample(int e) {
        int raw=e;
        auto floor_div=[](int64_t x,int64_t d){return x>=0?x/d:-((-x+d-1)/d);};
        e=raw-int(floor_div(dc_q8,256));
        if(raw<=30000&&raw>=-30000)dc_q8+=floor_div(int64_t(raw)*256-dc_q8,1024);
        if(mode!=RUN)fll=FLLGolden(double(selected_increment)*FS/4294967296.,automatic,selected);
        int theta=phase>>24;
        phase+=force_legacy500 ? INC[1]:(mode==RUN?fll.inc:selected_increment);
        int c=LUT[(theta+64)&255],s=LUT[theta];
        if(raw>30000 || raw< -30000) {mode=FAULT;fll=FLLGolden(double(selected_increment)*FS/4294967296.,automatic,selected);}
        if(mode==ARM || mode==FAULT) return published=y=0;
        if(mode==SETTLING) {
            published=y=c/64;
            if(++settle==SETTLE) {mode=CALIBRATING;cacc=sacc=count=0;}
            return y;
        }
        if(mode==CALIBRATING) {
            published=y=c/64;
            cacc+=int64_t(e)*c;sacc+=int64_t(e)*s;
            if(++count==CAL) {
                if(std::max(std::abs(cacc),std::abs(sacc))<MIN_CORR) {mode=FAULT;return y=0;}
                int64_t hr=cacc,hi=-sacc;
                while(std::max(std::abs(hr),std::abs(hi))>=16384) {
                    hr=arithmetic_shift(hr);hi=arithmetic_shift(hi);++norm_steps;
                }
                error_scale_pow2=std::clamp(24-norm_steps,0,6);
                int64_t score=INT64_MIN;
                for(int k=0;k<64;++k) {
                    int64_t test=hr*LUT[(4*k+64)&255]+hi*LUT[4*k];
                    if(test>score) {score=test;offset=4*k;}
                }
                mode=RUN;
            }
            return y;
        }
        y=int(nearest_shift(wc*c+ws*s,24));
        if(std::abs(y)>(ANC_VARIANT==0?4096:8192)) {mode=FAULT;fll=FLLGolden(double(selected_increment)*FS/4294967296.,automatic,selected);return published=y=0;}
        published=y;
        int fc=LUT[(theta+offset+64)&255],fs=LUT[(theta+offset)&255];
        int64_t scaled=int64_t(e)*(int64_t(1)<<error_scale_pow2);
        int64_t nc=wc-nearest_shift(scaled*fc,17);
        int64_t ns=ws-nearest_shift(scaled*fs,17);
        if(std::abs(nc)>COEFF || std::abs(ns)>COEFF) {mode=FAULT;fll=FLLGolden(double(selected_increment)*FS/4294967296.,automatic,selected);return y=0;}
        if(ANC_VARIANT!=2){wc=nc;ws=ns;}else{if(std::abs(nc)+std::abs(ws)<=4194304)wc=nc;else limited=true;if(std::abs(ns)+std::abs(wc)<=4194304)ws=ns;else limited=true;}fll.sample(wc,ws);
        return y;
    }
};

struct RefGolden{
 uint32_t base,inc;int64_t dc=0,ic=0,is=0,ic2=0,is2=0,pc=0,ps=0;int warm=0,count=0;bool previous=false;bool automatic=true;int profile=1;
 explicit RefGolden(uint32_t b):base(b),inc(b){}
 void frame(int raw,int c,int s,bool running){
  auto floor=[](int64_t v,int d){return v>=0?v/d:-((-v+d-1)/d);};
  int center=raw-int(floor(dc,256));bool unclipped=std::abs(raw)<=30000;
  if(unclipped)dc+=floor(int64_t(raw)*256-dc,1024);
  if(!running){ic=is=ic2=is2=0;warm=count=0;previous=false;inc=base;return;}
  if(unclipped){ic+=floor(int64_t(center)*c-ic,256);is+=floor(int64_t(center)*s-is,256);ic2+=floor(ic-ic2,256);is2+=floor(is-is2,256);}else ic=is=ic2=is2=0;
  if(warm<4096){++warm;return;}if(++count<128)return;count=0;
  int64_t a=std::clamp(floor(ic2,64),int64_t(-8388608),int64_t(8388607));
  int64_t b=std::clamp(floor(is2,64),int64_t(-8388608),int64_t(8388607));bool good=a*a+b*b>1048576;
  while(std::max(std::llabs(a),std::llabs(b))>=16384){a=floor(a,2);b=floor(b,2);}
  if(good&&previous){int64_t cross=pc*b-ps*a,dot=pc*a+ps*b;
   if(dot>0&&std::llabs(cross)<=(dot>>2)){
    int64_t dn=dot,cn=std::llabs(cross);while(dn>=65536){dn>>=1;cn>>=1;}
    const int rcp[]={19632,17568,15892,14512,13352,12364,11508,10768};int64_t delta=(cn*rcp[(dn>>12)&7])>>8;
    if(delta>=128){delta=std::min(delta,int64_t(8192));if(cross>=0)delta=-delta;
     const uint32_t fixed[]={223338,446676,670014,893353};int64_t bound=automatic?std::min(base>>6,446676u):fixed[profile];inc=uint32_t(std::clamp(int64_t(inc)+delta,std::max(int64_t(MIN_INC),int64_t(base)-bound),std::min(int64_t(MAX_INC),int64_t(base)+bound)));}}}
  pc=a;ps=b;previous=good;
 }
};

struct Golden:LegacyGolden{
 RefGolden reference{INC[1]};int reference_input=0;
 void reset(){LegacyGolden::reset();reference=RefGolden(selected_increment);reference.automatic=automatic;reference.profile=selected;}
 void command(int requested){int64_t saved_dc=reference.dc;LegacyGolden::command(requested);reference=RefGolden(selected_increment);reference.dc=saved_dc;reference.automatic=automatic;reference.profile=selected;}
 int sample(int error){
  bool running=mode==RUN,low=double(selected_increment)*FS/4294967296.<375.5;int theta=phase>>24;reference.base=selected_increment;
  if(!running)reference.inc=selected_increment;
  if(!low)fll.inc=reference.inc;int result=LegacyGolden::sample(error);
  reference.frame(reference_input,LUT[(theta+64)&255],LUT[theta],running&&mode==RUN);
  if(!low)fll.inc=reference.inc;return result;
 }
};
}
