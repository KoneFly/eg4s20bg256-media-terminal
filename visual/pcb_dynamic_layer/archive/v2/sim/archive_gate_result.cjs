'use strict';
// 为已经实际执行的 TD rev2 报告绑定源码，并独立复核只读上游。
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const task=path.resolve(__dirname,'..'),project=path.resolve(task,'../../..');
const sha=file=>crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const audit=JSON.parse(fs.readFileSync(path.join(task,'sim/startup_audit_rev1/audit_result.json'),'utf8'));
const protectedSources=audit.sources.filter(s=>!s.file.startsWith('visual_workspace/rtl_handoff/pcb_dynamic_layer/')).map(s=>{
  const current=sha(path.join(project,s.file));
  if(current!==s.sha256.toLowerCase())throw new Error(`只读上游发生变化：${s.file}`);
  return {file:s.file,sha256:current,status:'UNCHANGED'};
});
for(const name of ['pcb_frame_updater.v','pcb_dynamic_roms.vh']){
  if(sha(path.join(task,'rtl',name))!==sha(path.join(task,'td_run/rev2',name)))throw new Error(`TD 归档与当前源码不一致：${name}`);
}
const files=['rev2/pcb_frame_updater.v','rev2/pcb_dynamic_roms.vh','w2_area_rev2.tcl','w2_area_rev2.log','w2_rev2_gate.area','w2_rev2_rtl.area'];
const manifest=Object.fromEntries(files.map(f=>[f,sha(path.join(task,'td_run',f))]));
fs.writeFileSync(path.join(task,'td_run/rev2/source_manifest.json'),JSON.stringify(manifest,null,2)+'\n');
const area=fs.readFileSync(path.join(task,'td_run/w2_rev2_gate.area'),'utf8');
const metric=name=>{const match=area.match(new RegExp('^[ \\t]*#'+name+'\\s+(\\d+)','m'));if(!match)throw new Error(`TD 缺少指标：${name}`);return Number(match[1]);};
const counts={lut:metric('lut'),total_luts:metric('Total_luts'),reg:metric('reg'),dsp:metric('dsp'),bram9k:metric('bram9k'),bram32k:metric('bram32k'),pad:metric('pad')};
const report={generated_utc:new Date().toISOString(),scope:'W2 optimize_gate area only; excludes external P bank, W1 and physical timing',status:counts.lut<=2500&&counts.dsp<=2?'PASS':'FAIL_RESOURCE_BUDGET',budget:{lut:2500,dsp:2},measured:counts,setup_wns:null,hold_wns:null,board_acceptance:'NOT_RUN',source_sha256:manifest,protected_sources:protectedSources};
fs.writeFileSync(path.join(task,'sim/td_result.json'),JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify({status:report.status,measured:counts,protected_sources_unchanged:protectedSources.length}));
