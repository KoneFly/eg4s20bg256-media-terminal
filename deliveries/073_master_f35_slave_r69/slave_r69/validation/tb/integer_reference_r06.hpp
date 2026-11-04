// 逐运算整数控制器原型；外围声学plant仍是实测路径拟合的浮点模型，不是RTL。
#define main floating_reference_unused_main
#include "../../../measured_sweep01_20261031/kernel_band_gate_r04.cpp"
#undef main
#include <limits>
using I=int64_t;
I rounding(I x,int shift){if(!shift)return x;I h=I(1)<<(shift-1);return x>=0?(x+h)>>shift:-((-x+h)>>shift);}
I bounded(I x,I lo,I hi,uint64_t&count){if(x<lo){count++;return lo;}if(x>hi){count++;return hi;}return x;}
uint64_t sqrt_floor(uint64_t v){uint64_t r=0,bit=uint64_t(1)<<62;while(bit>v)bit>>=2;while(bit){if(v>=r+bit){v-=r+bit;r=(r>>1)+bit;}else r>>=1;bit>>=2;}return r;}
struct IntegerSOS{
 std::vector<std::array<I,6>> a;std::vector<std::array<I,2>> z;uint64_t saturations=0;
 IntegerSOS(const Vec&coeff){for(size_t j=0;j<coeff.size();j+=6){std::array<I,6>b;for(int k=0;k<6;k++)b[k]=std::llround(coeff[j+k]*65536);if(b[3]!=65536)throw std::runtime_error("INTEGER_SOS_A0");a.push_back(b);z.push_back({0,0});}}
 IntegerSOS(const Vec&first,const Vec&second):IntegerSOS(first){IntegerSOS q(second);a.insert(a.end(),q.a.begin(),q.a.end());z.resize(a.size(),{0,0});}
 I step(I x){for(size_t j=0;j<a.size();j++){auto&b=a[j];auto&s=z[j];I y=bounded(rounding(b[0]*x,16)+s[0],INT32_MIN,INT32_MAX,saturations);I z0=rounding(b[1]*x-b[4]*y,16)+s[1];I z1=rounding(b[2]*x-b[5]*y,16);s[0]=bounded(z0,INT32_MIN,INT32_MAX,saturations);s[1]=bounded(z1,INT32_MIN,INT32_MAX,saturations);x=y;}return x;}
};
struct IntegerRing{int position=0;std::vector<I> values;IntegerRing():values(4096){}void put(I x){position=position?position-1:2047;set(x);}void set(I x){values[position]=values[position+2048]=x;}const I*data()const{return values.data()+position;}};
I integer_dot(const std::vector<I>&h,const I*x,int begin=0){I result=0;for(size_t j=begin;j<h.size();j++)result+=h[j]*x[j];return result;}
struct IntegerControl{
 std::vector<I> s,f,w;IntegerRing rh,fx,actual,virtualy;
 IntegerSOS pre,output,obj,gout,gobj,detector,primary_objective;
 I band_power=0,total_power=0,gate=0;I last_gain=0,mu_q24=67112;I output_limit=12288;bool clip_recovery=true;bool gate_open=false;size_t n=0;I last_primary_objective_q4=0,last_virtual_error_q4=0;
 uint64_t history_saturations=0,output_clips=0,gain_bounds=0,weight_bounds=0,weight_projections=0,gradient_error_bounds=0,weight_box_bounds=0;
 IntegerControl(const Vec&Sh,const Vec&Fh,const Vec&hp,const Vec&ohp,const Vec&lp):w(256),pre(hp),output(lp),obj(ohp,lp),gout(lp),gobj(ohp,lp),detector(hp,lp),primary_objective(ohp,lp){for(double v:Sh)s.push_back(std::llround(v*32768));for(double v:Fh)f.push_back(std::llround(v*32768));}
 I step(I error_pcm,I observed_ref){
  // Histories index0 is the current output placeholder; S/F[0] is strictly zero.
  actual.put(0);virtualy.put(0);
  I model_actual_q12=rounding(integer_dot(s,actual.data(),1),3),model_virtual_q12=rounding(integer_dot(s,virtualy.data(),1),3);
  I primary_q12=error_pcm*4096-model_actual_q12;last_primary_objective_q4=rounding(primary_objective.step(primary_q12),8);
  I clean_q12=observed_ref*4096-rounding(integer_dot(f,actual.data(),1),3);
  I detector_q4=rounding(detector.step(primary_q12),8),primary_q4=rounding(primary_q12,8);
  band_power+=rounding((detector_q4*detector_q4-band_power)*436,20);total_power+=rounding((primary_q4*primary_q4-total_power)*436,20);
  if(band_power*20>total_power*3&&total_power>0)gate_open=true;else if(band_power*10<total_power)gate_open=false;
  I desired=n>=48077&&gate_open?(I(1)<<24):0;
  if(desired>gate)gate=std::min(desired,gate+1396);else gate=std::max(desired,gate-5584);
  I r=bounded(rounding(pre.step(clean_q12),12),-131072,131071,history_saturations);rh.put(r);
  I request=0;for(int k=0;k<256;k++){I coeff=std::clamp(rounding(w[k],13),I(-131072),I(131071));request+=coeff*rh.data()[k];}
  I request_q12=output.step(rounding(request,3));bool clipped=std::abs(request_q12)>output_limit*4096;output_clips+=clipped;
  I v=std::clamp(rounding(request_q12,12),-output_limit,output_limit);virtualy.set(v);I y=rounding(v*gate,24);actual.set(y);
  I sh_q12=rounding(integer_dot(s,rh.data()),3);I filtered_q4=bounded(rounding(gobj.step(gout.step(sh_q12)),8),-131072,131071,history_saturations);fx.put(filtered_q4);
  I error_q4=rounding(obj.step(primary_q12+model_virtual_q12),8);last_virtual_error_q4=error_q4;
  bool error_out=error_q4< -524272||error_q4>524272;gradient_error_bounds+=error_out;error_q4=std::clamp(error_q4,I(-524272),I(524272));
  I energy=0;for(int k=0;k<256;k++)energy+=fx.data()[k]*fx.data()[k];I gain=0;
  if(energy>0&&!clipped&&!error_out){__int128 numerator=-__int128(error_q4)*mu_q24*268435456;__int128 q=numerator/(energy+1);if(q<INT32_MIN){gain_bounds++;gain=INT32_MIN;}else if(q>INT32_MAX){gain_bounds++;gain=INT32_MAX;}else gain=I(q);}
  last_gain=gain;
  constexpr I BOX=I(1)<<26; // 0.25 in Q28; sqrt(256)*0.25=4 exactly.
  for(int k=0;k<256;k++){
   I next=rounding(w[k]*I(clip_recovery&&clipped?1072693248:1073740750),30)+rounding(gain*fx.data()[k],24);
   next=bounded(next,INT32_MIN,INT32_MAX,weight_bounds);
   w[k]=bounded(next,-BOX,BOX,weight_box_bounds);
  }
  n++;return y;
 }
 uint64_t filter_saturations()const{return pre.saturations+output.saturations+obj.saturations+gout.saturations+gobj.saturations+detector.saturations;}
};
