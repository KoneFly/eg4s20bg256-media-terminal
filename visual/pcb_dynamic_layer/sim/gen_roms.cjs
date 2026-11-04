'use strict';
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto');
const root = path.resolve(__dirname, '..');
const file = path.resolve(root, '../../prototype/pcb_model.js');
const model = require(file), g = model.PCB_GEO;
function rom(name, width, addrWidth, values) {
  return `function [${width - 1}:0] ${name};\ninput [${addrWidth - 1}:0] a;\nbegin\ncase (a)\n` +
    values.map((value, index) => `${addrWidth}'d${index}: ${name} = ${width}'h${BigInt.asUintN(width, BigInt(value)).toString(16)};`).join('\n') +
    `\ndefault: ${name} = ${width}'d0;\nendcase\nend\nendfunction\n`;
}
let out = '// 静态 ROM：由 sim/gen_roms.cjs 从只读模型生成。\n';
out += rom('trace_rom', 28, 7, g.traces.map(t => t.total | (t.ch << 7) | (t.slot << 14) | (t.rank << 17) | ((t.after + 1) << 21) | (t.nodes.length << 26)));
out += rom('trace_node_rom', 14, 8, g.traces.flatMap(t => [0, 1].map(q => t.nodes[q] ? t.nodes[q].at | (t.nodes[q].idx << 7) : 0)));
out += rom('node_rom', 27, 7, g.nodeTab.map(n => (n.traceIdx || 0) | ((n.at || 0) << 7) | ((n.line ? n.line.ch : n.ch || 0) << 14) | ((n.isPad || 0) << 21) | ((n.line ? 1 : 0) << 22) | ((n.line && n.line.type === 'dot' ? 1 : 0) << 23) | ((n.line ? 0 : g.traces[n.traceIdx].slot) << 24)));
out += rom('comp_rom', 14, 5, g.comps.map(c => c.traceIdx | (c.at << 7)));
// 预计算既有分段线性插值；256 个相位逐位等价，不改变平滑曲线。
const smoothGrid=Array.from({length:65},(_,i)=>Math.round(256*(i/64)**2*(3-2*i/64)));
out += rom('smooth_phase_rom',9,8,Array.from({length:256},(_,p)=>{
  const index=p>>2,delta=smoothGrid[index+1]-smoothGrid[index];
  return smoothGrid[index]+Math.floor(delta*(p&3)/4);
}));
out += rom('two_thirds_rom', 8, 8, Array.from({length:256}, (_, i) => Math.floor(i*2/3)));
out += rom('chip_rom', 8, 5, Array.from({length:32}, (_, i) => Math.min(255, Math.floor(i*255/24))));
fs.mkdirSync(path.join(root, 'rtl'), {recursive:true});
fs.writeFileSync(path.join(root, 'rtl/pcb_dynamic_roms_w2.vh'), out);
fs.writeFileSync(path.join(__dirname, 'rom_manifest.json'), JSON.stringify({model_sha256:crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex'), traces:g.traces.length, nodes:g.nodeTab.length, comps:g.comps.length, bars:g.bars.length}, null, 2)+'\n');
console.log('静态 ROM 已生成');
