'use strict';
// 归档已完成的独立 TD 测量；预算失败照实保留，不据此生成验收通过。
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const task = path.resolve(__dirname, '..');
const project = path.resolve(task, '../../..');
const read = file => fs.readFileSync(path.join(task, file), 'utf8');
const json = file => JSON.parse(read(file));
const sha = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const taskSha = file => sha(path.join(task, file));
const expect = (condition, message) => { if (!condition) throw new Error(message); };

function checkedHash(file, expected) {
  const current = taskSha(file);
  expect(current === expected.toLowerCase(), `证据与当前文件不一致：${file}`);
  return current;
}

const audit = json('sim/startup_audit_rev1/audit_result.json');
const protectedSources = audit.sources
  .filter(s => !s.file.startsWith('visual_workspace/rtl_handoff/pcb_dynamic_layer/'))
  .map(s => {
    const current = sha(path.join(project, s.file));
    expect(current === s.sha256.toLowerCase(), `只读上游发生变化：${s.file}`);
    return { file: s.file, sha256: current, status: 'UNCHANGED' };
  });

const w2Sim = json('sim/sim_result_v2.json');
const w1Sim = json('sim/w1_result_v2.json');
const w2Golden = json('sim/vectors/v2/w2/manifest.json');
const w1Golden = json('sim/vectors/v2/w1/manifest.json');
expect([w2Sim, w1Sim, w2Golden, w1Golden].every(x => x.profile === 'no_particles_v2'), '必须使用 V2 无粒子配置档');
for (const sim of [w2Sim, w1Sim]) {
  for (const [name, hash] of Object.entries(sim.source_sha256)) {
    checkedHash(`${name.endsWith('.cpp') ? 'tb' : 'rtl'}/${name}`, hash);
  }
}
checkedHash('reference/profiles.cjs', w2Golden.profile_sha256);
checkedHash('sim/gen_w2_tb_vectors.cjs', w2Golden.generator_sha256);
checkedHash('reference/gen_state_vectors.cjs', w2Golden.packer_sha256);
expect(sha(path.join(project, 'visual_workspace/prototype/pcb_model.js')) === w2Golden.model_sha256, 'W2 黄金模型变化');
for (const item of w2Golden.manifest) checkedHash(`sim/vectors/v2/w2/${item.scenario}.bin`, item.sha256);
checkedHash('sim/gen_w1_tb_vectors.cjs', w1Golden.generator_sha256);
checkedHash('reference/gen_overlay_vectors.cjs', w1Golden.reference_sha256);
expect(sha(path.join(project, 'visual_workspace/golden/pcb/obj_tables.json')) === w1Golden.object_tables_sha256, 'W1 黄金布局变化');
for (const files of Object.entries(w1Sim.golden_sha256)) {
  for (const [name, hash] of Object.entries(files[1])) checkedHash(`sim/vectors/v2/w1/${files[0]}/${name}`, hash);
}

const mutation = json('sim/mutation_result_v2.json');
checkedHash('rtl/pcb_frame_updater.v', mutation.original_sha256);
checkedHash('tb/tb_w2.cpp', mutation.tb_sha256);
checkedHash('sim/vectors/v2/w2/boot_silence.bin', mutation.vector_sha256);
expect(mutation.status === 'KILLED' && mutation.exit_code === 1 && mutation.failure.startsWith('FAIL:'), '变异未被正常运行的 TB 杀死');
expect(w2Sim.status === 'PASS' && w2Sim.scenarios.length === 10, 'W2 实际完整回归缺失');
expect(w1Sim.pixel_comparison === 'PASS' && w1Sim.scenarios.length === 8, 'W1 完整帧对拍缺失');

