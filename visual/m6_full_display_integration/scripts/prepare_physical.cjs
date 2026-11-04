// 固定既有网表与全部RTL，仅允许本轮已批准的SDC执行写法适配。
const fs=require('fs'),path=require('path'),crypto=require('crypto');
const task=path.resolve(__dirname,'..');
const [stageArg,outArg,inputArg,mode]=process.argv.slice(2);
if(!['place','route'].includes(mode))throw Error('physical mode must be place|route');
const stage=path.resolve(stageArg),out=path.resolve(outArg),input=path.resolve(inputArg);
const root=stage.replace(/\\/g,'/');
const sha=p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
const frozen=path.join(task,'td_run/synth1g');
const prior=JSON.parse(fs.readFileSync(path.join(frozen,'SOURCE_MANIFEST.json')));
const checked=prior.compiled_files.concat(['vendor/w2/pcb_dynamic_roms_w2.vh','vendor/fdi_stream/fdi_row_span_rom.vh','constraints/eth_m6_master.adc']);
for(const rel of checked)if(sha(path.join(stage,'src',rel))!==sha(path.join(frozen,'src',rel)))throw Error('Fixed RTL changed: '+rel);
if(mode==='route'){
 const gate=JSON.parse(fs.readFileSync(path.join(input,'RESULT.json')));
 if(!gate.complete||gate.failure||!gate.budget_pass||!gate.constraints_valid)throw Error('Refuse route: previous placed resource/constraints gate failed');
}
const manifest={generated_utc:new Date().toISOString(),mode,top:prior.top,fixed_rtl_origin:'td_run/synth1g',rtl_unchanged:true,compiled_files:prior.compiled_files,files:checked.map(p=>({path:p,sha256:sha(path.join(stage,'src',p))})),sdc_sha256:sha(path.join(stage,'src/constraints/eth_m6_master.sdc')),input_db_sha256:sha(path.join(stage,'input.db'))};
fs.writeFileSync(path.join(out,'SOURCE_MANIFEST.json'),JSON.stringify(manifest,null,2)+'\n');
const lines=['if {[catch {',`import_db ${root}/input.db`,'clear_user_sdc',`read_sdc ${root}/src/constraints/eth_m6_master.sdc`,mode==='place'?'place':'route',mode==='place'?'update_timing -mode manhattan':'update_timing -mode final',`report_area -io_info -file ${root}/${mode}.area`,`report_timing_status -file ${root}/${mode}.ts`,`report_timing_summary -ep_num 40 -file ${root}/${mode}.timing`,`report_timing_ignored -ep_num 2000 -file ${root}/${mode}_ignored.timing`,`report_qor -step ${mode} -file ${root}/${mode}.qor`,`write_verilog ${root}/${mode}_netlist.v`,`export_db ${root}/${mode}.db`,`puts FDI_${mode.toUpperCase()}_COMPLETE`,'} fdi_error]} {puts "FDI_PHY_ERROR: $fdi_error"}','exit'];
fs.writeFileSync(path.join(out,'run.tcl'),lines.join('\n')+'\n');
console.log(JSON.stringify({mode,stage:root,fixed_rtl:true,manifest_sha256:sha(path.join(out,'SOURCE_MANIFEST.json'))}));
