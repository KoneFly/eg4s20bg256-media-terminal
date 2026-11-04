#!/usr/bin/env node
'use strict';

/*
 * W1 独立覆盖层黄金生成器。
 *
 * 输入是 W2 已打包的 P/T2 快照；本脚本独立完成 Bresenham、3×3 最大值、
 * 行扫描、调色和 RGB565 量化，不调用任何 RTL，不读取 DUT 波形。
 */
const fs = require('node:fs');
const path = require('node:path');
const {PROFILE_V2,PROFILE_V1}=require('./profiles.cjs');

const W = 640;
const H = 480;
const CX = 320;
const CY = 224;
const BAR_R0 = 193;
const BAR_MAX = 34;
const BAR_N = 128;
const PART_N = 128;
const PART_TRAIL = 8;
const D = 647;
const SPAN_POOL_DEPTH = 6144;

const ROOT = path.resolve(__dirname, '..', '..', '..');
const TABLES = JSON.parse(fs.readFileSync(path.join(ROOT, 'golden/pcb/obj_tables.json'), 'utf8'));

function parseArgs(argv) {
  const out = {
    stateRoot: path.resolve(__dirname, 'vectors/w2'),
    out: path.resolve(__dirname, 'vectors/w1'),
    frames: 1,
    scenario: null,
    ovK: null,
    profile:PROFILE_V2,
  };
  for (let i = 2; i < argv.length; i += 1) {
    if (argv[i] === '--state-root') out.stateRoot = path.resolve(argv[++i]);
    else if (argv[i] === '--out') out.out = path.resolve(argv[++i]);
    else if (argv[i] === '--frames') out.frames = Number(argv[++i]);
    else if (argv[i] === '--scenario') out.scenario = argv[++i];
    else if (argv[i] === '--ov-k') out.ovK = Number(argv[++i]);
    else if (argv[i] === '--profile') out.profile = argv[++i];
    else if (argv[i] === '--help') {
      console.log('用法：node gen_overlay_vectors.cjs --state-root DIR --scenario NAME [--frames N] [--out DIR]');
      process.exit(0);
    } else throw new Error(`未知参数：${argv[i]}`);
  }
  if (!Number.isInteger(out.frames) || out.frames <= 0) throw new Error('--frames 必须为正整数');
  if (!out.scenario) throw new Error('必须指定 --scenario');
  return out;
}

function readLines(file) {
  return fs.readFileSync(file, 'utf8').trim().split(/\r?\n/).filter(Boolean);
}

function parseMisc(file) {
  return readLines(file).map((line) => Number.parseInt(line, 16) >>> 0);
}

function parseParticles(file) {
  const words = readLines(file).map((line) => Number.parseInt(line, 16) & 0xFFFF);
  if (words.length % 12 !== 0) throw new Error('state_particles.hex 必须是每粒子 12 个 16bit 字');
  const records = [];
  for (let k = 0; k < words.length / 12; k += 1) {
    let record = 0n;
    for (let word = 0; word < 12; word += 1) {
      record |= BigInt(words[k * 12 + word]) << BigInt(word * 16);
    }
    records.push(record);
  }
  return records;
}

function signed(value, width) {
  const sign = 1 << (width - 1);
  const mask = (1 << width) - 1;
  const v = value & mask;
  return (v & sign) ? v - (1 << width) : v;
}

function decodePoint(record, history) {
  const point = Number((record >> BigInt(history * 21)) & 0x1FFFFFn);
  return {
    x: signed(point & 0x7FF, 11),
    y: signed((point >> 11) & 0x3FF, 10),
  };
}

function unpackSnapshot(frameDir,profile=PROFILE_V2) {
  const misc = parseMisc(path.join(frameDir, 'state_misc.hex'));
  const particles = profile===PROFILE_V1 ? parseParticles(path.join(frameDir, 'state_particles.hex')) : [];
  const bars = Array.from({ length: BAR_N }, (_, index) => {
    const word = misc[64 + (index >> 1)] || 0;
    const shift = (index & 1) ? 16 : 0;
    return {
      h: (word >> shift) & 0xFF,
      peak: (word >> (shift + 8)) & 0xFF,
    };
  });
  const parts = particles.map((record) => {
    const history = Array.from({ length: PART_TRAIL }, (_, h) => decodePoint(record, h));
    return {
      history,
      energy: Number((record >> 168n) & 0xFFn),
      life: Number((record >> 176n) & 0xFFn),
      active: Number((record >> 184n) & 1n) !== 0,
    };
  });
  const global = misc[137] || 0;
  return { profile,bars, parts, ovK: (global >> 8) & 0xFF };
}

