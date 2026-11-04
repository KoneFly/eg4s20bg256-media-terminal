'use strict';
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),crypto=require('node:crypto');
const {createRequire}=require('node:module');
const file=path.resolve(__dirname,'../../../prototype/pcb_model.js');
const upstream=fs.readFileSync(file,'utf8');
const PROFILE_V2='no_particles_v2',PROFILE_V1='particles_v1';
const edits=[
  ['const nh=st.barH[i],r=pcbLfsr(st);','const nh=st.barH[i];'],
  [/    if\(st\.barCool\[i\]\)st\.barCool\[i\]--;\r?\n    else if\([^\n]+\r?\n      pcbEmit\(st,i,nh,r\);st\.barCool\[i\]=PCB_PART_COOL;\}/,''],
  ['  pcbParticles(st);',''],
];
function getModel(profile=PROFILE_V2){
  if(profile===PROFILE_V1)return require(file);
  if(profile!==PROFILE_V2)throw new Error(`未知基线配置档：${profile}`);
  let source=upstream;
  for(const [old,replacement] of edits){
    const matches=typeof old==='string' ? source.split(old).length-1 : (source.match(new RegExp(old.source,'g'))||[]).length;
    if(matches!==1)throw new Error('上游删除粒子适配位置不唯一，停止重出黄金');
    source=source.replace(old,replacement);
  }
  const sandbox={module:{exports:{}},require:createRequire(file)};
  vm.runInNewContext(source,sandbox,{filename:file});
  return sandbox.module.exports;
}
module.exports={getModel,PROFILE_V2,PROFILE_V1,upstream_sha256:crypto.createHash('sha256').update(upstream).digest('hex')};
