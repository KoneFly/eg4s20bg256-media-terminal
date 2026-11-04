"""创建独立启动自检；仅向新目录复制少量冻结资产，不改完整工程。"""
import hashlib
import json
from pathlib import Path
import runpy
import shutil

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / "experiments/startup_selftest_S1"
assert not WORK.exists(), "禁止覆盖已有S1"
runpy.run_path(str(ROOT / "scripts/seal_a4_confirmed_readback.py"))
PARENT = ROOT / "experiments/board_0x46_A4_work/project/src"
for directory in ("project/src/rtl", "project/src/vendor/display020", "project/src/vendor/udp_base/ip",
                  "project/src/constraints", "scripts", "tb", "sim", "doc/output"):
    (WORK / directory).mkdir(parents=True, exist_ok=True)
copied = []
for relative in ["rtl/fdi_clock_tree.v", "rtl/v7_decimal_display.v", "vendor/udp_base/ip/pll_gen.v"] + [
        f"vendor/display020/{p.name}" for p in sorted((PARENT / "vendor/display020").glob("*.v"))]:
    source, dest = PARENT / relative, WORK / "project/src" / relative
    shutil.copy2(source, dest)
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    assert hashlib.sha256(dest.read_bytes()).hexdigest() == digest
    copied.append(dict(source=source.as_posix(), path=relative, sha256=digest))
adc = (PARENT / "constraints/eth_m6_master.adc").read_text(encoding="utf-8")
selected = [line for line in adc.splitlines() if line.startswith("set_pin_assignment") and
            any("{" + name in line for name in ("clk_50}", "key1}", "sw[", "led[", "dled[", "HDMI_"))]
assert len(selected) == 32, len(selected)
(WORK / "project/src/constraints/eth_m6_master.adc").write_text("\n".join(selected) + "\n", encoding="utf-8")
(WORK / "doc/output/REFERENCE_ASSETS.json").write_text(json.dumps(dict(copied=copied,
    diagnostic_only=True, spi_sdram_w2_s2_not_instantiated=True, original_files_changed=0), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(WORK)
