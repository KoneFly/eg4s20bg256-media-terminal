"""生成 BMP 测试文件(按 32 位大端字 hex 输出) 与 640×480 期望 RGB565 帧。

几何与映射沿用同一套闭式定义(KEEP_ASPECT=1, CROP_PERCENT=6),
本脚本只补齐 BMP 文件层: 24 位 BGR、行 4 字节对齐填充、正高度底行先 / 负高度顶行先。
映射作用在文件行序上, 再按 top_down 翻转为显示行(与主线 loader 行序适配一致)。
用法: make_bmp_case.py <宽> <高> [topdown 0|1] [种子]
输出: sim/bmp_in.hex(每行一个 32 位字, 已补 2 个 0 字用于推出 shim 滞留字节), sim/bmp_expect.hex
"""
import struct
import sys
from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / "sim"
DW, DH = 640, 480


def geom(sw, sh):
    # 与主线 rework_golden.geom 相同
    if 4 * sh < 3 * sw:
        win = min(sw * 100 // 106, sw)
        xo = (sw - win) // 2
        cw, ch = DW, min(DW * sh // win, DH)
    elif 4 * sh == 3 * sw:
        win, xo = sw, 0
        cw, ch = DW, min(DW * sh // sw, DH)
    else:
        win, xo = sw, 0
        ch, cw = DH, min(DH * sw // sh, DW)
    return win, xo, cw, ch, (DW - cw) // 2, (DH - ch) // 2


def src_rgb(x, y, seed):
    h = (x * 40503 + y * 9973 + seed * 7919 + 0x5A5A) & 0xFFFFFFFF
    h ^= h >> 7
    return (h >> 16) & 0xFF, (h >> 8) & 0xFF, h & 0xFF


def to565(r, g, b):
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)


def main():
    sw, sh = int(sys.argv[1]), int(sys.argv[2])
    td = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    seed = int(sys.argv[4]) if len(sys.argv) > 4 else 1
    stride = (sw * 3 + 3) & ~3
    img = bytearray()
    rows = range(sh) if td else range(sh - 1, -1, -1)      # 文件中的行顺序(视觉行号)
    for y in rows:
        line = bytearray()
        for x in range(sw):
            r, g, b = src_rgb(x, y, seed)
            line += bytes([b, g, r])
        img += line.ljust(stride, b"\0")
    hdr = b"BM" + struct.pack("<IHHI", 54 + len(img), 0, 0, 54)
    hdr += struct.pack("<IiiHHIIiiII", 40, sw, -sh if td else sh, 1, 24, 0, len(img), 2835, 2835, 0, 0)
    data = hdr + img
    data += bytes((-len(data)) % 4) + bytes(8)              # 补齐到字 + 2 个推送字
    OUT.mkdir(exist_ok=True)
    with open(OUT / "bmp_in.hex", "w") as f:
        for i in range(0, len(data), 4):
            f.write(data[i:i + 4].hex() + "\n")

    win, xo, cw, ch, lft, top = geom(sw, sh)
    sx = [((t + 1) * win + cw - 1) // cw - 1 + xo for t in range(cw)]
    # 主线链路在"文件行序"上重采样, 再按 top_down 翻转到显示行(bmp_page_loader 的 y_disp)
    def stream_row_visual(k):
        return k if td else sh - 1 - k
    by_r = []
    for r in range(DH):
        if top <= r < top + ch:
            c = r - top
            k = ((c + 1) * sh + ch - 1) // ch - 1           # 文件流第 k 行
            vy = stream_row_visual(k)
            by_r.append([0] * lft + [to565(*src_rgb(x, vy, seed)) for x in sx] + [0] * (DW - lft - cw))
        else:
            by_r.append([0] * DW)
    exp = []
    for d in range(DH):
        exp += by_r[d if td else DH - 1 - d]
    with open(OUT / "bmp_expect.hex", "w") as f:
        f.write("".join("%04x\n" % v for v in exp))
    print(f"{sw}x{sh} td={td} words={len(data)//4} geom cw={cw} ch={ch} lft={lft} top={top}")


if __name__ == "__main__":
    main()
