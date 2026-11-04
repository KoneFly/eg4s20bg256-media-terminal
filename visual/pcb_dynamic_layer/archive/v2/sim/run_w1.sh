#!/usr/bin/env bash
set -euo pipefail
TASK_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="/tmp/pcb_dynamic_layer_w1_v2_build"
mkdir -p "$BUILD_DIR" "$TASK_DIR/sim/logs/v2"
cp "$TASK_DIR/rtl/pcb_particle_overlay.v" "$TASK_DIR/rtl/pcb_dynamic_roms_v2.vh" "$TASK_DIR/tb/tb_w1.cpp" "$TASK_DIR/rtl/pcb_ram_2k16.v" "$TASK_DIR/rtl/pcb_span_ram.v" "$BUILD_DIR/"
cd "$BUILD_DIR"
python3 "$TASK_DIR/sim/stamp_build.py" "$BUILD_DIR" "$TASK_DIR/sim/w1_compile_manifest_v2.json"
verilator --lint-only --Wall -Wno-BLKSEQ --top-module pcb_particle_overlay -I. pcb_particle_overlay.v pcb_span_ram.v pcb_ram_2k16.v > "$TASK_DIR/sim/logs/v2/w1_lint.log" 2>&1
verilator --cc --exe --build -j 4 --top-module pcb_particle_overlay -I. pcb_particle_overlay.v tb_w1.cpp -CFLAGS "-O2" > "$TASK_DIR/sim/logs/v2/w1_compile.log" 2>&1
if [[ -n "${SCEN_ONLY:-}" ]]; then cases=("$SCEN_ONLY");else cases=(all_empty bar_step bar_triangle bar_saturate bar_alternating bar_random alpha_zero alpha_partial);fi
timeout 60s ./obj_dir/Vpcb_particle_overlay "$TASK_DIR/sim/vectors/v2/w1" "${cases[@]}" | tee "$TASK_DIR/sim/logs/v2/w1.log"
python3 "$TASK_DIR/sim/collect_w1_results.py" "$BUILD_DIR"