function measure(label, top, sources, lutBudget) {
  const dir = `td_run/v2/${label}`;
  const log = read(`${dir}/run.log`);
  const area = read(`${dir}/area.txt`);
  const timing = read(`${dir}/timing.txt`);
  expect(log.includes('V2_TD_COMPLETE') && !/\bERROR\b/.test(log), `${label} TD 未完整结束或存在 ERROR`);
  expect(area.includes(`Report Model: ${top} Device: EG4S20BG256`) && timing.includes(`Top Model           : ${top}`), `${label} TD 顶层不匹配`);
  const compiled = json(`sim/${label}_compile_manifest_v2.json`).sources;
  const sourceSha256 = {};
  for (const name of sources) {
    sourceSha256[name] = checkedHash(`rtl/${name}`, compiled[name]);
    checkedHash(`${dir}/${name}`, sourceSha256[name]);
  }
  const metric = name => {
    const match = area.match(new RegExp(`^[ \\t]*#${name}\\s+(\\d+)`, 'm'));
    expect(match, `${label} TD 缺少指标：${name}`);
    return Number(match[1]);
  };
  const slack = name => {
    const match = timing.match(new RegExp(`\\b${name}:\\s*([-\\d.]+)ns`));
    expect(match, `${label} TD 缺少时序指标：${name}`);
    return Number(match[1]);
  };
  const clock = timing.match(/^\s*clk0\s+local\s+(.+)$/m);
  expect(clock, `${label} 时钟统计缺失`);
  const fields = clock[1].trim().split(/\s+/);
  const confidence = timing.match(/^Confidence\s*:\s*(\S+)/m)[1];
  const coverage = Number(timing.match(/^STA coverage\s*:\s*([\d.]+)%/m)[1]);
  expect(confidence === 'Synthesized', `${label} 报告级别变化，需重新说明口径`);
  const warnings = log.split(/\r?\n/).filter(line => /\bWARNING:/.test(line));
  const warningCounts = {};
  for (const warning of warnings) {
    const signature = warning.match(/^(\S+) WARNING:/)[1];
    warningCounts[signature] = (warningCounts[signature] || 0) + 1;
  }
  const measured = Object.fromEntries(['lut', 'Total_luts', 'reg', 'dsp', 'bram9k', 'bram32k', 'pad'].map(name => [name === 'Total_luts' ? 'total_luts' : name, metric(name)]));
  const sta = {
    confidence, coverage_percent: coverage, clock_period_ns: Number(fields[2]),
    clock_frequency_mhz: Number(fields[3]), reported_min_period_ns: Number(fields[4]),
    reported_fmax_mhz: Number(fields[5]), setup_wns_ns: slack('SWNS'),
    setup_tns_ns: slack('STNS'), hold_wns_ns: slack('HWNS'), hold_tns_ns: slack('HTNS'),
  };
  const gates = {
    lut: measured.lut <= lutBudget ? 'PASS' : 'FAIL',
    dsp: measured.dsp <= 2 ? 'PASS' : 'FAIL',
    setup: sta.setup_wns_ns >= 0 ? 'PASS_SYNTHESIZED' : 'FAIL_SYNTHESIZED',
    hold: sta.hold_wns_ns >= 0 ? 'PASS_SYNTHESIZED' : 'FAIL_SYNTHESIZED',
  };
  const artifactNames = [...sources, 'clock.sdc', 'run.tcl', 'run.log', 'area.txt', 'timing.txt', 'resource.qor'];
  const artifactSha256 = Object.fromEntries(artifactNames.map(name => [name, taskSha(`${dir}/${name}`)]));
  return {
    label: label.toUpperCase(), top, measurement_status: 'COMPLETE',
    device_for_measurement: 'EG4S20BG256', budget: { lut: lutBudget, dsp: 2, lut_metric: '#lut' },
    measured, sta, gates, warnings: { status: warnings.length ? 'OPEN' : 'NONE', counts: warningCounts, lines: warnings },
    source_sha256: sourceSha256, artifacts: { directory: dir, sha256: artifactSha256 },
  };
}

