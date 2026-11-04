// 归档实测结果、验证证据与SHA；不执行综合、物理实现或出位。
const fs=require('fs'),path=require('path'),crypto=require('crypto');
const task=path.resolve(__dirname,'..');
const sha=p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
const file=p=>path.join(task,p);
const json=p=>JSON.parse(fs.readFileSync(file(p),'utf8'));
const gate=json('td_run/synth1g/RESULT.json');
const pLog=fs.readFileSync(file('td_run/place1/console.log'),'utf8');
const physicalFailure=pLog.match(/PHY-9009 ERROR: Design's mslice number = (\d+), exceeds the limit (\d+)\./);
if(!physicalFailure)throw Error('Expected preserved physical capacity failure missing');
const fixed=json('td_run/place1/SOURCE_MANIFEST.json');
const sourceChecks=fixed.files.map(r=>({path:r.path,sha256:r.sha256,match:sha(file('project/src/'+r.path))===r.sha256}));
if(sourceChecks.some(r=>!r.match))throw Error('Fixed implementation source drift');
const qor=fs.readFileSync(file('td_run/synth1g/checked.qor'),'utf8');
const value=name=>Number(qor.match(new RegExp(name+'\\s*\\|\\s*(-?\\d+)\\s*\\|'))?.[1]);
const record={status:'HOLD_PHYSICAL_CAPACITY',updated_utc:new Date().toISOString(),authorization:'fixed RTL physical measurement approved; stop again on over-budget',fixed_rtl_unchanged:true,source_checks:sourceChecks,sdc_sha256:sha(file('project/src/constraints/eth_m6_master.sdc')),area:{confidence:'Synthesized',evidence:'td_run/synth1g/gate.area',measured:gate.measured,limits:gate.limits},timing_before_sdc_loop_expansion:{confidence:'Synthesized',evidence:'td_run/synth1g/checked.timing',setup_wns_ns:value('Setup WNS')/1000,hold_wns_ns:value('Hold WNS')/1000,setup_violations:value('Num of violated S-EP'),hold_violations:value('Num of violated H-EP'),open:'7 CDC first-stage exceptions were not executed through foreach'},physical:{evidence:'td_run/place1/console.log',stage:'Place packing, incomplete',error_code:'PHY-9009',required_mslices:Number(physicalFailure[1]),capacity_mslices:Number(physicalFailure[2]),excess_mslices:Number(physicalFailure[1])-Number(physicalFailure[2]),route_status:'NOT_STARTED',area_report_status:'No completed physical area report',timing_status:'No completed physical STA'},bit_status:'NOT_GENERATED',board_status:'NOT_STARTED'};
record.sdc_precision_open=['ctrl_error_meta wildcard aliases source ctrl_error registers','rd_gray_w1 and wr_gray_r1 wildcard aliases bin[10] source endpoints','spectrum target wildcard aliases 1016 spectrum_hold shift endpoints into MC4'];
if(fs.existsSync(file('sim/integration_lint/cdc_audit/AUDIT.json'))){
 const audit=json('sim/integration_lint/cdc_audit/AUDIT.json');
 record.readonly_sdc_audit={evidence:'sim/integration_lint/cdc_audit/AUDIT.json',status:audit.status,signoff:audit.signoff,numeric_sta:audit.numeric_sta,missing_queries:audit.missing_queries,rom_status:audit.rom.status,rom_words_checked:audit.rom.words_checked,rom_mismatches:audit.rom.mismatches,physical_and_bit_data_verified:audit.rom.physical_and_bit_data_verified};
}
fs.writeFileSync(file('doc/output/MEASURED_GATE.json'),JSON.stringify(record,null,2)+'\n');
const warnings=gate.warnings.lines;
const groups={};for(const line of warnings){const key=line.match(/^([A-Z]+-\d+)/)?.[1]??'OTHER';(groups[key]??=[]).push(line);}
fs.writeFileSync(file('doc/output/TD_WARNING_REVIEW.json'),JSON.stringify({status:'OPEN',count:warnings.length,physical_failure:'PHY-9009, separate hard failure; not waived',groups},null,2)+'\n');
const inputs=['doc/output/MEASURED_GATE.json','doc/output/TD_WARNING_REVIEW.json','doc/output/M6_FDI_INTEGRATION_REPORT.md','doc/output/SOURCE_DIFF.json','doc/output/SOURCE_DIFF.patch','doc/output/PREFLIGHT.json','doc/output/BOARD_RECORD.md','doc/output/PROJECT_LEDGER.md','doc/output/LOADER_REUSE_LEDGER.md','doc/output/STREAM_REUSE_LEDGER.md','td_run/synth1g/SOURCE_MANIFEST.json','td_run/synth1g/gate.area','td_run/synth1g/gate.db','td_run/synth1g/console.log','td_run/synth1g/checked.qor','td_run/synth1g/checked.timing','td_run/place1/SOURCE_MANIFEST.json','td_run/place1/console.log','td_run/place1/run.tcl','sim/w2_display_result.json','sim/w2_display_failure.json','sim/evidence/verified_rgb_manifest.json','sim/evidence/verified_boot_silence_f299.png','sim/evidence/verified_play_mid_f299.png','sim/integration_lint/RESULT.json','sim/integration_lint/INPUT_MANIFEST.json','sim/integration_lint/WARNING_REVIEW.json','project/src/vendor/fdi_loader/tests/LOADER_VALIDATION_MANIFEST.json'];
for(const p of ['sim/integration_lint/cdc_audit/AUDIT.json','sim/integration_lint/cdc_audit/AUDIT.md','sim/integration_lint/cdc_audit/MANIFEST.json','sim/integration_lint/cdc_audit/PRODUCTION_IDENTITY.json','sim/integration_lint/cdc_audit/audit.sdc','sim/integration_lint/cdc_audit/audit.tcl','sim/integration_lint/cdc_audit/audit.timing','sim/integration_lint/cdc_audit/audit_ignored.timing','sim/integration_lint/cdc_audit/audit_exception.timing','sim/integration_lint/cdc_audit/console.log','sim/integration_lint/cdc_audit/gate_view.v'])if(fs.existsSync(file(p)))inputs.push(p);
const evidence={status:record.status,generated_utc:new Date().toISOString(),files:inputs.map(p=>({path:p,bytes:fs.statSync(file(p)).size,sha256:sha(file(p))}))};
fs.writeFileSync(file('doc/output/EVIDENCE_INDEX.json'),JSON.stringify(evidence,null,2)+'\n');
console.log(JSON.stringify({status:record.status,mslices:record.physical.required_mslices,limit:record.physical.capacity_mslices,fixed_source_checks:sourceChecks.length,evidence_files:evidence.files.length}));
