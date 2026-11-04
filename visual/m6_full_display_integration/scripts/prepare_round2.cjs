// 第二轮独立阶段与冻结源检查；所有TD路径在ASCII快照中。
const fs=require('fs'),path=require('path'),crypto=require('crypto'),cp=require('child_process');
const task=path.resolve(__dirname,'..');
const [stageArg,outArg,mode,inputArg,holdStrategy='buffer',routeEffort='normal',placeSeed='0',routeStrategy='normal',flowThreads='auto']=process.argv.slice(2);
if(!['synth','check','pcheck','place','route','hold','prehold','bit'].includes(mode))throw Error('Invalid mode');
const stage=path.resolve(stageArg),out=path.resolve(outArg),root=stage.replace(/\\/g,'/');
const sha=p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
const frozen=path.join(task,'td_run/synth1g'),old=JSON.parse(fs.readFileSync(path.join(frozen,'SOURCE_MANIFEST.json')));
const allowed=new Set(['rtl/fdi_label_store.v','vendor/fdi_loader/fdi_fat32_file_streamer.v','vendor/fdi_loader/fdi_fat32_volume_scanner.v']);
const checked=old.compiled_files.concat(['vendor/w2/pcb_dynamic_roms_w2.vh','vendor/fdi_stream/fdi_row_span_rom.vh','constraints/eth_m6_master.adc']).filter(p=>!allowed.has(p));
for(const rel of checked)if(sha(path.join(stage,'src',rel))!==sha(path.join(frozen,'src',rel)))throw Error('Frozen source changed: '+rel);
cp.execFileSync(process.execPath,[path.join(__dirname,'prepare_td.cjs'),stage,out,'synth'],{stdio:'inherit'});
const manifestPath=path.join(out,'SOURCE_MANIFEST.json'),manifest=JSON.parse(fs.readFileSync(manifestPath));
manifest.mode=mode;manifest.round=2;manifest.frozen_round1_checks=checked.length;
manifest.sdc_sha256=sha(path.join(stage,'src/constraints/eth_m6_master.sdc'));
manifest.active_sdc_sha256=sha(path.join(stage,'production.sdc'));
manifest.flow_threads=flowThreads;
if(mode==='hold')manifest.hold_strategy=holdStrategy;
if(mode==='route'){manifest.route_effort=routeEffort;manifest.route_strategy=routeStrategy;}
if(mode==='place')manifest.place_seed=Number(placeSeed);
if(mode!=='synth'){
 const input=path.resolve(inputArg),result=JSON.parse(fs.readFileSync(path.join(input,'RESULT.json')));
 manifest.input_tag=path.basename(input);
 if((!result.complete||result.failure)&&!(mode==='route'&&routeStrategy==='repair'&&result.physical_gate_pass&&fs.existsSync(path.join(input,'failed_route.db'))))throw Error('Input TD stage failed');
 if(['route','hold','prehold','bit'].includes(mode)&&!result.physical_gate_pass)throw Error('Physical gate not passed');
 if(mode==='bit'){
  if(!result.timing_pass||result.status!=='PASS_STAGE')throw Error('Final timing gate not passed');
  const cdc=JSON.parse(fs.readFileSync(path.join(input,'CDC_AUDIT.json')));
  const rom=JSON.parse(fs.readFileSync(path.join(input,'ROM_AUDIT.json')));
  if(cdc.status!=='PASS_PRECISE_SCOPE'||rom.status!=='PASS_ROM_INIT')throw Error('Final CDC/ROM audit not passed');
  manifest.signoff_cdc_sha256=sha(path.join(input,'CDC_AUDIT.json'));
  manifest.signoff_rom_sha256=sha(path.join(input,'ROM_AUDIT.json'));
 }
 const prior=JSON.parse(fs.readFileSync(path.join(input,'SOURCE_MANIFEST.json')));
 for(const rel of manifest.compiled_files)if(sha(path.join(input,'src',rel))!==sha(path.join(stage,'src',rel)))throw Error('Stage RTL drift: '+rel);
 manifest.input_db_sha256=sha(path.join(stage,'input.db'));manifest.input_manifest_sha256=sha(path.join(input,'SOURCE_MANIFEST.json'));
 manifest.input_physical_mslices=result.measured.mslices;
 if(manifest.sdc_sha256!==prior.sdc_sha256)manifest.constraint_revision=true;
}
fs.writeFileSync(manifestPath,JSON.stringify(manifest,null,2)+'\n');
const expected=JSON.parse(fs.readFileSync(fs.existsSync(path.join(stage,'ACTIVE_SDC_EXPECTED.json'))?path.join(stage,'ACTIVE_SDC_EXPECTED.json'):path.join(task,'doc/output/ROUND2_SDC_EXPECTED.json')));
const audit=[...expected.false_data_endpoints,...expected.mcp_data_endpoints,
 ...(fs.existsSync(path.join(stage,'ACTIVE_SDC_EXPECTED.json'))?[]:Array.from({length:8},(_,i)=>`u_display/u_scan/ctrl_error_meta_reg[${i}].d`))];
