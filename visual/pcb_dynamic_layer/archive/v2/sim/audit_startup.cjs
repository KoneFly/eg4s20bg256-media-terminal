#!/usr/bin/env node
'use strict';

/* 开工契约自检：只读加载签发黄金，不调用 DUT，不执行 HDL 仿真。 */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const { createRequire } = require('node:module');
const assert = require('node:assert/strict');

const taskRoot = path.resolve(__dirname, '..');
const visualRoot = path.resolve(taskRoot, '..', '..');
const projectRoot = path.dirname(visualRoot);
const outputRoot = path.join(__dirname, 'startup_audit_rev1');
const model = require(path.join(visualRoot, 'prototype/pcb_model.js'));
const sourceFiles = [
  'prototype/pcb_model.js', 'prototype/pcb_layout.js', 'prototype/pcb_labels.js',
  'spec/M6_PCB_SKETCH.md', 'spec/M6_PCB_PORTING_PLAN.md', 'golden/pcb/obj_tables.json',
].map((relative) => path.join(visualRoot, relative));
sourceFiles.push(
  path.join(projectRoot, 'iccoder_workspace/TASK_KICKOFF.md'),
  path.join(projectRoot, 'iccoder_workspace/tasks/task_045_pcb_pixel_renderer/reference/gen_vectors.cjs'),
  path.join(projectRoot, 'iccoder_workspace/tasks/task_045_pcb_pixel_renderer/rtl/pcb_pixel_renderer.v'),
  path.join(projectRoot, 'iccoder_workspace/tasks/task_045_pcb_pixel_renderer/doc/output/behavior_spec.md'),
  path.join(taskRoot, 'doc/brief/START_PROMPT.md'),
  path.join(taskRoot, 'doc/brief/INTERFACE_SPEC.md'),
  path.join(taskRoot, 'doc/brief/VERIFICATION_CONTRACT.md'),
  path.join(taskRoot, 'reference/UPSTREAM_FACTS.md'),
  path.join(taskRoot, 'reference/gen_state_vectors.cjs'),
  path.join(taskRoot, 'reference/gen_overlay_vectors.cjs'),
);
const sha256 = (file) => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex').toUpperCase();
const sources = sourceFiles.map((file) => ({ file: path.relative(projectRoot, file).replaceAll('\\', '/'), sha256: sha256(file) }));

function loadGoldenFunctions(relative, names) {
  const file = path.join(taskRoot, relative);
  const functions = require(file);
  names.forEach((name) => assert.equal(typeof functions[name], 'function'));
  return functions;
}

const w2 = loadGoldenFunctions('reference/gen_state_vectors.cjs', ['makeSpec', 'packTrace', 'packMisc', 'packParticles']);
const w1 = loadGoldenFunctions('reference/gen_overlay_vectors.cjs', ['rasterize', 'paletteRgb565', 'writeFrame', 'unpackSnapshot']);
const s2File = path.join(projectRoot, 'iccoder_workspace/tasks/task_045_pcb_pixel_renderer/reference/gen_vectors.cjs');
const s2Source = fs.readFileSync(s2File, 'utf8');
const packStart = s2Source.indexOf('function packState(st){');
const packEnd = s2Source.indexOf('/* ---------- 输入图像', packStart);
assert(packStart >= 0 && packEnd > packStart);
const s2Pack = vm.runInNewContext(s2Source.slice(packStart, packEnd) + '\npackState;', { G: model.PCB_GEO });
const hex32 = (value) => (value >>> 0).toString(16).toUpperCase().padStart(8, '0');

function unpackP(words, slot) {
  let record = 0n;
  for (let word = 0; word < 12; word += 1) {
    record |= BigInt(`0x${words[slot * 12 + word]}`) << BigInt(word * 16);
  }
  const signed = (value, width) => value >= 2 ** (width - 1) ? value - 2 ** width : value;
  const history = Array.from({ length: 8 }, (_, index) => {
    const bits = Number((record >> BigInt(index * 21)) & ((1n << 21n) - 1n));
    return { x: signed(bits & 2047, 11), y: signed(bits >>> 11, 10) };
  });
  return {
    history, energy: Number((record >> 168n) & 255n),
    life: Number((record >> 176n) & 255n), active: Number((record >> 184n) & 1n),
    reserved: Number(record >> 185n),
  };
}

function snapshot(state) {
  const words = w2.packParticles(state);
  return {
    bars: Array.from({ length: 128 }, (_, i) => ({ h: state.barH[i], peak: state.barPeak[i] })),
    parts: Array.from({ length: 128 }, (_, i) => unpackP(words, i)), ovK: state.ovK,
  };
}

