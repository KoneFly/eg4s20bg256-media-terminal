// 只读核查上游资产；报告仅写入本任务目录。
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const task = path.resolve(__dirname, '..');
const visual = path.resolve(task, '../..');
const project = path.resolve(visual, '..');
const baseline = path.join(project, 'iccoder_workspace/tasks/task_052_ethernet_pcm_link/td_run/v9_display_20261004_final2');
const w2 = path.join(visual, 'rtl_handoff/pcb_dynamic_layer');
const sha = b => crypto.createHash('sha256').update(b).digest('hex');
const read = f => fs.readFileSync(f);
const txt = f => read(f).toString('utf8');
const files = [];
const faults = [];
function artifact(file) {
  const data = read(file);
  const item = {path: file.replace(/\\/g, '/'), bytes: data.length, sha256: sha(data)};
  files.push(item);
  return data;
}
function check(condition, message) { if (!condition) faults.push(message); }
function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) {
    crc ^= byte;
    for (let b = 0; b < 8; b++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  }
  return ((~crc) >>> 0).toString(16).toUpperCase().padStart(8, '0');
}
let sourceCount = 0;
for (const line of txt(path.join(baseline, 'SOURCE.sha256')).split(/\r?\n/)) {
  const match = line.match(/^([0-9a-f]{64})\s+(.+)$/i);
  if (!match) continue;
  const file = path.join(baseline, 'src', match[2].replace(/\\/g, '/'));
  sourceCount++;
  check(sha(artifact(file)) === match[1].toLowerCase(), `基座源码 SHA 不一致：${match[2]}`);
}
const bit = artifact(path.join(baseline, 'eth_udp_m6_master_top.bit'));
const bitSha = sha(bit);
check(bitSha === '75959e68b425de7a36ee937949c683b956d90164ea72c68e2bbcd40b6d5d5d1b', '基座位文件 SHA 不一致');
const w2Result = JSON.parse(txt(path.join(w2, 'sim/td_result_mc.json')));
for (const file of ['pcb_frame_updater.v', 'pcb_ram_2k16.v', 'pcb_dynamic_roms_w2.vh']) {
  check(sha(artifact(path.join(w2, 'rtl', file))) === w2Result.source_sha256[file], `W2 源码 SHA 不一致：${file}`);
}
const bmp = artifact(path.join(visual, 'golden/pcb/PCB.BMP'));
const header = {signature: bmp.toString('ascii', 0, 2), declared_bytes: bmp.readUInt32LE(2), pixel_offset: bmp.readUInt32LE(10), dib_bytes: bmp.readUInt32LE(14), width: bmp.readInt32LE(18), height: bmp.readInt32LE(22), planes: bmp.readUInt16LE(26), bits_per_pixel: bmp.readUInt16LE(28), compression: bmp.readUInt32LE(30)};
check(header.signature === 'BM' && header.width === 640 && header.height === 480 && header.planes === 1 && header.bits_per_pixel === 24 && header.compression === 0, '标签 BMP 格式不是冻结的 640x480 底向上 24bit BI_RGB');
check(header.declared_bytes === bmp.length && bmp.length === 921654, '标签 BMP 长度不一致');
const spans = artifact(path.join(visual, 'golden/pcb/rom/rom_row_span.hex')).toString('utf8').trim().split(/\r?\n/).map(s => parseInt(s, 16) >>> 0);
check(spans.length === 480, '行区段表不是 480 项');
const labels = Buffer.alloc(640 * 480 * 2);
let spanSum = 0, activeSum = 0, minWidth = 640, maxWidth = 0, alignedWords = 0, maxAlignedWords = 0;
for (let y = 0; y < 480; y++) {
  let first = -1, last = -1;
  for (let x = 0; x < 640; x++) {
    const pos = header.pixel_offset + (479 - y) * 1920 + x * 3;
    const value = ((bmp[pos + 2] >>> 3) << 11) | ((bmp[pos + 1] >>> 2) << 5) | (bmp[pos] >>> 3);
    labels.writeUInt16LE(value, (y * 640 + x) * 2);
    if (value) { if (first < 0) first = x; last = x; }
  }
  const width = first < 0 ? 0 : last - first + 1;
  const packed = spans[y];
  check((packed >>> 22) === Math.max(0, first) && ((packed >>> 12) & 1023) === Math.max(0, last) && (packed & 1023) === width && (packed & 0xc00) === 0, `行区段与标签不一致：y=${y}`);
  spanSum += width; minWidth = Math.min(minWidth, width); maxWidth = Math.max(maxWidth, width);
  if (y < 451 && width) {
    activeSum += width;
    const words = ((last >>> 1) | 7) - ((first >>> 1) & ~7) + 1;
    alignedWords += words; maxAlignedWords = Math.max(maxAlignedWords, words);
  }
}
const adcPath = path.join(baseline, 'src/constraints/eth_m6_master.adc');
const pins = [...txt(adcPath).matchAll(/^set_pin_assignment\s+\{([^}]+)\}\s+\{[^\r\n]*LOCATION\s*=\s*(\w+)/gm)].map(m => ({signal: m[1], pin: m[2]}));
const tf = [{signal:'sd_dclk',pin:'A14'}, {signal:'sd_miso',pin:'B14'}, {signal:'sd_mosi',pin:'A13'}, {signal:'sd_ncs',pin:'A12'}];
const implicitNegativePins = ['C2', 'G6', 'F2', 'D1'];
const occupied = new Set([...pins.map(p => p.pin), ...implicitNegativePins]);
check(new Set(pins.map(p => p.pin)).size === pins.length, '基座显式引脚重复');
check(tf.every(p => !occupied.has(p.pin)), '新增 TF 引脚冲突');
const physicalLabels = Buffer.alloc(labels.length);
for (let y = 0; y < 480; y++) labels.copy(physicalLabels, (479 - y) * 1280, y * 1280, (y + 1) * 1280);
const report = {
  generated_utc: new Date().toISOString(), status: faults.length ? 'FAIL' : 'PASS_READ_ONLY',
  scope: '只读资产核对；不代表集成 TD、时序、预算或上板通过',
  baseline: {directory: baseline.replace(/\\/g, '/'), bit_sha256: bitSha, source_manifest_entries: sourceCount},
  bitmap: {...header, actual_bytes: bmp.length, file_crc32: crc32(bmp), decoded_bytes: labels.length, top_down_labels_le_crc32: crc32(labels), physical_bottom_up_labels_le_crc32: crc32(physicalLabels)},
  row_span: {rows: spans.length, min_width: minWidth, max_width: maxWidth, total_span_pixels: spanSum, mean_width: spanSum / 480, y_below_451_span_pixels: activeSum, y_below_451_bl8_aligned_words: alignedWords, max_bl8_aligned_words_per_row: maxAlignedWords},
  pins: {baseline_explicit: pins.length, baseline_implicit_hdmi_negative: implicitNegativePins, proposed_tf: tf, overlaps: tf.filter(p => occupied.has(p.pin))},
  faults, artifacts: files
};
const prefix=process.argv[2]??'';
if(!['','ROUND2_'].includes(prefix))throw Error('Unsupported evidence prefix');
const out = path.join(task, `doc/output/${prefix}PREFLIGHT.json`);
fs.mkdirSync(path.dirname(out), {recursive: true});
fs.writeFileSync(out, JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify({status: report.status, sources: sourceCount, bitmap: report.bitmap, row_span: report.row_span, pins: report.pins, faults}, null, 2));
if (faults.length) process.exitCode = 1;