const commands=[];
if(mode==='synth'){
 const orig=fs.readFileSync(path.join(out,'run.tcl'),'utf8');
 commands.push(...orig.split('\n').slice(0,orig.split('\n').findIndex(l=>l.startsWith('export_db'))).map(l=>l.startsWith('read_sdc ')?`read_sdc ${root}/production.sdc`:l));
}else{
 commands.push('if {[catch {',`set ROOT {${root}}`,`import_db ${root}/input.db`,'clear_user_sdc',`read_sdc ${root}/production.sdc`,'update_timing',`report_timing_summary -ep_num 1 -file ${root}/pre.timing`,`set fp [open ${root}/pre.timing r]`,'set pre [read $fp]','close $fp','if {[string first production.sdc $pre] < 0} {error R2_SDC_NOT_LOADED}');
 if(flowThreads!=='auto')commands.push(`set_param flow thread ${flowThreads}`);
 if(mode==='prehold')commands.push('set_param place hold_fix high','phys_opt -hold_fix -post_clock_route -effort high','update_timing -mode manhattan');
 else if(mode==='hold'){
  const cmd={buffer:'fix_hold -buffer_opt -eco',clock:'fix_hold -clock_opt -eco',miso:'fix_hold -net sd_miso_dup_15 -buffer_opt -eco',miso_clock:'fix_hold -net sd_miso_dup_15 -clock_opt -eco'}[holdStrategy];
  if(!cmd)throw Error('Invalid hold strategy');
  commands.push('set_param route hold_fix_iteration 20',cmd,'update_timing -mode final');
 }
 else if(mode==='bit')commands.push('update_timing -mode final',`bitgen -bit ${root}/eth_udp_m6_master_top.bit`);
 else if(!['check','pcheck'].includes(mode)){
  if(mode==='route')commands.push(`set_param route effort ${routeEffort}`);
  if(mode==='place'&&Number(placeSeed)!==0)commands.push('set_param flow enable_seed on',`set_param place seed ${Number(placeSeed)}`);
  if(mode==='route'&&routeStrategy==='repair')commands.push(`report_route_status -remove_invalid_route -file ${root}/cleanup.txt`);
  commands.push(mode==='route'&&['incremental','repair'].includes(routeStrategy)?'route -incremental':mode,mode==='place'?'update_timing -mode manhattan':'update_timing -mode final');
 }
 const reportStep=mode==='check'?'gate':['pcheck','prehold'].includes(mode)?'place':['hold','bit'].includes(mode)?'route':mode;
 commands.push(`report_timing_status -file ${root}/${reportStep}.ts`,`report_timing_summary -ep_num 40 -file ${root}/${reportStep}.timing`,`report_qor -step ${reportStep} -file ${root}/${reportStep}.qor`,`report_area -io_info -file ${root}/${reportStep}.area`);
}
const step=['synth','check'].includes(mode)?'gate':['pcheck','prehold'].includes(mode)?'place':['hold','bit'].includes(mode)?'route':mode;
commands.push(`export_db ${root}/${step}.db`);
commands.push(`report_timing_exception -ep_num 4000 -file ${root}/${step}_exception.timing`, `report_timing_ignored -ep_num 4000 -file ${root}/${step}_ignored.timing`,`write_verilog ${root}/${step}_netlist.v`);
if(step==='route')commands.push('report_route_status -drc');
for(const p of [...new Set(audit)])commands.push(`puts [format {R2_PIN ${p} %s} [get_pins {${p}}]]`);
commands.push(`puts FDI_R2_${mode.toUpperCase()}_COMPLETE`);
commands.push(mode==='route'
 ? `} fdi_error]} {puts "FDI_R2_ERROR: $fdi_error"; catch {export_db ${root}/failed_route.db}; catch {report_route_status -drc -file ${root}/failed_route_status.txt}}`
 : '} fdi_error]} {puts "FDI_R2_ERROR: $fdi_error"}','exit');
fs.writeFileSync(path.join(out,'run.tcl'),commands.join('\n')+'\n');
