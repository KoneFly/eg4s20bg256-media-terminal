'use strict';
// 当前 W2 测量、实际对拍与冻结黄金统一绑定；优化目标和硬门禁分开登记。
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const task=path.resolve(__dirname,'..'),project=path.resolve(task,'../../..');
const revision=process.argv[2]||'trial4';
const expect=(condition,message)=>{if(!condition)throw Error(message);};
expect(/^trial\d+$/.test(revision),'修订目录非法');
const dir='td_run/w2_mc/'+revision;
const read=file=>fs.readFileSync(path.join(task,file),'utf8').replace(/^\uFEFF/,'');
const json=file=>JSON.parse(read(file));
const sha=file=>crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const taskSha=file=>sha(path.join(task,file));
function check(file,hash){const current=taskSha(file);expect(current===hash.toLowerCase(),'来源变化：'+file);return current;}

const protectedSources=json('archive/v2/sim/startup_audit_rev1/audit_result.json').sources
  .filter(s=>!s.file.startsWith('visual_workspace/rtl_handoff/pcb_dynamic_layer/'))
  .map(s=>{const current=sha(path.join(project,s.file));expect(current===s.sha256.toLowerCase(),'受保护上游变化：'+s.file);return{file:s.file,sha256:current,status:'UNCHANGED'};});
for(const file of ['reference/profiles.cjs','reference/gen_state_vectors.cjs','sim/gen_w2_tb_vectors.cjs'])check(file,taskSha('archive/v2/'+file));
const golden=json('sim/vectors/v2/w2/manifest.json');
expect(golden.profile==='no_particles_v2','黄金配置档变化');
check('sim/vectors/v2/w2/manifest.json',taskSha('archive/v2/sim/vectors/v2/w2/manifest.json'));
for(const entry of golden.manifest){check('sim/vectors/v2/w2/'+entry.scenario+'.bin',entry.sha256);check('archive/v2/sim/vectors/v2/w2/'+entry.scenario+'.bin',entry.sha256);}

const sim=json('sim/sim_result_mc.json'),cfg=json('sim/cfg_result_mc.json'),mutation=json('sim/mutation_result_mc.json');
expect(sim.status==='PASS'&&sim.scenarios.length===10&&sim.scenarios.every(s=>s.frames===300),'默认/协议回归不完整');
expect(cfg.status==='PASS'&&cfg.scenarios.length===7&&cfg.scenarios.every(s=>s.frames===300),'配置补充回归不完整');
for(const report of [sim,cfg])for(const [name,hash]of Object.entries(report.source_sha256))check((name.endsWith('.cpp')?'tb/':'rtl/')+name,hash);
const compile=json('sim/w2_compile_manifest_mc.json').sources;
const cfgCompile=json('sim/w2_cfg_compile_manifest_mc.json').sources;
for(const name of ['pcb_frame_updater.v','pcb_ram_2k16.v','pcb_dynamic_roms_w2.vh','tb_w2.cpp']){
  expect(compile[name]===sim.source_sha256[name]&&cfgCompile[name]===cfg.source_sha256[name],'实际编译输入与收集结果不一致：'+name);
}
expect(mutation.status==='KILLED'&&mutation.exit_code===1&&mutation.failure.includes('T1 addr='),'变异未被数据检查杀死');
check('rtl/pcb_frame_updater.v',mutation.original_sha256);check('tb/tb_w2.cpp',mutation.tb_sha256);
check('sim/vectors/v2/w2/boot_silence.bin',mutation.vector_sha256);
check('sim/gen_cfg_tb_vectors.cjs',cfg.golden_manifest.generator_sha256);
check('reference/profiles.cjs',cfg.golden_manifest.profile_sha256);
check('reference/gen_state_vectors.cjs',cfg.golden_manifest.packer_sha256);
for(const item of cfg.golden_manifest.cases){check('sim/vectors/cfg_mc/'+item.scenario+'.bin',item.vector_sha256);check('sim/vectors/cfg_mc/'+item.scenario+'.cfg.bin',item.config_sha256);}
expect(golden.model_sha256===cfg.golden_manifest.model_sha256,'配置补充黄金的原模型变化');
expect(JSON.stringify(json('sim/vectors/cfg_mc/manifest.json'))===JSON.stringify(cfg.golden_manifest),'配置收集器的黄金清单已过期');
for(const entry of sim.scenarios){
  const lines=read('sim/logs/w2_mc/'+entry.scenario+'.log').trim().split(/\r?\n/);
  const actual=JSON.parse(lines[lines.length-1]);
  expect(actual.status==='PASS'&&actual.scenario===entry.scenario&&actual.frames===entry.frames&&actual.max_update_cycles===entry.max_update_cycles,'实际运行日志与默认收集结果不一致：'+entry.scenario);
}
expect(!/%(?:Warning|Error)/.test(read('sim/logs/w2_mc/w2_lint.log')),'lint 告警未清零');
for(const name of ['rtl/pcb_particle_overlay.v','rtl/pcb_span_ram.v','tb/tb_w1.cpp','sim/run_w1.sh','sim/gen_w1_tb_vectors.cjs','reference/gen_overlay_vectors.cjs','sim/vectors/v2/w1'])expect(!fs.existsSync(path.join(task,name)),'W1 活动内容未出列：'+name);

