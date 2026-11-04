"""收集本次实际运行的 W2 结果；未运行场景不会从旧日志补成 PASS。"""
import datetime
import hashlib
import json
import pathlib
import sys

task = pathlib.Path(__file__).resolve().parent.parent
build = pathlib.Path(sys.argv[1])
cases = sys.argv[2:]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


sources = {}
compiled = json.loads((task / "sim/w2_compile_manifest_v2.json").read_text())["sources"]
for name, authoritative in (
    ("pcb_frame_updater.v", task / "rtl/pcb_frame_updater.v"),
    ("pcb_dynamic_roms_v2.vh", task / "rtl/pcb_dynamic_roms_v2.vh"),
    ("tb_w2.cpp", task / "tb/tb_w2.cpp"),
    ("pcb_ram_2k16.v", task / "rtl/pcb_ram_2k16.v"),
):
    built_hash = compiled[name]
    if built_hash != sha(authoritative):
        raise RuntimeError(f"运行期间源码变化，不能归档为当前版结果：{name}")
    sources[name] = built_hash

results = []
for scenario in cases:
    lines = (task / f"sim/logs/v2/{scenario}.log").read_text().splitlines()
    result = json.loads(lines[-1])
    if result["scenario"] != scenario or result["status"] != "PASS":
        raise RuntimeError(f"运行结果不通过：{scenario}")
    vector = {"tick_overrun": "boot_low", "reset_reentry": "boot_low"}.get(scenario, scenario)
    result["vector_sha256"] = sha(task / f"sim/vectors/v2/w2/{vector}.bin")
    results.append(result)

report = {
    "generated_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "scope": "W2 DUT simulation only; no W1, configuration-boundary, TD timing or board acceptance",
    "status": "PASS",
    "backend": "WSL Ubuntu Verilator",
    "profile": "no_particles_v2",
    "source_sha256": sources,
    "golden_manifest": json.loads((task / "sim/vectors/v2/w2/manifest.json").read_text()),
    "scenarios": results,
    "max_update_cycles": max(r["max_update_cycles"] for r in results),
}
(task / "sim/sim_result_v2.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
