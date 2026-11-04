"""生成 FAT32 测试镜像(稀疏块表)与期望 extent, 供 fat32_scan 仿真作独立黄金。

镜像: MBR 分区(0x0C) @LBA 2048, 每簇 8 扇区, 2 张 FAT; 根目录跨两个簇(第二簇不连续),
含删除项、LFN 项、卷标、子目录项, 目标文件 VID00000.V29 有 3 个不连续 extent。
输出: sim/fat_img.hex(每行 "LBA 512字节hex", 只含非零块), sim/fat_expect.txt。
"""
import struct
import sys
from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / "sim"
PART, SPC, RSVD, NFATS, FATSZ = 2048, 8, 32, 2, 1024
FAT_LBA = PART + RSVD
DATA_LBA = FAT_LBA + NFATS * FATSZ
blocks = {}
fat = {}


def clus_lba(c):
    return DATA_LBA + (c - 2) * SPC


def put(lba, data):
    blocks[lba] = data.ljust(512, b"\0")


def chain(cl):
    for a, b in zip(cl, cl[1:]):
        fat[a] = b
    fat[cl[-1]] = 0x0FFFFFFF


def dirent(name, attr, clus, size):
    return name + bytes([attr, 0, 0]) + b"\0" * 6 + struct.pack("<H", clus >> 16) + b"\0" * 4 + \
        struct.pack("<H", clus & 0xFFFF) + struct.pack("<I", size)


def main():
    mbr = bytearray(512)
    mbr[446 + 4] = 0x0C
    mbr[446 + 8:446 + 12] = struct.pack("<I", PART)
    mbr[446 + 12:446 + 16] = struct.pack("<I", 1 << 20)
    mbr[510:512] = b"\x55\xAA"
    put(0, bytes(mbr))

    bpb = bytearray(512)
    bpb[0:3] = b"\xEB\x58\x90"
    bpb[11:13] = struct.pack("<H", 512)
    bpb[13] = SPC
    bpb[14:16] = struct.pack("<H", RSVD)
    bpb[16] = NFATS
    bpb[36:40] = struct.pack("<I", FATSZ)
    bpb[44:48] = struct.pack("<I", 2)
    bpb[510:512] = b"\x55\xAA"
    put(PART, bytes(bpb))

    # 根目录簇 2 -> 9 (不连续)
    chain([2, 9])
    ents = [dirent(b"VOLUME     ", 0x08, 0, 0),
            b"\xE5" + dirent(b"VID00000V29", 0x20, 77, 1234)[1:],      # 已删除的同名项
            bytes([0x41]) + b"\0" * 10 + bytes([0x0F]) + b"\0" * 20,      # LFN 项
            dirent(b"SUBDIR     ", 0x10, 50, 0),
            dirent(b"PIC1    BMP", 0x20, 60, 1000)]
    # 填满第一簇(8 扇区 × 16 项)让目标落在第二簇
    filler = [dirent(b"F%07d" % i + b"BIN", 0x20, 70, 10) for i in range(8 * 16 - len(ents))]
    ents += filler
    for i in range(8):
        put(clus_lba(2) + i, b"".join(ents[i * 16:(i + 1) * 16]))

    size = 3 * 1024 * 1024 + 12345
    ncl = -(-size // (SPC * 512))
    clusters = list(range(100, 100 + 300)) + list(range(1000, 1000 + 200)) + list(range(5000, 5000 + ncl - 500))
    assert len(clusters) == ncl
    chain(clusters)
    put(clus_lba(9), dirent(b"OTHER   TXT", 0x20, 80, 5) + dirent(b"VID00000V29", 0x20, clusters[0], size))

    for c in (50, 60, 70, 80):
        fat[c] = 0x0FFFFFFF
    fat[0], fat[1] = 0x0FFFFFF8, 0x0FFFFFFF
    for c, v in fat.items():
        for copy in range(NFATS):
            lba = FAT_LBA + copy * FATSZ + c // 128
            sec = bytearray(blocks.get(lba, bytes(512)))
            sec[(c % 128) * 4:(c % 128) * 4 + 4] = struct.pack("<I", v)
            blocks[lba] = bytes(sec)

    # 期望 extent
    ext = []
    for c in clusters:
        if ext and c == ext[-1][0] + ext[-1][1]:
            ext[-1][1] += 1
        else:
            ext.append([c, 1])
    OUT.mkdir(exist_ok=True)
    with open(OUT / "fat_img.hex", "w") as f:
        for lba in sorted(blocks):
            f.write("%08x %s\n" % (lba, blocks[lba].hex()))
    with open(OUT / "fat_expect.txt", "w") as f:
        f.write("%d %d\n" % (size, len(ext)))
        for c, n in ext:
            f.write("%d %d\n" % (clus_lba(c), n * SPC))
    print("blocks", len(blocks), "size", size, "extents", ext)


if __name__ == "__main__":
    sys.exit(main())
