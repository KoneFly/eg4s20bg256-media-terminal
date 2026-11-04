'use strict';
// 补充配置刺激；基线配置档和二进制不改，独立模型在隔离 VM 中绑定参数。
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),crypto=require('node:crypto');
const {createRequire}=require('node:module');
const task=path.resolve(__dirname,'..'),profileFile=path.join(task,'reference/profiles.cjs');
const modelFile=path.resolve(task,'../../prototype/pcb_model.js');
const pack=require('../reference/gen_state_vectors.cjs');
const sha=file=>crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const names=['PCB_GROW_PX_PER_S','PCB_GROW_MIN_FR','PCB_RANK_STAG_FR','PCB_FLOW_V0','PCB_FLOW_VG','PCB_PULSE_V','PCB_ONSET_FLOOR','PCB_PULSE_MIN'];
const defaults=[70,36,9,8,24,44,160,18],low=[30,12,0,0,0,16,64,8],high=[200,90,30,32,64,96,512,64];
function configuredModel(values){
  const actualRequire=createRequire(profileFile);
  const fsProxy={...fs,readFileSync(file,...args){
    let data=fs.readFileSync(file,...args);
    if(path.resolve(file)===modelFile){
      for(let i=0;i<names.length;i++){
        const re=new RegExp('\\b'+names[i]+'=\\d+','g');
        if((data.match(re)||[]).length!==1)throw Error('模型参数位置不唯一：'+names[i]);
        data=data.replace(re,names[i]+'='+values[i]);
      }
    }
    return data;
  }};
  const moduleProxy={createRequire(file){
    const real=createRequire(file);
    return name=>name==='./pcb_layout.js' ? structuredClone(real(name)) : real(name);
  }};
  const sandbox={module:{exports:{}},__dirname:path.dirname(profileFile),
    require:name=>name==='node:fs'?fsProxy:name==='node:module'?moduleProxy:actualRequire(name)};
  vm.runInNewContext(fs.readFileSync(profileFile,'utf8'),sandbox,{filename:profileFile});
  return sandbox.module.exports.getModel('no_particles_v2');
}
const cases=[
  {scenario:'cfg_min',mode:'cfg',raw:low},
  {scenario:'cfg_max',mode:'cfg',raw:high},
  {scenario:'cfg_clamp_low',mode:'cfg',raw:Array(8).fill(0)},
  {scenario:'cfg_clamp_high',mode:'cfg',raw:Array(8).fill(65535)},
  {scenario:'cfg_same_tick',mode:'cfg_tick',raw:defaults.map((v,i)=>i===3?32:v)},
  {scenario:'cfg_during_busy',mode:'cfg_busy',raw:defaults.map((v,i)=>i===3?32:v)},
  {scenario:'cfg_retired_ignored',mode:'cfg_retired',raw:defaults},
];
const out=path.join(__dirname,'vectors/cfg_mc');fs.mkdirSync(out,{recursive:true});
const manifest=[];
for(const test of cases){
  const applied=test.raw.map((v,i)=>Math.max(low[i],Math.min(high[i],v)));
  const model=configuredModel(applied),base=configuredModel(defaults);
  const switching=test.mode==='cfg_tick'||test.mode==='cfg_busy';
  const state=(switching?base:model).pcbInitState();state.coreQ=256;
  const frames=300,stride=2736,bytes=Buffer.alloc(4+frames*stride);bytes.writeUInt32LE(frames);let offset=4;
  for(let n=0;n<frames;n++){
    const spectrum=pack.makeSpec('mixed',n<180?n:n-180,n<180?'boot':'play');
    (switching&&n===0?base:model).pcbStep(state,spectrum);
    Buffer.from(spectrum).copy(bytes,offset);offset+=128;
    for(const record of pack.packTrace(state))for(let lane=0;lane<4;lane++){bytes.writeUInt32LE(parseInt(record.slice(lane*8,lane*8+8),16),offset);offset+=4;}
    for(const word of pack.packMisc(state)){bytes.writeUInt32LE(parseInt(word,16),offset);offset+=4;}
  }
  const cfg=Buffer.alloc(16);test.raw.forEach((v,i)=>cfg.writeUInt16LE(v,i*2));
  fs.writeFileSync(path.join(out,test.scenario+'.bin'),bytes);fs.writeFileSync(path.join(out,test.scenario+'.cfg.bin'),cfg);
  manifest.push({...test,applied,frames,vector_sha256:sha(path.join(out,test.scenario+'.bin')),config_sha256:sha(path.join(out,test.scenario+'.cfg.bin'))});
}
fs.writeFileSync(path.join(out,'manifest.json'),JSON.stringify({profile:'no_particles_v2',scope:'Supplemental configurations; does not replace or rewrite baseline',model_sha256:sha(modelFile),profile_sha256:sha(profileFile),packer_sha256:sha(path.join(task,'reference/gen_state_vectors.cjs')),generator_sha256:sha(__filename),cases:manifest},null,2)+'\n');
console.log('配置补充黄金：7×300 帧；基线不改。');