function measure(directory){
  const area=read(directory+'/area.txt'),timing=read(directory+'/timing.txt'),log=read(directory+'/run.log');
  expect(log.includes('W2_MC_TD_COMPLETE')&&!/\bERROR\b/.test(log),'TD 未完整结束：'+directory);
  expect(area.includes('Report Model: pcb_frame_updater Device: EG4S20BG256'),'TD 顶层或器件变化');
  const metric=name=>{const match=area.match(new RegExp('^[ \\t]*#'+name+'\\s+(\\d+)','m'));expect(match,'指标缺失：'+name);return Number(match[1]);};
  const slack=name=>Number(timing.match(new RegExp('\\b'+name+':\\s*([-\\d.]+)ns'))[1]);
  const fields=timing.match(/^\s*clk0\s+local\s+(.+)$/m)[1].trim().split(/\s+/);
  const confidence=timing.match(/^Confidence\s*:\s*(\S+)/m)[1];
  const coverage=Number(timing.match(/^STA coverage\s*:\s*([\d.]+)%/m)[1]);
  expect(confidence==='Synthesized'&&coverage===100&&Number(fields[2])===20&&Number(fields[3])===50,'TD 时序口径改变');
  const max=timing.match(/Max\s*: SWNS\s+[-\d.]+ns, STNS\s+[-\d.]+ns,\s*(\d+) Viol Endpoints/);
  const min=timing.match(/Min\s*: HWNS\s+[-\d.]+ns, HTNS\s+[-\d.]+ns,\s*(\d+) Viol Endpoints/);
  const warnings=log.split(/\r?\n/).filter(line=>/\bWARNING:/.test(line));
  const warningCounts={};for(const line of warnings){const code=line.match(/^(\S+) WARNING:/)[1];warningCounts[code]=(warningCounts[code]||0)+1;}
  return{
    measured:{lut:metric('lut'),total_luts:metric('Total_luts'),reg:metric('reg'),dsp:metric('dsp'),bram9k:metric('bram9k'),bram32k:metric('bram32k'),pad:metric('pad')},
    sta:{confidence,coverage_percent:coverage,clock_frequency_mhz:50,clock_period_ns:20,reported_min_period_ns:Number(fields[4]),reported_fmax_mhz:Number(fields[5]),setup_wns_ns:slack('SWNS'),setup_tns_ns:slack('STNS'),hold_wns_ns:slack('HWNS'),hold_tns_ns:slack('HTNS'),setup_violating_endpoints:Number(max[1]),hold_violating_endpoints:Number(min[1])},
    warnings:{status:warnings.length?'OPEN':'NONE',counts:warningCounts,lines:warnings},
  };
}
const result=measure(dir);
check(dir+'/clock.sdc',taskSha('archive/v2/td_run/v2/w2/clock.sdc'));
const sources=['pcb_frame_updater.v','pcb_ram_2k16.v','pcb_dynamic_roms_w2.vh'];
for(const name of sources)check(dir+'/'+name,compile[name]);
const inputManifest=json(dir+'/input_manifest.json');
for(const [name,hash]of Object.entries(inputManifest))check(dir+'/'+name,hash);
const artifacts=[...sources,'clock.sdc','run.tcl','input_manifest.json','run.log','rtl.area','area.txt','timing.txt','resource.qor'];
const artifactHashes=Object.fromEntries(artifacts.map(name=>[name,taskSha(dir+'/'+name)]));
const maxCycles=Math.max(sim.max_update_cycles,cfg.max_update_cycles);
const gates={lut_minimum:result.measured.lut<=4500?'PASS':'FAIL',lut_optimized_target:result.measured.lut<=4000?'PASS':'NOT_MET',dsp:result.measured.dsp<=2?'PASS':'FAIL',setup:result.sta.setup_wns_ns>=0&&result.sta.setup_tns_ns===0&&result.sta.setup_violating_endpoints===0?'PASS_SYNTHESIZED':'FAIL',hold:result.sta.hold_wns_ns>=0&&result.sta.hold_tns_ns===0&&result.sta.hold_violating_endpoints===0?'PASS_SYNTHESIZED':'FAIL',frame_cycles:maxCycles<=833333?'PASS':'FAIL'};
const iterations=[];
for(const name of ['trial1','trial2','trial3','trial4']){const previous=measure('td_run/w2_mc/'+name);iterations.push({revision:name,...previous.measured,...previous.sta,source_sha256:taskSha('td_run/w2_mc/'+name+'/pcb_frame_updater.v')});}
const evidenceFiles=['sim/sim_result_mc.json','sim/cfg_result_mc.json','sim/mutation_result_mc.json','sim/w2_compile_manifest_mc.json','sim/w2_cfg_compile_manifest_mc.json','sim/vectors/v2/w2/manifest.json','sim/vectors/cfg_mc/manifest.json','sim/logs/w2_mc/w2_lint.log','sim/logs/w2_mc/mutation.log','sim/logs/w2_mc/cfg.log',...sim.scenarios.map(s=>'sim/logs/w2_mc/'+s.scenario+'.log')];
const report={
  generated_utc:new Date().toISOString(),scope:'W2 only; independent optimize_gate area and synthesized STA; no board selection or integration',
  profile:'no_particles_v2',revision,measurement_status:'COMPLETE',
  hard_gate_status:Object.entries(gates).filter(([key])=>key!=='lut_optimized_target').every(([,value])=>value.startsWith('PASS'))?'PASS':'FAIL',
  budget:{lut_minimum:4500,lut_optimized_target:4000,lut_metric:'#lut',dsp:2,frame_cycles:833333},...result,gates,
  functional_evidence:{default_and_protocol_frames:sim.scenarios.reduce((n,s)=>n+s.frames,0),configuration_supplement_frames:cfg.scenarios.reduce((n,s)=>n+s.frames,0),default_max_update_cycles:sim.max_update_cycles,all_tested_max_update_cycles:maxCycles,fixed_baseline_sha_status:'UNCHANGED',mutation:mutation.status,complete_per_parameter_boundary_matrix:'NOT_RUN',gate_primitive_simulation:'NOT_RUN',w1:'RETIRED_ARCHIVED'},
  source_sha256:sim.source_sha256,artifacts:{directory:dir,sha256:artifactHashes},iterations,protected_sources:protectedSources,
  evidence_sha256:Object.fromEntries(evidenceFiles.map(name=>[name,taskSha(name)])),archive_script_sha256:taskSha('sim/archive_mc_result.cjs'),
  limitations:['4000 LUT optimized target is not met.','Synthesized STA only; no placement/routing or board acceptance.','1105-pad internal-interface top exceeds 188 device pads; used only for logic measurement.','Behavioral RAM passed Verilator; TD primitive gate simulation was not run.','Combined extrema/lock tests do not cover the complete per-parameter boundary matrix.'],
};
fs.writeFileSync(path.join(task,dir,'source_manifest.json'),JSON.stringify({generated_utc:report.generated_utc,source_sha256:report.source_sha256,artifact_sha256:artifactHashes},null,2)+'\n');
fs.writeFileSync(path.join(task,'sim/td_result_mc.json'),JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify({hard_gate_status:report.hard_gate_status,measured:report.measured,sta:report.sta,gates,frames:report.functional_evidence,protected_sources_unchanged:protectedSources.length}));
