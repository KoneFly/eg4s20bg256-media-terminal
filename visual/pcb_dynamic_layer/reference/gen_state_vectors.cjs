#!/usr/bin/env node
'use strict';

/*
 * W2 独立状态黄金生成器。
 *
 * 期望值来源是只读的 pcb_model.js；本脚本只负责刺激、帧推进和冻结状态
 * 表打包，不读取任何 RTL 输出。运行后可把生成目录直接交给 W2 TB。
 */
const fs = require('node:fs');
const path = require('node:path');
const model = require(path.resolve(__dirname, '../../../prototype/pcb_model.js'));
const {getModel,PROFILE_V2,PROFILE_V1}=require('./profiles.cjs');

const OUT_DEFAULT = path.resolve(__dirname, 'vectors/w2');
const PART_N = 128;
const TRACE_N = 128;
const MISC_N = 140;
const BOOT_FRAMES = 180;
const PLAY_FRAMES = 120;

function clamp8(value) {
  return Math.max(0, Math.min(255, value | 0));
}

function parseArgs(argv) {
  const out = { out: OUT_DEFAULT, scenario: 'all', boot: BOOT_FRAMES, play: PLAY_FRAMES, profile:PROFILE_V2 };
  for (let i = 2; i < argv.length; i += 1) {
    if (argv[i] === '--out') out.out = path.resolve(argv[++i]);
    else if (argv[i] === '--scenario') out.scenario = argv[++i];
    else if (argv[i] === '--boot') out.boot = Number(argv[++i]);
    else if (argv[i] === '--play') out.play = Number(argv[++i]);
    else if (argv[i] === '--profile') out.profile = argv[++i];
    else if (argv[i] === '--help') {
      console.log('用法：node gen_state_vectors.cjs [--scenario all|boot_silence|boot_low|play_low|play_mid|play_high|saturate] [--boot N] [--play N] [--out DIR]');
      process.exit(0);
    } else throw new Error(`未知参数：${argv[i]}`);
  }
  if (!Number.isInteger(out.boot) || out.boot < 0 || !Number.isInteger(out.play) || out.play < 0) {
    throw new Error('--boot/--play 必须是非负整数');
  }
  return out;
}

function putByteWord(bytes) {
  return ((bytes[0] & 255) | ((bytes[1] & 255) << 8) | ((bytes[2] & 255) << 16) | ((bytes[3] & 255) << 24)) >>> 0;
}

function hex32(value) {
  return (value >>> 0).toString(16).toUpperCase().padStart(8, '0');
}

function hex256(value) {
  return value.toString(16).toUpperCase().padStart(64, '0');
}

function signedBits(value, width) {
  const modulus = 1 << width;
  const mask = modulus - 1;
  const integer = value | 0;
  return (integer < 0 ? modulus + integer : integer) & mask;
}

function makeSpec(scenario, frame, phase) {
  const spec = new Uint8Array(128);
  if (scenario === 'impulse_broadcast') {
    if (phase === 'play' && frame % 16 === 0) spec.fill(255, 0, 32);
    return spec;
  }
  if (scenario === 'silence_decay') {
    if (phase === 'boot') spec.fill(255);
    return spec;
  }
  if (phase === 'boot' && scenario === 'boot_silence') return spec;
  if (scenario === 'saturate') {
    spec.fill(255);
    return spec;
  }
  if (scenario === 'boot_low' || scenario === 'play_low') {
    const pulse = frame % 30 < 4 ? 255 : 64;
    for (let k = 0; k < 32; k += 1) spec[k] = pulse - ((k * 3 + frame) & 15);
    return spec;
  }
  if (scenario === 'play_mid') {
    for (let k = 32; k < 96; k += 1) {
      const wave = (k * 11 + frame * 17) & 127;
      spec[k] = clamp8(48 + wave + (frame % 24 < 3 ? 72 : 0));
    }
    return spec;
  }
  if (scenario === 'play_high') {
    for (let k = 96; k < 128; k += 1) {
      const wave = (k * 19 + frame * 23) & 127;
      spec[k] = clamp8(64 + wave + (frame % 18 < 2 ? 96 : 0));
    }
    return spec;
  }
  if (scenario === 'mixed') {
    for (let k = 0; k < 128; k += 1) {
      const base = (k * 29 + frame * 13) & 127;
      spec[k] = clamp8(32 + base + (frame % 20 < 2 ? 96 : 0));
    }
    return spec;
  }
  return spec;
}

function packTrace(state) {
  const records = [];
  for (let i = 0; i < TRACE_N; i += 1) {
    const words = [0, 0, 0, 0];
    if (i < model.PCB_GEO.traces.length) {
      const slot = i * 3;
      words[0] = ((state.grow[i] & 0xFFFF)
        | ((state.flowE[i] & 0xFF) << 16)
        | ((state.flowPh[i] & 0xFF) << 24)) >>> 0;
      for (let j = 0; j < 3; j += 1) {
        const q = slot + j;
        words[j + 1] = ((state.pPos[q] & 0xFFFF)
          | ((state.pPeak[q] & 0xFF) << 16)
          | ((state.pAge[q] & 0xFF) << 24)) >>> 0;
      }
    }
    records.push(words.map(hex32).join(''));
  }
  return records;
}

