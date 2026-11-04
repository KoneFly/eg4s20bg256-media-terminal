'use strict';
/* S2 黄金向量生成器（独立来源：JS 参考模型，非 RTL 公式复写 —— LESSON-001）
 *
 * 用法：node reference/gen_vectors.cjs          生成全部用例
 *       node reference/gen_vectors.cjs --list    只列出用例
 *
 * 输出（reference/vectors/）：
 *   label.bin                    640×480 × 16bit LE —— 标签图（全部用例共用）
 *   <case>/image.bin             640×480 × 16bit LE —— 输入图像像素（叠加模式底图；否则全 0）
 *   <case>/state_trace.hex       128 行 × 32 hex   —— T1 走线状态（4×32bit/行，与 wr_lane 对应）
 *   <case>/state_misc.hex        256 行 ×  8 hex   —— T2 杂项状态
 *   <case>/expect.bin            640×480 × 16bit LE —— 期望输出像素（逐位）
 *   <case>/meta.json             用例说明：ov_on / core_q8 / latency / 像素数
 *
 * 状态表布局与 INTERFACE_SPEC.md §状态表内存图 一致（冻结）。
 */

const fs=require('fs'),path=require('path');
// 参考模型的位置随本包所在工作区而变（签发处 / 立项后的任务目录）⇒ 向上搜索定位
function findProto(){
  let d=__dirname;
  for(let i=0;i<7;i++){
    for(const rel of [['prototype'],['visual_workspace','prototype']]){
      const p=path.join(d,...rel,'pcb_model.js');
      if(fs.existsSync(p))return path.join(d,...rel);
    }
    const up=path.dirname(d);if(up===d)break;d=up;
  }
  throw new Error('未找到 prototype/pcb_model.js（需与 visual_workspace/prototype 同区）');
}
const PROTO=findProto();
const M=require(path.join(PROTO,'pcb_model.js'));
const A=require(path.join(PROTO,'pcb_audio.js'));
const FX=require(path.join(PROTO,'pcb_spec_fixed.js'));

const OUT=path.join(__dirname,'vectors');
const SR=48000,W=640,H=480,PIX=W*H;
const G=M.PCB_GEO;

/* ---------- 音频：与浏览器同源（定点前端） ---------- */
const demoSamples=A.pcbDemoTrack(SR);
const pcm12=(()=>{const o=new Int16Array(demoSamples.length);
  for(let i=0;i<demoSamples.length;i++)o[i]=Math.max(-2048,Math.min(2047,Math.round(demoSamples[i]*32767)>>4));
  return o;})();
const an=FX.pcbMakeFixedAnalyzer(SR);
const SILENT=new Uint8Array(128);
const specAt=t=>an.analyze(pcm12,Math.round(t*SR/1000));

/* ---------- 状态推进到指定帧 ---------- */
function stepTo(bootFr,audioMs,silenceAfter){
  const st=M.pcbInitState();
  for(let f=1;f<=bootFr;f++)M.pcbStep(st,SILENT);
  if(audioMs>0){
    const end=Math.round(audioMs/1000*60);
    for(let f=1;f<=end;f++)M.pcbStep(st,specAt(f*1000/60));
    if(silenceAfter)M.pcbStep(st,SILENT);
  }
  return st;
}
const cp=a=>Uint16Array.from(a);