function bresenham(x0, y0, x1, y1, visit) {
  let dx = Math.abs(x1 - x0);
  let dy = Math.abs(y1 - y0);
  const sx = x0 < x1 ? 1 : -1;
  const sy = y0 < y1 ? 1 : -1;
  let err = dx - dy;
  for (;;) {
    visit(x0, y0);
    if (x0 === x1 && y0 === y1) return;
    const twice = err * 2;
    if (twice > -dy) {
      err -= dy;
      x0 += sx;
    }
    if (twice < dx) {
      err += dx;
      y0 += sy;
    }
  }
}

function addPixel(plane, x, y, luma) {
  if (x < 0 || x >= W || y < 0 || y >= H) return;
  for (let yy = y - 1; yy <= y + 1; yy += 1) {
    if (yy < 0 || yy >= H) continue;
    for (let xx = x - 1; xx <= x + 1; xx += 1) {
      if (xx < 0 || xx >= W) continue;
      const index = yy * W + xx;
      if (luma > plane[index]) plane[index] = luma;
    }
  }
}

function barPoint(index, radius) {
  const bar = TABLES.bars[index];
  return [CX + ((radius * bar.ex) >> 8), CY + ((radius * bar.ey) >> 8)];
}

function rasterize(snapshot) {
  const plane = new Uint8Array(W * H);
  let previous = null;
  for (let index = 0; index < BAR_N; index += 1) {
    const bar = snapshot.bars[index];
    const height = (bar.h * BAR_MAX) >> 8;
    const current = barPoint(index, BAR_R0 + height);
    if (previous && (height > 0 || previous.height > 0)) {
      bresenham(previous.x, previous.y, current[0], current[1], (x, y) => addPixel(plane, x, y, 170));
    }
    previous = { x: current[0], y: current[1], height };
  }

  for (let particleIndex = 0; snapshot.profile===PROFILE_V1 && particleIndex < PART_N; particleIndex += 1) {
    const particle = snapshot.parts[particleIndex];
    if (!particle.active || particle.life === 0) continue;
    const a = (particle.energy * Math.min(255, particle.life * 6)) >> 8;
    for (let trail = PART_TRAIL - 1; trail > 0; trail -= 1) {
      const from = particle.history[trail];
      const to = particle.history[trail - 1];
      const luma = (a * (PART_TRAIL - trail) * 28) >> 8;
      bresenham(from.x, from.y, to.x, to.y, (x, y) => addPixel(plane, x, y, luma));
    }
    const head = particle.history[0];
    addPixel(plane, head.x, head.y, a);
    if (a > 150) {
      addPixel(plane, head.x + 1, head.y, a >> 1);
      addPixel(plane, head.x - 1, head.y, a >> 1);
      addPixel(plane, head.x, head.y + 1, a >> 1);
      addPixel(plane, head.x, head.y - 1, a >> 1);
    }
  }
  return plane;
}

function paletteRgb565(ridx, luma) {
  const level = luma & 0xF8;
  const color = TABLES.pal[Math.max(0, Math.min(63, ridx))];
  let r = (color.r * level) >> 8;
  let g = (color.g * level) >> 8;
  let b = (color.b * level) >> 8;
  const white = luma > 190 ? Math.min(255, (luma - 190) * 4) : 0;
  if (white) {
    r += ((255 - r) * white) >> 8;
    g += ((255 - g) * white) >> 8;
    b += ((255 - b) * white) >> 8;
  }
  return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
}