function packMisc(state) {
  const words = new Array(MISC_N).fill(0);
  for (let n = 0; n < 64; n += 1) {
    const a = n * 2;
    words[n] = putByteWord([
      state.nodeVis[a] & 0xFF,
      state.nodeB[a] & 0xFF,
      state.nodeVis[a + 1] & 0xFF,
      state.nodeB[a + 1] & 0xFF,
    ]);
  }
  for (let c = 0; c < 64; c += 1) {
    const a = c * 2;
    words[64 + c] = putByteWord([
      state.barH[a] & 0xFF,
      state.barPeak[a] & 0xFF,
      state.barH[a + 1] & 0xFF,
      state.barPeak[a + 1] & 0xFF,
    ]);
  }
  for (let q = 0; q < 5; q += 1) {
    const bytes = [];
    for (let k = 0; k < 4; k += 1) bytes.push(state.compFade[q * 4 + k] || 0);
    words[128 + q] = putByteWord(bytes);
  }
  for (let j = 0; j < 4; j += 1) {
    words[133 + j] = ((state.rcAmp[j] & 0xFF)
      | ((state.rcDir[j] & 3) << 8)
      | ((state.rcPos[j] & 0x3FF) << 10)) >>> 0;
  }
  words[137] = putByteWord([
    state.coreQ === undefined ? 256 : state.coreQ,
    state.ovK & 0xFF,
    state.chipInk & 0xFF,
    state.beatK & 0xFF,
  ]);
  words[138] = putByteWord([state.bands[0], state.bands[1], state.bands[2], state.bands[3]]);
  words[139] = putByteWord([state.bands[4], state.bands[5], state.bands[6], state.bands[7]]);
  return words.map(hex32);
}

function packParticles(state) {
  const words = [];
  for (let k = 0; k < PART_N; k += 1) {
    let value = 0n;
    const offset = k * 8;
    for (let h = 0; h < 8; h += 1) {
      const x = signedBits(state.pHX[offset + h] || 0, 11);
      const y = signedBits(state.pHY[offset + h] || 0, 10);
      const point = BigInt(x | (y << 11));
      value |= point << BigInt(h * 21);
    }
    value |= BigInt(state.pE[k] & 0xFF) << 168n;
    value |= BigInt(state.pLife[k] & 0xFF) << 176n;
    value |= BigInt(state.pLife[k] ? 1 : 0) << 184n;
    for (let word = 0; word < 12; word += 1) {
      words.push(((value >> BigInt(word * 16)) & 0xFFFFn).toString(16).toUpperCase().padStart(4, '0'));
    }
  }
  return words;
}

function writeFrame(dir, state, spec, frame, phase,profile=PROFILE_V2) {
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'state_trace.hex'), `${packTrace(state).join('\n')}\n`);
  fs.writeFileSync(path.join(dir, 'state_misc.hex'), `${packMisc(state).join('\n')}\n`);
  if(profile===PROFILE_V1)fs.writeFileSync(path.join(dir, 'state_particles.hex'), `${packParticles(state).join('\n')}\n`);
  fs.writeFileSync(path.join(dir, 'spec_frame.bin'), Buffer.from(spec));
  fs.writeFileSync(path.join(dir, 'meta.json'), `${JSON.stringify({ profile,frame, phase, state_trace_lines: TRACE_N, state_misc_lines: MISC_N, state_particle_lines: profile===PROFILE_V1 ? PART_N * 12 : 0 }, null, 2)}\n`);
}

function scenariosFor(requested) {
  if (requested === 'all') return ['boot_silence', 'boot_low', 'play_low', 'play_mid', 'play_high', 'saturate', 'impulse_broadcast', 'silence_decay'];
  return [requested];
}

function main() {
  const options = parseArgs(process.argv);
  const activeModel=getModel(options.profile);
  fs.mkdirSync(options.out, { recursive: true });
  const manifest = [];
  for (const scenario of scenariosFor(options.scenario)) {
    const scenarioDir = path.join(options.out, scenario);
    const state = activeModel.pcbInitState();
    state.coreQ = 256;
    state.ovK = 255;
    activeModel.pcbSetOverlay(state, 1);
    let frame = 0;
    const total = options.boot + options.play;
    for (let n = 0; n < total; n += 1) {
      const phase = n < options.boot ? 'boot' : 'play';
      const spec = makeSpec(scenario, phase === 'boot' ? n : n - options.boot, phase);
      activeModel.pcbStep(state, spec);
      writeFrame(path.join(scenarioDir, `frame_${String(frame).padStart(4, '0')}`), state, spec, frame, phase,options.profile);
      frame += 1;
    }
    manifest.push({ scenario, frames: total, boot_frames: options.boot, play_frames: options.play });
  }
  fs.writeFileSync(path.join(options.out, 'manifest.json'), `${JSON.stringify({ profile:options.profile, generated: new Date().toISOString(), manifest }, null, 2)}\n`);
  console.log(`W2 状态黄金已生成：${path.relative(process.cwd(), options.out)}`);
}

module.exports = { makeSpec, packTrace, packMisc, packParticles, writeFrame, model };
if (require.main === module) main();


