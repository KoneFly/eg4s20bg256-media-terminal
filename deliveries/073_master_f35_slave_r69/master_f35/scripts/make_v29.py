"""把普通视频转为 V29 原始帧文件(PC 侧预转换), 格式见 doc/output/V29_FORMAT.md。

用法:
  python make_v29.py <输入视频> <输出 VID00000.V29> [--fmt 565|332] [--fps 15|24|30]
                     [--max-sec N] [--no-audio]

依赖 ffmpeg(PATH 中): 等比缩放到 640×480 加黑边, 按目标帧率重采样, 输出 rgb24 原始帧
后在本脚本量化。量化按就近取整: 选使 FPGA 位复制展开后最接近原色的码(比截位误差小)。
有音轨且未指定 --no-audio 时生成 version 2: 音频下混单声道, 重采样到 48076.923Hz
(FPGA 播放节拍), 按帧累加分配样本。另写 <输出>.sha256 便于核对卡上文件。
"""
import argparse
import hashlib
import struct
import subprocess
import sys
from pathlib import Path

W, H = 640, 480
RATE_NUM, RATE_DEN = 25200000 * 25, 13104      # 48076.923Hz
AB = 7                                          # 每帧音频块数(30fps 每帧 ≤1603 样本)


def header(fmt, fps, nframes, ab):
    fbytes = W * H * (2 if fmt == 1 else 1)
    h = bytearray(512)
    h[0:4] = b"T29V"
    struct.pack_into("<HHHHBBHIIIIIIQI", h, 4, 2 if ab else 1, 512, W, H, fmt, ab, 0, fps, 1, fbytes,
                     nframes, 0, 0xFFFFFFFF, 0, 1)
    return bytes(h)


def _nearest_lut(bits, expand):
    """每个 8 位输入值 -> 使 FPGA 位复制展开后最接近原值的 bits 位码(就近取整, 非截位)。"""
    import numpy as np
    lv = np.array([expand(q) for q in range(1 << bits)])
    return np.array([int(np.argmin(np.abs(lv - v))) for v in range(256)], dtype=np.uint16)


def _luts():
    # FPGA 显示链: RGB332 -> RGB565 位复制 -> RGB888 位复制
    e5 = lambda v5: (v5 << 3) | (v5 >> 2)
    e6 = lambda v6: (v6 << 2) | (v6 >> 4)
    r3 = _nearest_lut(3, lambda q: e5((q << 2) | (q >> 1)))
    g3 = _nearest_lut(3, lambda q: e6((q << 3) | q))
    b2 = _nearest_lut(2, lambda q: e5((q << 3) | (q << 1) | (q >> 1)))
    r5 = _nearest_lut(5, e5)
    g6 = _nearest_lut(6, e6)
    return r3, g3, b2, r5, g6


LUT = None


def quantize(rgb, fmt):
    import numpy as np
    global LUT
    if LUT is None:
        LUT = _luts()
    r3, g3, b2, r5, g6 = LUT
    a = np.frombuffer(rgb, dtype=np.uint8).reshape(-1, 3)
    r, g, b = a[:, 0], a[:, 1], a[:, 2]
    if fmt == 1:
        p = (r5[r] << 11) | (g6[g] << 5) | r5[b]
        return p.astype("<u2").tobytes()
    p = (r3[r] << 5) | (g3[g] << 2) | b2[b]
    return p.astype(np.uint8).tobytes()


def load_audio(src, max_sec):
    # ffmpeg 只接受整数采样率: 先到 48077Hz, 误差 0.05‰ 在 FPGA 端表现为极慢漂移, 可忽略
    cmd = ["ffmpeg", "-v", "error", "-i", src, "-vn", "-ac", "1", "-ar", "48077"]
    if max_sec > 0:
        cmd += ["-t", str(max_sec)]
    cmd += ["-f", "s16le", "-"]
    r = subprocess.run(cmd, stdout=subprocess.PIPE)
    return r.stdout if r.returncode == 0 else b""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--fmt", choices=["565", "332"], default="332")
    ap.add_argument("--fps", type=int, choices=[15, 24, 30], default=30)
    ap.add_argument("--max-sec", type=float, default=0)
    ap.add_argument("--no-audio", action="store_true")
    a = ap.parse_args()
    fmt = 1 if a.fmt == "565" else 2
    pcm = b"" if a.no_audio else load_audio(a.src, a.max_sec)
    ab = AB if pcm else 0
    vf = (f"fps={a.fps},scale={W}:{H}:force_original_aspect_ratio=decrease,"
          f"pad={W}:{H}:(ow-iw)/2:(oh-ih)/2:color=black")
    cmd = ["ffmpeg", "-v", "error", "-i", a.src, "-an", "-vf", vf]
    if a.max_sec > 0:
        cmd += ["-t", str(a.max_sec)]
    cmd += ["-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
    frame = W * H * 3
    out = Path(a.dst)
    tmp = out.with_suffix(".part")
    n = 0
    sidx = 0
    nsamp = len(pcm) // 2
    with subprocess.Popen(cmd, stdout=subprocess.PIPE) as p, open(tmp, "wb") as f:
        f.write(bytes(512))                          # 头块占位, 帧数确定后回填
        while True:
            buf = p.stdout.read(frame)
            if len(buf) < frame:
                break
            f.write(quantize(buf, fmt))
            if ab:
                want = (n + 1) * RATE_NUM // (RATE_DEN * a.fps) - sidx
                seg = pcm[2 * sidx:2 * (sidx + want)]
                seg += bytes(2 * want - len(seg))     # 音轨短于视频时补静音
                sidx += want
                f.write((struct.pack("<I", want) + seg).ljust(512 * ab, b"\0"))
            n += 1
        if p.wait() != 0:
            sys.exit("ffmpeg 失败")
    if n == 0:
        sys.exit("没有解码出帧")
    with open(tmp, "r+b") as f:
        f.write(header(fmt, a.fps, n, ab))
    size = tmp.stat().st_size
    if size > 0xFFFFFFFF:
        sys.exit("文件超过 4GiB, FAT32 不支持; 请用 --max-sec 截短")
    tmp.replace(out)
    sha = hashlib.sha256()
    with open(out, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            sha.update(chunk)
    Path(str(out) + ".sha256").write_text(f"{sha.hexdigest()}  {out.name}\n")
    rate = size / (n / a.fps) / 1e6
    print(f"{out}: {n} frames @{a.fps}fps fmt={a.fmt} audio={'yes' if ab else 'no'}"
          f"({nsamp} samples) size={size}B need={rate:.2f}MB/s")


if __name__ == "__main__":
    main()
