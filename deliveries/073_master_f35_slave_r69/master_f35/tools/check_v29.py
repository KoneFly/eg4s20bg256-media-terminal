"""PC 侧校验 V29 完整长度和交织音频记录，不依赖 FPGA 宽乘法校验器。只读素材。"""
import argparse
import json
import struct
from pathlib import Path


def inspect(path):
    result = {"file": str(path.resolve()), "passed": False}
    try:
        with path.open("rb") as media:
            header = media.read(512)
            if len(header) != 512 or header[:4] != b"T29V":
                raise ValueError("invalid or truncated header")
            version, size, width, height = struct.unpack_from("<4H", header, 4)
            fmt, audio_blocks = header[12], header[13]
            fps, fps_den, frame_bytes, frame_count = struct.unpack_from("<4I", header, 16)
            if size != 512 or (width, height) != (640, 480):
                raise ValueError("unsupported geometry")
            if fmt not in (1, 2) or frame_bytes != width * height * (2 if fmt == 1 else 1):
                raise ValueError("pixel format/frame size mismatch")
            if fps not in (15, 24, 30) or fps_den != 1 or frame_count == 0:
                raise ValueError("unsupported frame cadence/count")
            if not ((version == 1 and audio_blocks == 0) or (version == 2 and audio_blocks > 0)):
                raise ValueError("version/audio mismatch")
            if path.name.upper() == "BOOT.V29" and frame_count > 65535:
                raise ValueError("BOOT exceeds display-counter range")
            record_bytes = frame_bytes + audio_blocks * 512
            expected_bytes = 512 + frame_count * record_bytes
            actual_bytes = path.stat().st_size
            if expected_bytes != actual_bytes:
                raise ValueError(f"file length {actual_bytes} != {expected_bytes}")
            audio_samples = 0
            for index in range(frame_count if audio_blocks else 0):
                media.seek(512 + index * record_bytes + frame_bytes)
                count = struct.unpack("<I", media.read(4))[0]
                if count > 65535 or count * 2 + 4 > audio_blocks * 512:
                    raise ValueError(f"audio record {index}: sample count {count} exceeds capacity")
                audio_samples += count
            result.update(passed=True, version=version, pixel_format="RGB565" if fmt == 1 else "RGB332",
                          frames=frame_count, fps=fps, bytes=actual_bytes,
                          audio_records=frame_count if audio_blocks else 0, audio_samples=audio_samples)
    except (OSError, ValueError, struct.error) as exc:
        result["error"] = str(exc)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("files", type=Path, nargs="+")
    parser.add_argument("--json", type=Path, required=True)
    args = parser.parse_args()
    results = [inspect(path) for path in args.files]
    args.json.write_text(json.dumps({"scope": "file format, exact length and audio count bounds only; not board acceptance",
                                     "results": results}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    for item in results:
        print(("PASS " if item["passed"] else "FAIL ") + item["file"])
    raise SystemExit(0 if all(item["passed"] for item in results) else 1)


if __name__ == "__main__":
    main()
