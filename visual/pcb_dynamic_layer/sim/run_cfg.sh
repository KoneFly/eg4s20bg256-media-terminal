#!/usr/bin/env bash
set -euo pipefail
TASK_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="/tmp/pcb_dynamic_layer_w2_cfg_mc_build"
mkdir -p "$BUILD_DIR" "$TASK_DIR/sim/logs/w2_mc"
cp "$TASK_DIR/rtl/pcb_frame_updater.v" "$TASK_DIR/rtl/pcb_dynamic_roms_w2.vh" "$TASK_DIR/rtl/pcb_ram_2k16.v" "$TASK_DIR/tb/tb_w2.cpp" "$BUILD_DIR/"
cd "$BUILD_DIR"
python3 "$TASK_DIR/sim/stamp_build.py" "$BUILD_DIR" "$TASK_DIR/sim/w2_cfg_compile_manifest_mc.json"
verilator --cc --exe --build -j 4 --top-module pcb_frame_updater -I. pcb_frame_updater.v tb_w2.cpp -CFLAGS "-O2" > "$TASK_DIR/sim/logs/w2_mc/cfg_compile.log" 2>&1
names=(cfg_min cfg_max cfg_clamp_low cfg_clamp_high cfg_same_tick cfg_during_busy cfg_retired_ignored)
modes=(cfg cfg cfg cfg cfg_tick cfg_busy cfg_retired)
: > "$TASK_DIR/sim/logs/w2_mc/cfg.log"
for n in "${!names[@]}"; do
  scenario="${names[$n]}"
  timeout 60s ./obj_dir/Vpcb_frame_updater "$TASK_DIR/sim/vectors/cfg_mc/$scenario.bin" "$scenario" "${modes[$n]}" "$TASK_DIR/sim/vectors/cfg_mc/$scenario.cfg.bin" | tee -a "$TASK_DIR/sim/logs/w2_mc/cfg.log"
done
python3 - "$TASK_DIR" <<'PY'
import datetime,hashlib,json,pathlib,sys
task=pathlib.Path(sys.argv[1]);sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
compiled=json.loads((task/'sim/w2_cfg_compile_manifest_mc.json').read_text())['sources']
for name in ('pcb_frame_updater.v','pcb_ram_2k16.v','pcb_dynamic_roms_w2.vh','tb_w2.cpp'):
    if compiled[name]!=sha(task/('tb' if name.endswith('.cpp') else 'rtl')/name):raise RuntimeError('配置测试源码变化')
golden=json.loads((task/'sim/vectors/cfg_mc/manifest.json').read_text())
results=[json.loads(line) for line in (task/'sim/logs/w2_mc/cfg.log').read_text().splitlines()]
if [r['scenario'] for r in results]!=[g['scenario'] for g in golden['cases']]:raise RuntimeError('配置测试集合不完整')
for result,entry in zip(results,golden['cases']):
    if result['status']!='PASS' or result['frames']!=entry['frames']:raise RuntimeError('配置测试失败')
    for suffix,key in (('.bin','vector_sha256'),('.cfg.bin','config_sha256')):
        if sha(task/'sim/vectors/cfg_mc'/(entry['scenario']+suffix))!=entry[key]:raise RuntimeError('配置黄金变化')
report={'generated_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'status':'PASS','profile':'no_particles_v2','scope':'Seven combined configuration stimuli; not the complete per-parameter boundary matrix','source_sha256':compiled,'golden_manifest':golden,'scenarios':results,'max_update_cycles':max(r['max_update_cycles'] for r in results)}
(task/'sim/cfg_result_mc.json').write_text(json.dumps(report,indent=2)+'\n')
PY
