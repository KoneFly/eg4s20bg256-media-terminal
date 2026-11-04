#!/usr/bin/env bash
set -euo pipefail
TASK_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)
PROFILE=${PROFILE:-quick}
SCEN_ONLY=${SCEN_ONLY:-}
case "$PROFILE" in quick|full) ;; *) echo "PROFILE 必须为 quick|full" >&2; exit 2;; esac
BUILD_DIR="/tmp/pcb_dynamic_layer_w2_build"
mkdir -p "$BUILD_DIR" "$TASK_DIR/sim/logs"
cp "$TASK_DIR/rtl/pcb_frame_updater.v" "$TASK_DIR/rtl/pcb_dynamic_roms.vh" "$TASK_DIR/tb/tb_w2.cpp" "$BUILD_DIR/"
cd "$BUILD_DIR"
verilator --lint-only --Wall -Wno-BLKSEQ --top-module pcb_frame_updater -I. pcb_frame_updater.v > "$TASK_DIR/sim/logs/w2_lint.log" 2>&1
verilator --cc --exe --build -j 4 --top-module pcb_frame_updater -I. pcb_frame_updater.v tb_w2.cpp -CFLAGS "-O2" > "$TASK_DIR/sim/logs/w2_compile.log" 2>&1
if [[ -n "$SCEN_ONLY" ]]; then cases=("$SCEN_ONLY");
elif [[ "$PROFILE" == full ]]; then cases=(boot_silence boot_low play_low play_mid play_high saturate impulse_broadcast silence_decay tick_overrun reset_reentry);
else cases=(boot_silence boot_low saturate); fi
for scenario in "${cases[@]}"; do
  vector="$scenario";mode=""
  case "$scenario" in tick_overrun) vector=boot_low;mode=overrun;; reset_reentry) vector=boot_low;mode=reset;; esac
  timeout 60s ./obj_dir/Vpcb_frame_updater "$TASK_DIR/sim/vectors/w2/$vector.bin" "$scenario" "$mode" | tee "$TASK_DIR/sim/logs/$scenario.log"
done
python3 "$TASK_DIR/sim/collect_results.py" "$BUILD_DIR" "${cases[@]}"
