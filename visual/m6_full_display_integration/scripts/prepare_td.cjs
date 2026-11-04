// 将当前任务源冻结到独立ASCII目录，绑定综合输入身份。
const fs=require('fs'),path=require('path'),crypto=require('crypto');
const task=path.resolve(__dirname,'..');
const [stageArg,outArg,mode='synth']=process.argv.slice(2);
if(!stageArg||!outArg||!['synth','route'].includes(mode))throw Error('usage: prepare_td.cjs stage out synth|route');
const stage=path.resolve(stageArg),out=path.resolve(outArg);
const source=path.join(task,'project/src');
const hash=p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
function list(dir){return fs.readdirSync(dir,{withFileTypes:true}).sort((a,b)=>a.name.localeCompare(b.name)).flatMap(e=>e.isDirectory()?list(path.join(dir,e.name)):[path.join(dir,e.name)]);}
if(!fs.existsSync(path.join(stage,'src')))throw Error('PowerShell source snapshot missing');
const project=path.resolve(task,'../../..');
const baseline=path.join(project,'iccoder_workspace/tasks/task_052_ethernet_pcm_link/td_run/v9_display_20261004_final2');
const originalRead=fs.readFileSync(path.join(baseline,'physical_build.log'),'utf8').match(/read_hdl -file (.+?) -top eth_udp_m6_master_top/);
if(!originalRead)throw Error('baseline HDL list missing');
const old=originalRead[1].trim().split(/\s+/).map(p=>p.replace(/^.*?\/(rtl|vendor)\//,'$1/'));
const selected=new Set(old.filter(p=>!['vendor/udp_base/import/clk_gen_rst_gen.v','vendor/udp_base/import/div_clk_gen.v'].includes(p)));
for(const file of list(source)){
 const rel=path.relative(source,file).replace(/\\/g,'/');
 if(rel.endsWith('.v')&&(rel.startsWith('rtl/fdi_')||/^vendor\/(w2|fdi_loader|fdi_stream)\//.test(rel)))selected.add(rel);
}
const compiled=[...selected].sort();
for(const rel of compiled)if(!fs.existsSync(path.join(stage,'src',rel)))throw Error('HDL missing '+rel);
const manifest={generated_utc:new Date().toISOString(),mode,top:'eth_udp_m6_master_top',compiled_files:compiled,files:list(path.join(stage,'src')).map(p=>({path:path.relative(path.join(stage,'src'),p).replace(/\\/g,'/'),sha256:hash(p)})),row_span_sha256:hash(path.join(stage,'rom_row_span.hex'))};
fs.writeFileSync(path.join(out,'SOURCE_MANIFEST.json'),JSON.stringify(manifest,null,2)+'\n');
const root=stage.replace(/\\/g,'/');
const script=[
 'if {[catch {',`set ROOT {${root}}`,'set TOP eth_udp_m6_master_top',
 'import_device eagle_s20.db -package EG4S20BG256','set_param flow qor_monitor on',
 `read_hdl -file {${compiled.map(p=>root+'/src/'+p).join(' ')}} -top eth_udp_m6_master_top`,
 'read_adc "$ROOT/src/constraints/eth_m6_master.adc"','optimize_rtl','report_area -file "$ROOT/rtl.area"',
 'read_sdc $ROOT/src/constraints/eth_m6_master.sdc','optimize_gate','legalize_phy_inst',
 'clear_user_sdc','read_sdc $ROOT/src/constraints/eth_m6_master.sdc','update_timing',
 'report_timing_status -file "$ROOT/gate.ts"','report_timing_summary -ep_num 40 -file "$ROOT/gate.timing"',
 'report_qor -step gate -file "$ROOT/gate.qor"','report_area -io_info -file "$ROOT/gate.area"',
 'export_db "$ROOT/gate.db"','puts "FDI_SYNTH_COMPLETE"',
];
if(mode==='route')script.push('place','update_timing -mode manhattan','report_timing_summary -ep_num 40 -file "$ROOT/place.timing"','route','clear_user_sdc','read_sdc $ROOT/src/constraints/eth_m6_master.sdc','update_timing -mode final','report_timing_status -file "$ROOT/route.ts"','report_timing_summary -ep_num 40 -file "$ROOT/route.timing"','report_timing_ignored -ep_num 2000 -file "$ROOT/ignored.timing"','report_qor -step route -file "$ROOT/route.qor"','report_area -io_info -file "$ROOT/route.area"','write_verilog "$ROOT/route_netlist.v"','export_db "$ROOT/route.db"','puts "FDI_ROUTE_COMPLETE"');
script.push('} message]} {puts "FDI_ERROR: $message"}','exit');
fs.writeFileSync(path.join(out,'run.tcl'),script.join('\n')+'\n');
console.log(JSON.stringify({stage:root,mode,compiled:compiled.length,manifest_sha256:hash(path.join(out,'SOURCE_MANIFEST.json'))}));