/* ---------- 状态表打包（写入冻结布局） ---------- */
function packState(st){
  const t1=[];
  for(let i=0;i<128;i++){
    if(i<G.traces.length){
      const s0=i*3;
      t1.push([(st.grow[i]&0xFFFF)|((st.flowE[i]&0xFF)<<16)|((st.flowPh[i]&0xFF)<<24),
               (st.pPos[s0]&0xFFFF)|((st.pPeak[s0]&0xFF)<<16)|((st.pAge[s0]&0xFF)<<24),
               (st.pPos[s0+1]&0xFFFF)|((st.pPeak[s0+1]&0xFF)<<16)|((st.pAge[s0+1]&0xFF)<<24),
               (st.pPos[s0+2]&0xFFFF)|((st.pPeak[s0+2]&0xFF)<<16)|((st.pAge[s0+2]&0xFF)<<24)]);
    } else t1.push([0,0,0,0]);
  }
  const m=new Array(256).fill(0);
  for(let n=0;n<64;n++){
    const a=2*n,b=2*n+1;
    m[n]=(st.nodeVis[a]&0xFF)|((st.nodeB[a]&0xFF)<<8)|
         ((st.nodeVis[b]&0xFF)<<16)|((st.nodeB[b]&0xFF)<<24);
  }
  for(let c=0;c<64;c++){
    const a=2*c,b=2*c+1;
    m[64+c]=(st.barH[a]&0xFF)|((st.barPeak[a]&0xFF)<<8)|
            ((st.barH[b]&0xFF)<<16)|((st.barPeak[b]&0xFF)<<24);
  }
  for(let q=0;q<5;q++){let w=0;
    for(let k=0;k<4;k++){const id=q*4+k;if(id<st.compFade.length)w|=(st.compFade[id]&0xFF)<<(8*k);}
    m[128+q]=w>>>0;}
  for(let j=0;j<4;j++)
    m[133+j]=((st.rcAmp[j]&0xFF)|((st.rcDir[j]&3)<<8)|((st.rcPos[j]&0x3FF)<<10))>>>0;
  m[137]=((st.coreQ&0xFF)|((st.ovK&0xFF)<<8)|((st.chipInk&0xFF)<<16)|((st.beatK&0xFF)<<24))>>>0;
  m[138]=((st.bands[0]&0xFF)|((st.bands[1]&0xFF)<<8)|((st.bands[2]&0xFF)<<16)|((st.bands[3]&0xFF)<<24))>>>0;
  m[139]=((st.bands[4]&0xFF)|((st.bands[5]&0xFF)<<8)|((st.bands[6]&0xFF)<<16)|((st.bands[7]&0xFF)<<24))>>>0;
  return{t1,m};
}

/* ---------- 输入图像（叠加模式底图）：亮/暗/中三区，覆盖 Y≥128 两个分支 ---------- */
function makeImage(kind){
  const img=new Uint16Array(PIX);
  if(kind==='none')return img;
  for(let y=0;y<H;y++)for(let x=0;x<W;x++){
    let r8,g8,b8;
    if(kind==='thirds'){                                  // 左 1/3 暗、中 1/3 中、右 1/3 亮
      const t=Math.floor(x*3/W);
      const v=t===0?40:t===1?128:230;
      r8=v;g8=(v+((y>>2)&31))&0xFF;b8=(v-((y>>3)&15))&0xFF;
    }else{                                                // 渐变 + 棋盘
      const v=(x>>1)+(y>>1)&0xFF;
      r8=v;g8=(v^((x^y)&63));b8=255-v;
    }
    img[y*W+x]=((r8>>3)<<11)|((g8>>2)<<5)|(b8>>3);
  }
  return img;
}

/* ---------- 用例定义 ---------- */
const CASES=[
  {name:'boot_done', boot:180, audio:0,    ov:0, core:256, desc:'启动完成静音：静态墨线与元件全显，无发光/无柱'},
  {name:'play_low',  boot:180, audio:1000, ov:0, core:256, desc:'播放 1s（低频段）：底盘/片内低频表亮，柱形图仅低频'},
  {name:'play_mid',  boot:180, audio:5000, ov:0, core:256, desc:'播放 5s（中频段）：中频柱高、脉冲在场'},
  {name:'play_high', boot:180, audio:9000, ov:0, core:256, desc:'播放 9s（高频段）：全频段柱高、彗星在场'},
  {name:'grow_half', boot:90,  audio:0,    ov:0, core:256, desc:'生长半程（第 90 帧）：走线部分生长 + 亚像素前沿'},
  {name:'all_zero',  zero:1,                ov:0, core:256, desc:'状态表全零：仅静态墨线在 chip_ink=0 下全黑（边界）'},
  {name:'saturate',  boot:180, audio:9000, ov:0, core:256, sat:1, desc:'饱和：全段能量 255、柱顶、节点/片内全亮（边界）'},
  {name:'overlay_thirds', boot:180, audio:5000, ov:1, core:90, img:'thirds', desc:'叠加模式 + 三区底图（覆盖亮/暗两支）'},
  {name:'overlay_grad',   boot:180, audio:9000, ov:1, core:90, img:'grad',   desc:'叠加模式 + 渐变棋盘底图'},
];

