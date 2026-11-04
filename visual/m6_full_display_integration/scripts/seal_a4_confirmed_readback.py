"""确认A4补读与新分层计划，复核旧封存；仅创建新的证据索引。"""
import hashlib
import json
from pathlib import Path
import runpy

ROOT = Path(__file__).resolve().parents[1]
# 复用已封存的原文/gzip逐字节核验，禁止改写旧证据。
audit = runpy.run_path(str(ROOT / "scripts/seal_a4_board_readback.py"))
sha = audit["sha"]
partial_index = ROOT / "doc/output/A4_PROBE_BOARD_READBACK_EVIDENCE_20261006.json"
reference = (ROOT.parents[2] / "iccoder_workspace/tasks/task_052_ethernet_pcm_link/td_run/"
             "v9_display_20261004_final2/eth_udp_m6_master_top.bit")
expected = "75959e68b425de7a36ee937949c683b956d90164ea72c68e2bbcd40b6d5d5d1b"
assert reference.is_file() and sha(reference) == expected
files = []
for name in (
    "doc/output/A4_PROBE_BOARD_READBACK_CONFIRMED_20261006.json",
    "doc/output/A4_PROBE_BOARD_ANALYSIS_CONFIRMED_20261006.md",
    "doc/brief/BOARD_DIAGNOSTIC_ISOLATION_PLAN_20261006.md",
    "scripts/seal_a4_confirmed_readback.py",
):
    path = ROOT / name
    files.append(dict(path=name, bytes=path.stat().st_size, sha256=sha(path)))
result = dict(status="SEALED_CONFIRMED_USER_OBSERVATION_AND_ISOLATION_PLAN",
              hardware_status="FAIL_MONITOR_NO_SIGNAL_AND_NO_PCB_IMAGE",
              actual_board_bit_readback=False,
              files=files,
              prior_partial_evidence=dict(path=partial_index.relative_to(ROOT).as_posix(), sha256=sha(partial_index)),
              source_chain_evidence=[dict(path=f"experiments/board_0x46_A4_work/project/src/{name}",
                                          sha256=sha(ROOT / "experiments/board_0x46_A4_work/project/src" / name))
                                     for name in ("rtl/v9_m6_scan.v", "rtl/v9_m6_hdmi.v",
                                                  "vendor/display020/axis_pixel_adapter.v",
                                                  "vendor/fdi_loader/fdi_sdram_cmd_engine.v")],
              reference_bit=dict(path=reference.as_posix(), bytes=reference.stat().st_size, sha256=expected,
                                 current_run_board_comparison="PENDING_USER_BOARD_TEST"),
              prior_entries_verified=1389, prior_gzip_payloads_verified=68, protected_entries_verified=81,
              no_rtl_sdc_bit_mutation=True, new_self_test_bit="NOT_IMPLEMENTED")
output = ROOT / "doc/output/A4_PROBE_BOARD_CONFIRMED_EVIDENCE_20261006.json"
serialized = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
if output.exists():
    assert output.read_text(encoding="utf-8") == serialized, "禁止覆盖不同证据"
else:
    output.write_text(serialized, encoding="utf-8")
print(json.dumps(dict(status=result["status"], new_entries=len(files), reference_sha256=expected), ensure_ascii=False))
