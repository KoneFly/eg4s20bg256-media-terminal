"""截取 V29 文件的帧区间，重写帧数，用于压缩交付包体积。

用法：python trim_v29.py <输入.V29> <输出.V29> (--head N | --tail N)
  --head N  保留前 N 帧（从片头取）
  --tail N  保留后 N 帧（从片尾取，用于保留末帧与首图一致的启动片）
播放端按文件长度截止，因此只需改头里的帧数并截断数据。
"""
import argparse
import struct
from pathlib import Path

HDR = 52


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('src')
    ap.add_argument('dst')
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument('--head', type=int)
    g.add_argument('--tail', type=int)
    a = ap.parse_args()

    src = Path(a.src).read_bytes()
    magic, ver, hb, w, h, fmt, ab, _u, fps, _n, fbytes, frames = struct.unpack('<4sHHHHBBHIIII', src[:32])
    assert magic == b'T29V', '不是 V29 文件'
    rec = fbytes + ab * 512
    body = src[512:]
    assert len(body) >= frames * rec, '文件长度与帧数不符'
    n = a.head if a.head else a.tail
    n = min(n, frames)
    start = 0 if a.head else frames - n
    data = body[start * rec:(start + n) * rec]
    hdr = bytearray(src[:512])
    struct.pack_into('<I', hdr, 28, n)
    Path(a.dst).write_bytes(bytes(hdr) + data)
    print(f'{a.dst}: {n}/{frames} 帧, {len(hdr)+len(data)} 字节, {n/fps:.1f}s @{fps}fps')


if __name__ == '__main__':
    main()