function writeFrame(frameDir, outDir, snapshot) {
  const plane = rasterize(snapshot);
  const valid = Buffer.alloc(W * H);
  valid.fill(1);
  const hit = Buffer.alloc(W * H);
  const alpha = Buffer.alloc(W * H);
  const rgb565 = Buffer.alloc(W * H * 2);
  const rowRuns = [];
  let hitPixels = 0;
  let spanCount = 0;
  for (let y = 0; y < H; y += 1) {
    let runStart = -1;
    let runLuma = 0;
    for (let x = 0; x <= W; x += 1) {
      const luma = x < W ? plane[y * W + x] : 0;
      if (luma) {
        const dx = x - CX;
        const dy = y - CY;
        const ridx = Math.min(63, Math.floor(Math.sqrt(dx * dx + dy * dy)) >> 2);
        const rgb = paletteRgb565(ridx, luma);
        const pixel = y * W + x;
        hit[pixel] = 1;
        alpha[pixel] = Math.min(255, (luma * snapshot.ovK) >> 8);
        rgb565.writeUInt16LE(rgb, pixel * 2);
        hitPixels += 1;
        if (runStart < 0) {
          runStart = x;
          runLuma = luma;
        } else if (luma !== runLuma || x - runStart === 64) {
          rowRuns.push({ y, x0: runStart, x1: x - 1, luma: runLuma });
          spanCount += 1;
          runStart = x;
          runLuma = luma;
        }
      } else if (runStart >= 0) {
        rowRuns.push({ y, x0: runStart, x1: x - 1, luma: runLuma });
        spanCount += 1;
        runStart = -1;
        runLuma = 0;
      }
    }
  }
  fs.mkdirSync(outDir, { recursive: true });
  const restored = new Uint8Array(W * H);
  const packed = Buffer.alloc(rowRuns.length * 3);
  rowRuns.forEach((span, index) => {
    const word = span.x0 | ((span.x1 - span.x0) << 10) | (span.luma << 16);
    packed.writeUIntLE(word, index * 3, 3);
    const decoded = packed.readUIntLE(index * 3, 3);
    const x0 = decoded & 1023, length = ((decoded >>> 10) & 63) + 1;
    restored.fill(decoded >>> 16, span.y * W + x0, span.y * W + x0 + length);
  });
  if (!Buffer.from(restored).equals(Buffer.from(plane))) throw new Error('紧凑行记录像素还原失配');
  fs.writeFileSync(path.join(outDir, 'overlay_valid.bin'), valid);
  fs.writeFileSync(path.join(outDir, 'overlay_hit.bin'), hit);
  fs.writeFileSync(path.join(outDir, 'overlay_luma.bin'), Buffer.from(plane));
  fs.writeFileSync(path.join(outDir, 'row_spans.bin'), packed);
  fs.writeFileSync(path.join(outDir, 'overlay_alpha.bin'), alpha);
  fs.writeFileSync(path.join(outDir, 'overlay_rgb565.bin'), rgb565);
  fs.writeFileSync(path.join(outDir, 'row_spans.json'), `${JSON.stringify(rowRuns)}\n`);
  fs.writeFileSync(path.join(outDir, 'meta.json'), `${JSON.stringify({ profile:snapshot.profile||PROFILE_V2, frame_dir: frameDir, pixels: W * H, hit_pixels: hitPixels, span_count: spanCount, span_pool_depth: SPAN_POOL_DEPTH, overflow: spanCount >= SPAN_POOL_DEPTH, fixed_delay: D, ov_k: snapshot.ovK }, null, 2)}\n`);
  return { hitPixels, spanCount };
}

function main() {
  const options = parseArgs(process.argv);
  const scenarioDir = path.join(options.stateRoot, options.scenario);
  if (!fs.existsSync(scenarioDir)) throw new Error(`找不到状态场景：${scenarioDir}`);
  const frames = fs.readdirSync(scenarioDir).filter((name) => /^frame_\d{4}$/.test(name)).sort().slice(0, options.frames);
  if (frames.length === 0) throw new Error(`场景没有 frame_NNNN 目录：${scenarioDir}`);
  const manifest = [];
  for (const frame of frames) {
    const frameDir = path.join(scenarioDir, frame);
    const snapshot = unpackSnapshot(frameDir,options.profile);
    if (options.ovK !== null) snapshot.ovK = Math.max(0, Math.min(255, options.ovK | 0));
    const result = writeFrame(frameDir, path.join(options.out, options.scenario, frame), snapshot);
    manifest.push({ frame, ...result });
  }
  const maxSpan = Math.max(...manifest.map((item) => item.spanCount));
  fs.mkdirSync(path.join(options.out, options.scenario), { recursive: true });
  fs.writeFileSync(path.join(options.out, options.scenario, 'manifest.json'), `${JSON.stringify({ profile:options.profile,fixed_delay: D, span_pool_depth: SPAN_POOL_DEPTH, span_count_max: maxSpan, frames: manifest }, null, 2)}\n`);
  if (maxSpan >= SPAN_POOL_DEPTH) process.exitCode = 2;
  console.log(`W1 覆盖层黄金已生成：${path.relative(process.cwd(), path.join(options.out, options.scenario))}，最大区段 ${maxSpan}`);
}

module.exports = { rasterize, paletteRgb565, writeFrame, unpackSnapshot, bresenham, TABLES };
if (require.main === module) main();

