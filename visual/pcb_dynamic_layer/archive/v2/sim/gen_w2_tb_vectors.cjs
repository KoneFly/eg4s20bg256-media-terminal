'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const gold=require('../reference/gen_state_vectors.cjs');
const profile=require('../reference/profiles.cjs'),model=profile.getModel();
const out=path.join(__dirname,'vectors/v2/w2');
fs.mkdirSync(out,{recursive:true});
const cases=['boot_silence','boot_low','play_low','play_mid','play_high','saturate','impulse_broadcast','silence_decay'];
const manifest=[];
for(const scenario of cases){
  const state=model.pcbInitState();state.coreQ=256;
  const legacy=gold.model.pcbInitState();legacy.coreQ=256;
  const frames=300, stride=128+512*4+140*4;
  const bytes=Buffer.alloc(4+frames*stride);bytes.writeUInt32LE(frames);
  let offset=4;
  for(let n=0;n<frames;n++){
    const spectrum=gold.makeSpec(scenario,n<180?n:n-180,n<180?'boot':'play');
    model.pcbStep(state,spectrum);gold.model.pcbStep(legacy,spectrum);
    if(JSON.stringify(gold.packTrace(state))!==JSON.stringify(gold.packTrace(legacy))||JSON.stringify(gold.packMisc(state))!==JSON.stringify(gold.packMisc(legacy)))throw Error('粒子删除污染 T1/T2 冻结语义');
    if(state.pLife.some(v=>v!==0)||state.lfsr!==0xace1)throw Error('无粒子配置档仍执行粒子路径');
    Buffer.from(spectrum).copy(bytes,offset);offset+=128;
    for(const record of gold.packTrace(state)) for(let lane=0;lane<4;lane++) {bytes.writeUInt32LE(parseInt(record.slice(lane*8,lane*8+8),16),offset);offset+=4;}
    for(const word of gold.packMisc(state)) {bytes.writeUInt32LE(parseInt(word,16),offset);offset+=4;}
  }
  fs.writeFileSync(path.join(out,scenario+'.bin'),bytes);
  manifest.push({scenario,frames,frame_stride:stride,sha256:crypto.createHash('sha256').update(bytes).digest('hex')});
}
fs.writeFileSync(path.join(out,'manifest.json'),JSON.stringify({profile:profile.PROFILE_V2,noninterference_frames:2400,model_sha256:profile.upstream_sha256,profile_sha256:crypto.createHash('sha256').update(fs.readFileSync(path.resolve(__dirname,'../reference/profiles.cjs'))).digest('hex'),generator_sha256:crypto.createHash('sha256').update(fs.readFileSync(__filename)).digest('hex'),packer_sha256:crypto.createHash('sha256').update(fs.readFileSync(path.resolve(__dirname,'../reference/gen_state_vectors.cjs'))).digest('hex'),manifest},null,2)+'\n');
console.log(`W2 TB 黄金：${cases.length}×300 帧`);
