'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const reference=require('../reference/gen_overlay_vectors.cjs'),profiles=require('../reference/profiles.cjs');
const root=path.join(__dirname,'vectors/v2/w1');fs.mkdirSync(root,{recursive:true});
const cases=['all_empty','bar_step','bar_triangle','bar_saturate','bar_alternating','bar_random','alpha_zero','alpha_partial'];
let random=0x31415926;
const manifest=[];
for(const scenario of cases){
  const bars=Array.from({length:128},(_,i)=>{
    let h=0;
    if(scenario==='bar_step')h=(i%16)*17;
    if(scenario==='bar_triangle')h=Math.min(255,Math.abs(i-64)*4);
    if(['bar_saturate','alpha_zero','alpha_partial'].includes(scenario))h=255;
    if(scenario==='bar_alternating')h=i&1?255:0;
    if(scenario==='bar_random'){random=(Math.imul(random,1664525)+1013904223)>>>0;h=random>>>24;}
    return {h,peak:Math.min(255,h+9)};
  });
  const ovK=scenario==='alpha_zero'?0:scenario==='alpha_partial'?17:255;
  const snapshot={profile:profiles.PROFILE_V2,bars,parts:[],ovK};
  const dir=path.join(root,scenario);const stats=reference.writeFrame('independent synthetic T2',dir,snapshot);
  const misc=Buffer.alloc(140*4);
  bars.forEach((b,i)=>{const offset=(64+(i>>1))*4+(i&1)*2;misc[offset]=b.h;misc[offset+1]=b.peak;});
  misc.writeUInt32LE(ovK<<8,137*4);fs.writeFileSync(path.join(dir,'state_misc.bin'),misc);
  manifest.push({scenario,...stats,ovK,sha256:crypto.createHash('sha256').update(misc).digest('hex')});
}
fs.writeFileSync(path.join(root,'manifest.json'),JSON.stringify({profile:profiles.PROFILE_V2,pixels:640*480,span_pool_depth:6144,span_count_max:Math.max(...manifest.map(f=>f.spanCount)),generator_sha256:crypto.createHash('sha256').update(fs.readFileSync(__filename)).digest('hex'),reference_sha256:crypto.createHash('sha256').update(fs.readFileSync(path.join(__dirname,'../reference/gen_overlay_vectors.cjs'))).digest('hex'),object_tables_sha256:crypto.createHash('sha256').update(fs.readFileSync(path.resolve(__dirname,'../../../golden/pcb/obj_tables.json'))).digest('hex'),manifest},null,2)+'\n');
console.log('W1 V2 黄金已生成，最大区段 '+Math.max(...manifest.map(f=>f.spanCount)));