function spanCounts(plane) {
  let connected = 0;
  let equalLuma = 0;
  let overlapMax = 0;
  let compact24 = 0;
  for (let y = 0; y < 480; y += 1) {
    let previous = 0;
    let runLength = 0;
    const levels = [];
    for (let x = 0; x <= 640; x += 1) {
      const value = x < 640 ? plane[y * 640 + x] : 0;
      if (value && !previous) connected += 1;
      if (value && value !== previous) equalLuma += 1;
      if (value && (value !== previous || runLength === 64)) {
        compact24 += 1;
        runLength = 0;
      }
      runLength = value ? runLength + 1 : 0;
      while (levels.length && levels.at(-1) > value) {
        levels.pop();
        overlapMax += 1;
      }
      if (value && (!levels.length || levels.at(-1) < value)) levels.push(value);
      previous = value;
    }
  }
  return { connected, equal_luma: equalLuma, overlap_max: overlapMax, compact_24: compact24 };
}

function checkCompactSpans(plane) {
  const words = [];
  const rows = [];
  const restored = new Uint8Array(640 * 480);
  for (let y = 0; y < 480; y += 1) {
    const base = words.length;
    for (let x = 0; x < 640;) {
      const luma = plane[y * 640 + x];
      if (!luma) { x += 1; continue; }
      const x0 = x;
      while (x < 640 && x - x0 < 64 && plane[y * 640 + x] === luma) x += 1;
      words.push(x0 | ((x - x0 - 1) << 10) | (luma << 16));
    }
    rows.push({ base, count: words.length - base });
    for (let index = base; index < words.length; index += 1) {
      const word = words[index];
      const x0 = word & 1023;
      const length = ((word >>> 10) & 63) + 1;
      const luma = word >>> 16;
      for (let dx = 0; dx < length; dx += 1) restored[y * 640 + x0 + dx] = luma;
    }
  }
  for (let pixel = 0; pixel < plane.length; pixel += 1) assert.equal(restored[pixel], plane[pixel]);
  assert.equal(words.length, spanCounts(plane).compact_24);
  return { words, rows };
}

// 候选容量方案：重叠区段取 max；仅用于审计，不作为未经签发的新黄金。
function maxSpans(plane) {
  const result = [];
  for (let y = 0; y < 480; y += 1) {
    const stack = [];
    for (let x = 0; x <= 640; x += 1) {
      const luma = x < 640 ? plane[y * 640 + x] : 0;
      let x0 = x;
      while (stack.length && stack.at(-1).luma > luma) {
        const entry = stack.pop();
        result.push({ y, x0: entry.x0, x1: x - 1, luma: entry.luma });
        x0 = entry.x0;
      }
      if (luma && (!stack.length || stack.at(-1).luma < luma)) stack.push({ x0, luma });
    }
  }
  return result;
}

function checkMaxSpans(plane) {
  const spans = maxSpans(plane);
  const restored = new Uint8Array(640 * 480);
  for (const span of spans) {
    for (let x = span.x0; x <= span.x1; x += 1) {
      const pixel = span.y * 640 + x;
      restored[pixel] = Math.max(restored[pixel], span.luma);
    }
  }
  for (let pixel = 0; pixel < plane.length; pixel += 1) assert.equal(restored[pixel], plane[pixel]);
  assert.equal(spans.length, spanCounts(plane).overlap_max);
  return spans;
}

function checkPackedState(state) {
  const packed = s2Pack(state);
  const expectedTrace = packed.t1.map((record) => record.map(hex32).join(''));
  const actualTrace = w2.packTrace(state);
  for (let index = 0; index < 128; index += 1) assert.equal(actualTrace[index], expectedTrace[index]);
  const actualMisc = w2.packMisc(state);
  for (let index = 0; index < 140; index += 1) assert.equal(actualMisc[index], hex32(packed.m[index]));
  const particles = w2.packParticles(state);
  assert.equal(particles.length, 1536);
  for (let slot = 0; slot < 128; slot += 1) {
    const decoded = unpackP(particles, slot);
    assert.equal(decoded.energy, state.pE[slot]);
    assert.equal(decoded.life, state.pLife[slot]);
    assert.equal(decoded.active, state.pLife[slot] ? 1 : 0);
    assert.equal(decoded.reserved, 0);
    for (let h = 0; h < 8; h += 1) {
      assert.equal(decoded.history[h].x, state.pHX[slot * 8 + h]);
      assert.equal(decoded.history[h].y, state.pHY[slot * 8 + h]);
    }
  }
}

function makeParticle(history, energy = 240) {
  const state = model.pcbInitState();
  state.coreQ = 256;
  state.pLife[0] = 110;
  state.pE[0] = energy;
  history.forEach((point, h) => { state.pHX[h] = point.x; state.pHY[h] = point.y; });
  return state;
}