function build(c){
  let st;
  if(c.zero){st=M.pcbInitState();st.chipInk=0;}
  else{
    st=stepTo(c.boot,c.audio,false);
    if(c.sat){                                            // 饱和态：手工置满
      st.bands.fill(255);st.barH.fill(255);st.barPeak.fill(255);
      st.nodeVis.fill(255);st.nodeB.fill(255);st.chipInk=255;st.beatK=255;
      st.flowE.fill(255);st.compFade.fill(255);st.grow.fill(0x7FFF);
      st.pPos.fill(60);st.pPeak.fill(255);st.pAge.fill(0);
      st.rcAmp.fill(255);st.rcPos.fill(0);st.rcDir.fill(1);
      st.coreQ=c.core;st.ovK=255;
    }
  }
  st.coreQ=c.core??256;
  if(c.ov&&!c.sat)st.ovK=255;
  M.pcbSetOverlay(st,c.ov?1:0);
  if(c.ov)st.ovK=255;
  const opts={noOverlay:1,core:st.coreQ,gain:st.ovK};
  const vis=M.pcbRender(st,0,opts);
  const img=makeImage(c.img||'none');
  let expect;
  if(c.ov){
    const bg=new Uint8ClampedArray(PIX*4);
    for(let i=0;i<PIX;i++){const p=img[i];
      bg[i*4]=((p>>11)&31)<<3;bg[i*4+1]=((p>>5)&63)<<2;bg[i*4+2]=(p&31)<<3;bg[i*4+3]=255;}
    const out=new Uint8ClampedArray(PIX*4);
    M.pcbComposite(vis,bg,out);
    expect=new Uint16Array(PIX);
    for(let i=0;i<PIX;i++)
      expect[i]=((out[i*4]>>3)<<11)|((out[i*4+1]>>2)<<5)|(out[i*4+2]>>3);
  } else expect=vis;
  return{st,img,expect};
}

function wBin16(file,arr){
  const b=Buffer.alloc(arr.length*2);
  for(let i=0;i<arr.length;i++)b.writeUInt16LE(arr[i]&0xFFFF,i*2);
  fs.writeFileSync(file,b);
}
const hx=(v,n)=>((v>>>0).toString(16).toUpperCase()).padStart(n,'0');

(function main(){
  if(process.argv.includes('--list')){CASES.forEach(c=>console.log(c.name.padEnd(16)+c.desc));return;}
  fs.mkdirSync(OUT,{recursive:true});
  wBin16(path.join(OUT,'label.bin'),G.label);
  let total=0;
  for(const c of CASES){
    const d=path.join(OUT,c.name);fs.mkdirSync(d,{recursive:true});
    const{st,img,expect}=build(c);
    const{t1,m}=packState(st);
    fs.writeFileSync(path.join(d,'state_trace.hex'),
      t1.map(r=>r.map(v=>hx(v,8)).join('')).join('\n')+'\n');
    fs.writeFileSync(path.join(d,'state_misc.hex'),m.map(v=>hx(v,8)).join('\n')+'\n');
    wBin16(path.join(d,'image.bin'),img);
    wBin16(path.join(d,'expect.bin'),expect);
    const nz=expect.reduce((a,v)=>a+(v?1:0),0);
    fs.writeFileSync(path.join(d,'meta.json'),JSON.stringify({
      name:c.name,desc:c.desc,ov_on:c.ov,core_q8:st.coreQ,gain_q8:st.ovK,
      pixels:PIX,non_zero_pixels:nz,label:'../label.bin',
      state_trace:'state_trace.hex（128 行×32hex，行为走线号 0..127，字段序 = 4×32bit 小端段）',
      state_misc:'state_misc.hex（256 行×8hex，字地址 0..255）',
      expect:'expect.bin（640×480×16bit LE，行主序）'},null,1)+'\n');
    total+=nz;
    console.log(c.name.padEnd(16)+' 非零像素 '+String(nz).padStart(6)+'/'+PIX+'  ov='+c.ov);
  }
  console.log('\n输出 → '+OUT);
})();