const modules = {
  W2: measure('w2', 'pcb_frame_updater', ['pcb_frame_updater.v', 'pcb_ram_2k16.v', 'pcb_dynamic_roms_v2.vh'], 3000),
  W1: measure('w1', 'pcb_particle_overlay', ['pcb_particle_overlay.v', 'pcb_span_ram.v', 'pcb_ram_2k16.v', 'pcb_dynamic_roms_v2.vh'], 1200),
};
const evidenceFiles = [
  'sim/sim_result_v2.json', 'sim/w1_result_v2.json', 'sim/mutation_result_v2.json',
  'sim/w2_compile_manifest_v2.json', 'sim/w1_compile_manifest_v2.json',
  'sim/vectors/v2/w2/manifest.json', 'sim/vectors/v2/w1/manifest.json',
  'sim/logs/v2/w2_lint.log', 'sim/logs/v2/w1_lint.log',
];
for (const file of ['sim/logs/v2/w2_lint.log', 'sim/logs/v2/w1_lint.log']) {
  expect(!/%(?:Warning|Error)/.test(read(file)), `lint 未通过：${file}`);
}
const report = {
  generated_utc: new Date().toISOString(), profile: 'no_particles_v2',
  measurement_status: 'COMPLETE',
  budget_status: Object.values(modules).every(result => result.gates.lut === 'PASS' && result.gates.dsp === 'PASS') ? 'PASS' : 'FAIL',
  scope: 'Separate W1/W2 optimize_gate area and synthesized STA; no placement, routing, board selection or integration',
  tool: 'Tang Dynasty V6.2.168116', modules,
  functional_evidence: {
    w2_default_and_protocol: w2Sim.status,
    w2_compared_frames: w2Sim.scenarios.reduce((n, s) => n + s.frames, 0),
    w2_model_noninterference_frames: w2Golden.noninterference_frames,
    w2_max_update_cycles: w2Sim.max_update_cycles,
    w1_pixel_comparison: w1Sim.pixel_comparison,
    w1_compared_pixels: w1Sim.scenarios.reduce((n, s) => n + s.pixels, 0),
    w1_delay_and_markers: w1Sim.fixed_delay_and_markers,
    w1_vblank_deadline: w1Sim.vblank_deadline,
    w1_max_build_cycles: Math.max(...w1Sim.scenarios.map(s => s.build_cycles)),
    w1_vblank_budget_cycles: 36000, mutation: mutation.status,
    configuration_boundary: 'NOT_RUN', overflow_injection: 'NOT_RUN',
    publication_during_active_frame: 'NOT_RUN', gate_primitive_simulation: 'NOT_RUN',
  },
  limitations: [
    'Both #lut budgets fail; W2 synthesized setup fails at 50MHz.',
    'W1 bar_alternating build exceeds 36000 blank cycles; pixel TB starts only after completed publication.',
    'W1 single active span pool has no proven atomic switch if activity starts during publication.',
    'Verilator uses behavioral RAM; TD uses EG_LOGIC_BRAM. No gate simulation verifies remaining byte-enable warnings.',
    'W1 auxiliary storage is 34 ERAM9K in addition to the 6 ERAM32K formal span pool.',
    'W2 standalone internal interface uses 1105 pads versus 188 device pads; this is a logic measurement top.',
    'No place/route, S2 integration, board selection, bitstream or board acceptance.',
  ],
  protected_sources: protectedSources,
  evidence_sha256: Object.fromEntries(evidenceFiles.map(file => [file, taskSha(file)])),
  archive_script_sha256: taskSha('sim/archive_v2_result.cjs'),
};
for (const result of Object.values(modules)) {
  fs.writeFileSync(path.join(task, result.artifacts.directory, 'source_manifest.json'), JSON.stringify({
    generated_utc: report.generated_utc, top: result.top,
    authoritative_source_sha256: result.source_sha256, artifact_sha256: result.artifacts.sha256,
  }, null, 2) + '\n');
}
fs.writeFileSync(path.join(task, 'sim/td_result_v2.json'), JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify({ measurement_status: report.measurement_status, budget_status: report.budget_status,
  measured: Object.fromEntries(Object.entries(modules).map(([name, result]) => [name, { ...result.measured, ...result.sta }])),
  protected_sources_unchanged: protectedSources.length }));
