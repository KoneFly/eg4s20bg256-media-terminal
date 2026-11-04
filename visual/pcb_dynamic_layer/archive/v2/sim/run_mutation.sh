#!/usr/bin/env bash
set -euo pipefail
TASK_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="/tmp/pcb_dynamic_layer_w2_v2_mutation"
mkdir -p "$BUILD_DIR" "$TASK_DIR/sim/logs/v2"
cp "$TASK_DIR/rtl/pcb_frame_updater.v" "$TASK_DIR/rtl/pcb_dynamic_roms_v2.vh" "$TASK_DIR/tb/tb_w2.cpp" "$TASK_DIR/rtl/pcb_ram_2k16.v" "$BUILD_DIR/"
python3 - "$BUILD_DIR/pcb_frame_updater.v" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
old = "GROW_CAP: begin a=max2({16'd0,trace_work[15:0]},mul_result>>>8);"
assert text.count(old) == 1
path.write_text(text.replace(old, old.replace(">>>8", ">>>7")))
PY
cd "$BUILD_DIR"
verilator --cc --exe --build -j 4 --top-module pcb_frame_updater -I. pcb_frame_updater.v pcb_ram_2k16.v tb_w2.cpp -CFLAGS "-O2" > "$TASK_DIR/sim/logs/v2/mutation_compile.log" 2>&1
set +e
timeout 60s ./obj_dir/Vpcb_frame_updater "$TASK_DIR/sim/vectors/v2/w2/boot_silence.bin" mutation_grow_shift > "$TASK_DIR/sim/logs/v2/mutation.log" 2>&1
MUTANT_EXIT=$?
set -e
python3 - "$TASK_DIR" "$BUILD_DIR" "$MUTANT_EXIT" <<'PY'
import datetime, hashlib, json, pathlib, sys
task, build, code = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), int(sys.argv[3])
failure = (task / "sim/logs/v2/mutation.log").read_text().strip()
killed = code == 1 and "T1 addr=" in failure and "expected=" in failure and "actual=" in failure
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
report = {"generated_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(), "status": "KILLED" if killed else "FAIL", "mutation": "GROW_CAP arithmetic shift 8 to 7", "exit_code": code, "failure": failure, "original_sha256": sha(task / "rtl/pcb_frame_updater.v"), "mutant_sha256": sha(build / "pcb_frame_updater.v"), "tb_sha256": sha(build / "tb_w2.cpp"), "vector_sha256": sha(task / "sim/vectors/v2/w2/boot_silence.bin")}
(task / "sim/mutation_result_v2.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report))
sys.exit(0 if killed else 1)
PY
