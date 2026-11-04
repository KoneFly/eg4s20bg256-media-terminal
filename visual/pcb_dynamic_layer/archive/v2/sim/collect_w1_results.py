"""仅收集本次 W1 完整帧实测；像素等价与消隐期限分别判定。"""
import datetime
import hashlib
import json
import pathlib
import sys

task = pathlib.Path(__file__).resolve().parent.parent
build = pathlib.Path(sys.argv[1])
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
sources = {}
compiled = json.loads((task / "sim/w1_compile_manifest_v2.json").read_text())["sources"]
for name, path in (
    ("pcb_particle_overlay.v", task / "rtl/pcb_particle_overlay.v"),
    ("pcb_span_ram.v", task / "rtl/pcb_span_ram.v"),
    ("pcb_ram_2k16.v", task / "rtl/pcb_ram_2k16.v"),
    ("pcb_dynamic_roms_v2.vh", task / "rtl/pcb_dynamic_roms_v2.vh"),
    ("tb_w1.cpp", task / "tb/tb_w1.cpp"),
):
    sources[name] = compiled[name]
    if sources[name] != sha(path):
        raise RuntimeError(f"源码变化：{name}")
results = [json.loads(line) for line in (task / "sim/logs/v2/w1.log").read_text().splitlines()]
golden = {}
for result in results:
    if result["status"] != "PASS":
        raise RuntimeError("W1 像素失配")
    golden[result["scenario"]] = {
        name: sha(task / "sim/vectors/v2/w1" / result["scenario"] / name)
        for name in ("state_misc.bin", "overlay_hit.bin", "overlay_rgb565.bin", "overlay_alpha.bin")
    }
report = {
    "generated_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "profile": "no_particles_v2",
    "scope": "W1 standalone full frames with completed bucket publication; no S2 integration or board acceptance",
    "pixel_comparison": "PASS", "fixed_delay_and_markers": "PASS",
    "vblank_deadline": "PASS" if all(r["fits_36000_vblank_cycles"] for r in results) else "FAIL",
    "source_sha256": sources, "golden_sha256": golden, "scenarios": results,
}
(task / "sim/w1_result_v2.json").write_text(json.dumps(report, indent=2) + "\n")
