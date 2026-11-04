"""生成含 V29/1 视频文件的 FAT32 稀疏镜像, 以及每帧期望 RGB565 像素(独立黄金)。

用法: make_video_image.py <fmt 1|2> <帧数> <fps>
视频帧内容: 帧号/坐标的确定性函数(与 RTL 无关)。RGB332 展开规则按 T29 合同:
  R5=(r3<<2)|(r3>>1), G6=(g3<<3)|g3, B5=(b2<<3)|(b2<<1)|(b2>>1)。
输出: sim/vid_img.hex(块镜像), sim/vid_expect.hex(每帧 307200 个 16 位像素, 逐行)。
文件簇分成 3 段不连续 extent, 检验跨 extent 读。
"""
import struct
import sys
from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / "sim"
PART, SPC, RSVD, NFATS, FATSZ = 2048, 8, 32, 2, 1024
FAT_LBA = PART + RSVD
DATA_LBA = FAT_LBA + NFATS * FATSZ
W, H = 640, 480


def clus_lba(c):
    return DATA_LBA + (c - 2) * SPC


def src_pixel(fmt, f, x, y):
    v = (x * 7 + y * 13 + f * 101) ^ (x >> 3) ^ (y << 2)
    return (v ^ (v >> 9)) & (0xFFFF if fmt == 1 else 0xFF)


def expand332(c):
    r3, g3, b2 = c >> 5, (c >> 2) & 7, c & 3
    return (((r3 << 2) | (r3 >> 1)) << 11) | (((g3 << 3) | g3) << 5) | ((b2 << 3) | (b2 << 1) | (b2 >> 1))


def main():
    fmt, nfr, fps = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
    ab = int(sys.argv[4]) if len(sys.argv) > 4 else 0     # 每帧音频块数, 0 = version 1
    rate_num, rate_den = 25200000 * 25, 13104              # 48076.923Hz 的有理表示
    bpp = 2 if fmt == 1 else 1
    fbytes = W * H * bpp
    hdr = bytearray(512)
    hdr[0:4] = b"T29V"
    struct.pack_into("<HHHHBBHIIIIIIQI", hdr, 4, 2 if ab else 1, 512, W, H, fmt, ab, 0, fps, 1, fbytes,
                     nfr, 0, 0xFFFFFFFF, 0, 7)
    body = bytearray()
    expect = []
    aud = []
    sidx = 0
    for f in range(nfr):
        for y in range(H):
            for x in range(W):
                p = src_pixel(fmt, f, x, y)
                body += struct.pack("<H", p) if fmt == 1 else bytes([p])
                expect.append(p if fmt == 1 else expand332(p))
        if ab:
            # 累计样本数 floor((f+1)·rate/fps) 减去已分配, 长期与播放节拍一致
            n = (f + 1) * rate_num // (rate_den * fps) - sidx
            assert 4 + 2 * n <= 512 * ab
            smp = [((i * 2654435761) >> 7) & 0xFFFF for i in range(sidx, sidx + n)]
            sidx += n
            aud += smp
            blk = struct.pack("<I", n) + b"".join(struct.pack("<H", v) for v in smp)
            body += blk.ljust(512 * ab, b"\0")
    with open(OUT / "aud_expect.hex", "w") as fh:
        fh.write("".join("%04x\n" % v for v in aud) if aud else "0000\n")
    data = bytes(hdr) + bytes(body)
    size = len(data)
    ncl = -(-size // (SPC * 512))
    a, b = ncl // 3, ncl // 3
    clusters = list(range(200, 200 + a)) + list(range(4000, 4000 + b)) + list(range(9000, 9000 + ncl - a - b))

    blocks = {}
    fat = {0: 0x0FFFFFF8, 1: 0x0FFFFFFF, 2: 0x0FFFFFFF}
    mbr = bytearray(512)
    mbr[446 + 4] = 0x0C
    mbr[446 + 8:446 + 12] = struct.pack("<I", PART)
    mbr[510:512] = b"\x55\xAA"
    blocks[0] = bytes(mbr)
    bpb = bytearray(512)
    bpb[0:3] = b"\xEB\x58\x90"
    struct.pack_into("<HBHB", bpb, 11, 512, SPC, RSVD, NFATS)
    struct.pack_into("<I", bpb, 36, FATSZ)
    struct.pack_into("<I", bpb, 44, 2)
    bpb[510:512] = b"\x55\xAA"
    blocks[PART] = bytes(bpb)
    ent = b"VID00000V29" + bytes([0x20]) + b"\0" * 8 + struct.pack("<H", clusters[0] >> 16) + b"\0" * 4 + \
        struct.pack("<HI", clusters[0] & 0xFFFF, size)
    blocks[clus_lba(2)] = ent.ljust(512, b"\0")
    for i, c in enumerate(clusters):
        fat[c] = clusters[i + 1] if i + 1 < len(clusters) else 0x0FFFFFFF
        for s in range(SPC):
            off = (i * SPC + s) * 512
            if off < size:
                blk = data[off:off + 512].ljust(512, b"\0")
                if any(blk):
                    blocks[clus_lba(c) + s] = blk
    for c, v in fat.items():
        for copy in range(NFATS):
            lba = FAT_LBA + copy * FATSZ + c // 128
            sec = bytearray(blocks.get(lba, bytes(512)))
            sec[(c % 128) * 4:(c % 128) * 4 + 4] = struct.pack("<I", v)
            blocks[lba] = bytes(sec)
    OUT.mkdir(exist_ok=True)
    with open(OUT / "vid_img.hex", "w") as fh:
        for lba in sorted(blocks):
            fh.write("%08x %s\n" % (lba, blocks[lba].hex()))
    with open(OUT / "vid_expect.hex", "w") as fh:
        fh.write("\n".join("%04x" % p for p in expect) + "\n")
    print("fmt", fmt, "frames", nfr, "A", ab, "samples", len(aud), "size", size, "blocks", len(blocks))


if __name__ == "__main__":
    main()