function writeFixture(name, state) {
  const input = path.join(outputRoot, name, 'input');
  fs.mkdirSync(input, { recursive: true });
  fs.writeFileSync(path.join(input, 'state_trace.hex'), w2.packTrace(state).join('\n') + '\n');
  fs.writeFileSync(path.join(input, 'state_misc.hex'), w2.packMisc(state).join('\n') + '\n');
  fs.writeFileSync(path.join(input, 'state_particles.hex'), w2.packParticles(state).join('\n') + '\n');
  w1.writeFrame(input, path.join(outputRoot, name, 'golden'), w1.unpackSnapshot(input));
  return { input, golden: path.join(outputRoot, name, 'golden') };
}

function main() {
  const facts = fs.readFileSync(path.join(taskRoot, 'reference/UPSTREAM_FACTS.md'), 'utf8');
  const frozen = [...facts.matchAll(/\| `([^`]+)` \|[^\n]+\| `([A-F\d]{64})` \|/g)];
  assert.equal(frozen.length, 5, '预期五个已登记的冻结 SHA256');
  for (const entry of frozen) assert.equal(sha256(path.join(visualRoot, entry[1])), entry[2]);
  fs.mkdirSync(outputRoot, { recursive: true });
  const findings = [];
  const traceFixture = makeParticle(Array.from({ length: 8 }, (_, h) => ({ x: 110 - h * 3, y: 100 })));
  const tracePaths = writeFixture('nonuniform_luma', traceFixture);
  const tracePlane = w1.rasterize(snapshot(traceFixture));
  const candidateSpans = checkMaxSpans(tracePlane);
  fs.writeFileSync(path.join(outputRoot, 'nonuniform_luma/candidate_max_spans.json'), JSON.stringify(candidateSpans, null, 2) + '\n');
  const compactFixture = checkCompactSpans(tracePlane);
  fs.writeFileSync(path.join(outputRoot, 'nonuniform_luma/candidate_compact_spans.json'), JSON.stringify(compactFixture, null, 2) + '\n');
  const spans = JSON.parse(fs.readFileSync(path.join(tracePaths.golden, 'row_spans.json'), 'utf8'));
  const goldenAlpha = fs.readFileSync(path.join(tracePaths.golden, 'overlay_alpha.bin'));
  let changedPixels = 0;
  let firstDifference = null;
  for (const span of spans) {
    for (let x = span.x0; x <= span.x1; x += 1) {
      const pixel = span.y * 640 + x;
      const alpha = (span.luma * traceFixture.ovK) >> 8;
      if (alpha !== goldenAlpha[pixel]) {
        changedPixels += 1;
        firstDifference ||= { x, y: span.y, pixel_luma: tracePlane[pixel], span_luma: span.luma, golden_alpha: goldenAlpha[pixel], span_alpha: alpha };
      }
    }
  }
  assert.equal(changedPixels, 0, '行记录应逐像素还原黄金 alpha');
  findings.push({ id: 'span_luma_conflict', status: 'FIXED', changed_pixels: changedPixels, first_difference: firstDifference, span_counts: spanCounts(tracePlane), fixture: 'nonuniform_luma' });

  const clippedFixture = makeParticle(Array.from({ length: 8 }, () => ({ x: -1, y: 20 })), 100);
  writeFixture('outside_before_dilation', clippedFixture);
  const clippedPlane = w1.rasterize(snapshot(clippedFixture));
  const labels = new Uint16Array(640 * 480);
  const rendered = model.pcbRender(clippedFixture, 0, { label: labels, gain: 255 });
  const point = 20 * 640;
  const currentRgb = w1.paletteRgb565(63, clippedPlane[point]);
  assert.equal(rendered[point], 0);
  assert.equal(currentRgb, rendered[point]);
  findings.push({ id: 'clip_order_conflict', status: 'FIXED', x: 0, y: 20, model_rgb565: rendered[point], golden_rgb565: currentRgb, golden_luma: clippedPlane[point], fixture: 'outside_before_dilation' });

  const packingBoundary = model.pcbInitState();
  packingBoundary.coreQ = 256;
  packingBoundary.ovK = 0;
  const s2Global = hex32(s2Pack(packingBoundary).m[137]);
  const w2Global = w2.packMisc(packingBoundary)[137];
  assert.equal(w2Global, s2Global);
  findings.push({ id: 'core_byte_spill', status: 'FIXED', misc_address: 137, core_q8: 256, ov_k: 0, expected: s2Global, actual: w2Global });

  const emptyFixture = model.pcbInitState();
  writeFixture('all_empty', emptyFixture);
  const emptyMask = fs.readFileSync(path.join(outputRoot, 'all_empty/golden/overlay_valid.bin'));
  assert.equal(emptyMask.length, 640 * 480);
  assert(emptyMask.every((value) => value === 1));
  assert(fs.readFileSync(path.join(outputRoot, 'all_empty/golden/overlay_hit.bin')).every((value) => value === 0));
  findings.push({ id: 'valid_file_is_hit_mask', status: 'FIXED', full_frame_valid_pixels: 640 * 480, golden_valid_file_ones: emptyMask.length, fixture: 'all_empty' });

  const edgeState = makeParticle(Array.from({ length: 8 }, (_, h) => ({ x: h & 1 ? 1023 : -1024, y: h & 2 ? 511 : -512 })));
  checkPackedState(edgeState);

  const scenarios = ['boot_silence', 'boot_low', 'play_low', 'play_mid', 'play_high', 'saturate'];
  const capacity = [];
  let framesChecked = 0;
  for (const scenario of scenarios) {
    const state = model.pcbInitState();
    state.coreQ = 256;
    state.ovK = 255;
    let connectedMax = { count: 0, frame: 0 };
    let equalMax = { count: 0, frame: 0 };
    let overlapMax = { count: 0, frame: 0 };
    let compactMax = { count: 0, frame: 0 };
    let firstExactOverflow = null;
    for (let frame = 0; frame < 300; frame += 1) {
      const phase = frame < 180 ? 'boot' : 'play';
      model.pcbStep(state, w2.makeSpec(scenario, frame < 180 ? frame : frame - 180, phase));
      checkPackedState(state);
      framesChecked += 1;
      const plane = w1.rasterize(snapshot(state));
      const counts = spanCounts(plane);
      if (scenario === 'saturate' && frame < 16) {
        checkMaxSpans(plane);
        checkCompactSpans(plane);
      }
      if (counts.connected > connectedMax.count) connectedMax = { count: counts.connected, frame };
      if (counts.equal_luma > equalMax.count) equalMax = { count: counts.equal_luma, frame };
      if (counts.overlap_max > overlapMax.count) overlapMax = { count: counts.overlap_max, frame };
      if (counts.compact_24 > compactMax.count) compactMax = { count: counts.compact_24, frame };
      if (counts.equal_luma >= 4096 && firstExactOverflow === null) firstExactOverflow = { frame, counts };
    }
    const result = { scenario, frames: 300, connected_max: connectedMax, equal_luma_max: equalMax, candidate_overlap_max: overlapMax, candidate_compact_24_max: compactMax, first_exact_overflow: firstExactOverflow };
    capacity.push(result);
    console.log(JSON.stringify(result));
  }

  const storageMax = Math.max(...capacity.map((item) => item.candidate_compact_24_max.count));
  assert(storageMax < 6144);
  findings.push({ id: 'span_capacity_requires_decision', status: 'FIXED', connected_span_count_max: Math.max(...capacity.map((item) => item.connected_max.count)), equal_luma_span_count_max: Math.max(...capacity.map((item) => item.equal_luma_max.count)), pool_depth: 6144 });
  const protectedHashesUnchanged = sources.every((item) => sha256(path.join(projectRoot, item.file)) === item.sha256);
  assert(protectedHashesUnchanged, '上游/签发黄金不得发生修改');
  const result = {
    checked_date: '2026-10-04', status: 'PASS', purpose: '修订后契约与独立黄金审计；不是 RTL 仿真或板级验收',
    audit_script_sha256: sha256(__filename), sources, frozen_sha_checks: frozen.length, protected_hashes_unchanged: protectedHashesUnchanged,
    packing_default: { status: 'PASS', frames: framesChecked, scenarios: scenarios.length, t1_words_per_frame: 512, t2_words_per_frame: 140, p_words_per_frame: 1536, rtl_write_protocol_tested: false },
    signed_p_boundaries: { status: 'PASS', x: [-1024, 1023], y: [-512, 511], reserved_bits_zero: true },
    candidate_compact_24_spans: { status: 'MODEL_ONLY', span_count_max: Math.max(...capacity.map((item) => item.candidate_compact_24_max.count)), proposed_pool_depth: 6144, proposed_record_bits: 24, pool_logical_bits: 6144 * 24, row_directory_logical_bits: 480 * 23, pixel_roundtrip_frames: 17, contract_approval_required: true, td_resources_measured: false },
    findings, capacity,
  };
  fs.writeFileSync(path.join(outputRoot, 'audit_result.json'), JSON.stringify(result, null, 2) + '\n');
  console.log(JSON.stringify({ status: result.status, frames_checked: framesChecked, findings, protected_hashes_unchanged: protectedHashesUnchanged }, null, 2));
  process.exitCode = 0;
}

main();
