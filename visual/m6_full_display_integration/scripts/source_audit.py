"""逐文件差异与只读上游身份核验，仅输出到本任务。"""
from pathlib import Path
import difflib
import hashlib
import json
import sys

TASK = Path(__file__).resolve().parent.parent
BASE = TASK / "reference/base_src"
CURRENT = TASK / "project/src"
WORKSPACE = TASK.parent.parent
OUTPUT = TASK / "doc/output"
PREFIX = sys.argv[1] if len(sys.argv)>1 else ""
if PREFIX not in ("", "ROUND2_"):
    raise ValueError("Unsupported evidence prefix")
ALLOWED = {
    "constraints/eth_m6_master.adc", "constraints/eth_m6_master.sdc",
    "rtl/v9_udp_m6_master_top.v", "rtl/v9_m6_hdmi.v", "rtl/v9_m6_scan.v",
    "vendor/udp_base/ip/pll_gen.v", "vendor/m6_s2/pcb_state_mem.v",
    "vendor/m6_s2/pcb_pixel_renderer.v",
}

def digest(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def inventory(root):
    return {p.relative_to(root).as_posix(): p for p in sorted(root.rglob("*")) if p.is_file()}

baseline, current = inventory(BASE), inventory(CURRENT)
rows, patch = [], []
for name in sorted(baseline.keys() | current.keys()):
    before, after = baseline.get(name), current.get(name)
    old_sha, new_sha = digest(before) if before else None, digest(after) if after else None
    state = "ADDED" if not before else "REMOVED" if not after else "SAME" if old_sha == new_sha else "MODIFIED"
    rows.append(dict(path=name, status=state, baseline_sha256=old_sha, current_sha256=new_sha))
    if state != "SAME":
        old = before.read_text(encoding="utf-8-sig", errors="replace").splitlines(keepends=True) if before else []
        new = after.read_text(encoding="utf-8-sig", errors="replace").splitlines(keepends=True) if after else []
        patch.extend(difflib.unified_diff(old, new, fromfile=f"a/{name}" if before else "/dev/null", tofile=f"b/{name}" if after else "/dev/null"))

unexpected = [r["path"] for r in rows if r["status"] == "REMOVED" or (r["status"] == "MODIFIED" and r["path"] not in ALLOWED)]
protected = [{"path": "rtl/v9_spectrum_snapshot.v", "pass": digest(BASE / "rtl/v9_spectrum_snapshot.v") == digest(CURRENT / "rtl/v9_spectrum_snapshot.v")}]
for name in ("pcb_frame_updater.v", "pcb_ram_2k16.v", "pcb_dynamic_roms_w2.vh"):
    original = WORKSPACE / "rtl_handoff/pcb_dynamic_layer/rtl" / name
    copy = CURRENT / "vendor/w2" / name
    protected.append({"path": f"vendor/w2/{name}", "original": str(original), "sha256": digest(copy), "pass": digest(original) == digest(copy)})
for name, original in (("PCB.BMP", WORKSPACE / "golden/pcb/PCB.BMP"), ("rom_row_span.hex", WORKSPACE / "golden/pcb/rom/rom_row_span.hex")):
    copy = TASK / "project/assets" / name
    protected.append({"path": f"project/assets/{name}", "sha256": digest(copy), "pass": digest(original) == digest(copy)})
result = {"status": "PASS" if not unexpected and all(r["pass"] for r in protected) else "FAIL", "unexpected_changes": unexpected, "protected": protected, "counts": {s: sum(r["status"] == s for r in rows) for s in ("SAME", "MODIFIED", "ADDED", "REMOVED")}, "files": rows}
OUTPUT.mkdir(parents=True, exist_ok=True)
(OUTPUT / f"{PREFIX}SOURCE_DIFF.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
(OUTPUT / f"{PREFIX}SOURCE_DIFF.patch").write_text("".join(patch), encoding="utf-8")
print(json.dumps({k: v for k, v in result.items() if k != "files"}, ensure_ascii=False, indent=2))
if result["status"] != "PASS":
    raise SystemExit(1)
