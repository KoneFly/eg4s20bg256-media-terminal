"""只读验证既有封存及保护资产，另立A4真卡读数补充索引。"""
import hashlib
import gzip
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(record):
    path = Path(record["path"])
    if not path.is_absolute():
        path = ROOT / path
    if path.is_file():
        assert path.stat().st_size == record["bytes"], str(path)
        assert sha(path) == record["sha256"], str(path)
        return None
    # 部分历史原文现以gzip保存；只在内存中解压核验，不还原或覆盖封存路径。
    packed = Path(str(path) + ".gz")
    assert packed.is_file(), str(path)
    digest, length = hashlib.sha256(), 0
    with gzip.open(packed, "rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
            length += len(chunk)
    assert length == record["bytes"] and digest.hexdigest() == record["sha256"], str(packed)
    return dict(original_path=record["path"], gzip_path=str(packed),
                gzip_bytes=packed.stat().st_size, gzip_sha256=sha(packed),
                decompressed_bytes=length, decompressed_sha256=digest.hexdigest())


indexes = [
    "BOARD_PROBE_A4_EVIDENCE_INDEX.json",
    "A3_PROBE_BOARD_READBACK_EVIDENCE_20261006.json",
    "BOARD_PROBE_A3_EVIDENCE_INDEX.json",
    "BOARD_PROBE_A2_EVIDENCE_INDEX.json",
    "BOARD_PROBE_A2_SUPPORTING_EVIDENCE.json",
    "ROUND2_EVIDENCE_INDEX.json",
    "A2_PROBE_REVIEW_EVIDENCE_INDEX_20261006.json",
    "A2_PROBE_BOARD_READBACK_EVIDENCE_20261006.json",
]
prior = []
for name in indexes:
    path = ROOT / "doc/output" / name
    document = json.loads(path.read_text(encoding="utf-8"))
    compressed = []
    for record in document["files"]:
        packed = verify(record)
        if packed:
            compressed.append(packed)
    prior.append(dict(path=path.relative_to(ROOT).as_posix(), sha256=sha(path),
                      verified_entries=len(document["files"]), compressed_payloads=compressed))
preflight = ROOT / "doc/output/ROUND2_PREFLIGHT.json"
protected = json.loads(preflight.read_text(encoding="utf-8"))["artifacts"]
protected_compressed = []
for record in protected:
    packed = verify(record)
    if packed:
        protected_compressed.append(packed)

names = [
    "doc/output/A4_PROBE_BOARD_READBACK_PARTIAL_20261006.json",
    "doc/output/A4_PROBE_BOARD_ANALYSIS_PARTIAL_20261006.md",
    "doc/output/A4_PROBE_HISTORY_STATIC_20261006.json",
    "scripts/review_a4_history_readback.py",
    "scripts/seal_a4_board_readback.py",
]
files = []
for name in names:
    path = ROOT / name
    files.append(dict(path=name, bytes=path.stat().st_size, sha256=sha(path)))
result = dict(status="SEALED_USER_BOARD_OBSERVATION_PARTIAL",
              hardware_status="FAIL_NO_PCB_IMAGE_REPORTED",
              unresolved="Current-run d0/d7, KEY1 precondition, d3 numeric detail and explicit no-signal versus black image",
              bit_sha256="343714aaa27eec0f317dc4b546e591496cc16cfc0ba6c0f56f3faff3d40d8fe8",
              files=files, prior_archives=prior,
              protected_assets=dict(path="doc/output/ROUND2_PREFLIGHT.json", sha256=sha(preflight),
                                    verified_entries=len(protected), compressed_payloads=protected_compressed),
              no_rtl_sdc_bit_mutation=True)
output = ROOT / "doc/output/A4_PROBE_BOARD_READBACK_EVIDENCE_20261006.json"
serialized = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
if output.exists():
    assert output.read_text(encoding="utf-8") == serialized, "禁止覆盖不同证据"
else:
    output.write_text(serialized, encoding="utf-8")
print(json.dumps(dict(status=result["status"], new_entries=len(files),
                      prior_entries=sum(r["verified_entries"] for r in prior),
                      compressed_prior_entries=sum(len(r["compressed_payloads"]) for r in prior),
                      protected_entries=len(protected)), ensure_ascii=False))
