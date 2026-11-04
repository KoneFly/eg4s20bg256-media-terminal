"""生成 t073_osd 的字串 ROM、字串属性与字模 ROM(Verilog case 表), 写入 rtl/t073_osd_rom.vh。

字符编码 6 位: 0 透明 1 空格 2..11 '0'..'9' 12..37 'A'..'Z' 38 ':' 39 '>' 40 '-' 41 '+' 42 '<' 43 '/'。
字串属性 2 位: 0 数值(白) 1 名称(浅青) 2 标签块(黄字蓝底)。
字串按序紧排在一张 ROM 里, 另给每个字串号的 {属性, 起址, 长度}。
"""
from pathlib import Path

V, L, T = 0, 1, 2
STRS = [
    # 标签块
    ("S_TVID", " VIDEO ", T), ("S_TPHO", " PHOTO ", T), ("S_TWALL", " WALL ", T), ("S_TSD", " SD ", T),
    ("S_TSET", " SETTINGS", T), ("S_TMUS", " MUSIC ", T),
    # 名称
    ("S_LRES", "RES ", L), ("S_LFPS", "FPS ", L), ("S_LTIME", "TIME ", L), ("S_LPIC", "PIC ", L),
    ("S_LSRC", "SRC ", L), ("S_LOUT", "OUT ", L), ("S_LGRP", "GROUP ", L),
    ("S_LWAV", "WAV", L), ("S_LTRK", "TRACK ", L),
    ("S_MMUS", "MUSIC", L), ("S_MVOL", "VOLUME", L), ("S_MTR", "TRANSITION", L), ("S_MPER", "PERIOD", L),
    ("S_MSPEC", "SPECTRUM", L), ("S_MINFO", "INFO", L), ("S_MOUT", "OUTPUT", L),
    ("S_HINT1", "K2 NEXT   K3 -   K4 +", L), ("S_HINT2", "HOLD:K2 PREV K3 RESET", L),
    # 数值
    ("S_RES", "640X480", V), ("S_RES2", "320X240", V), ("S_RES4", "160X120", V), ("S_332", "RGB332", V),
    ("S_565", "RGB565", V), ("S_ON", "ON", V), ("S_OFF", "OFF", V), ("S_X", "X", V), ("S_OF8", "/8", V),
    ("S_OF4", "/4", V), ("S_G1", "1/2", V), ("S_G2", "2/2", V), ("S_SEC", "S", V),
    ("S_NOCARD", "NO CARD", V), ("S_RELOAD", "RELOADING", V), ("S_NOFILE", "NO FILE", V),
    ("S_PLAY", "PLAY", V), ("S_PRAW", "PLAY-RAW", V), ("S_STOP", "STOP", V), ("S_NOWAV", "NO WAV", V),
    ("S_AUTO", "AUTO", V), ("S_FADE", "FADE", V), ("S_WIPE", "WIPE", V), ("S_CURT", "CURTAIN", V),
    ("S_PAUSE", "PAUSE", V), ("S_HSPK", "HDMI+SPK", V), ("S_SPK", "SPK ONLY", V),
    ("S_LT", "<", V), ("S_GT", ">", V), ("S_COLON", ":", V), ("S_SEP", " ", V), ("S_LMUS", "MUSIC ", L), ("S_VWAV", "WAV", V), ("S_SL", "/", V),
]

FONT = {
    "A": "01110100011000111111100011000110001", "B": "11110100011000111110100011000111110",
    "C": "01110100011000010000100001000101110", "D": "11110100011000110001100011000111110",
    "E": "11111100001000011110100001000011111", "F": "11111100001000011110100001000010000",
    "G": "01110100011000010111100011000101111", "H": "10001100011000111111100011000110001",
    "I": "01110001000010000100001000010001110", "J": "00111000100001000010100101001001100",
    "K": "10001100101010011000101001001010001", "L": "10000100001000010000100001000011111",
    "M": "10001110111010110101100011000110001", "N": "10001110011010110011100011000110001",
    "O": "01110100011000110001100011000101110", "P": "11110100011000111110100001000010000",
    "Q": "01110100011000110001101011001001101", "R": "11110100011000111110101001001010001",
    "S": "01111100001000001110000010000111110", "T": "11111001000010000100001000010000100",
    "U": "10001100011000110001100011000101110", "V": "10001100011000110001100010101000100",
    "W": "10001100011000110101101011010101010", "X": "10001100010101000100010101000110001",
    "Y": "10001100010101000100001000010000100", "Z": "11111000010001000100010001000011111",
    "0": "01110100011001110101110011000101110", "1": "00100011000010000100001000010001110",
    "2": "01110100010000100010001000100011111", "3": "11110000010000101110000010000111110",
    "4": "00010001100101010010111110001000010", "5": "11111100001000011110000010000111110",
    "6": "01110100001000011110100011000101110", "7": "11111000010001000100010000100001000",
    "8": "01110100011000101110100011000101110", "9": "01110100011000101111000010000101110",
    ":": "00000001000010000000001000010000000", ">": "10000010000010000010001000100010000",
    "-": "00000000000000011111000000000000000", "+": "00000001000010011111001000010000000",
    "<": "00010001000100010000010000010000010", "/": "00001000100001000100010001000010000",
}


def code(ch):
    if ch == " ":
        return 1
    if ch.isdigit():
        return 2 + int(ch)
    if ch.isalpha():
        return 12 + ord(ch) - ord("A")
    return {":": 38, ">": 39, "-": 40, "+": 41, "<": 42, "/": 43}[ch]


def main():
    out = []
    rom, starts = [], []
    for name, text, attr in STRS:
        starts.append((name, len(rom), len(text), attr))
        rom += [code(c) for c in text]
    assert len(STRS) <= 63 and len(rom) <= 512 and max(len(t) for _, t, _ in STRS) < 32
    out.append("// 字串号")
    for i, (name, _, _, _) in enumerate(starts, 1):
        out.append(f"localparam [5:0] {name} = 6'd{i};")
    out.append("// 字串号 -> {属性, 起址, 长度}")
    out.append("function [15:0] str_loc(input [5:0] sid);")
    out.append("    case (sid)")
    for i, (name, st, ln, at) in enumerate(starts, 1):
        out.append(f"    6'd{i}: str_loc = {{2'd{at}, 9'd{st}, 5'd{ln}}};")
    out.append("    default: str_loc = 16'd0;")
    out.append("    endcase")
    out.append("endfunction")
    out.append(f"// 字串 ROM({len(rom)} 字符)")
    out.append("function [5:0] str_rom(input [8:0] a);")
    out.append("    case (a)")
    for i, c in enumerate(rom):
        out.append(f"    9'd{i}: str_rom = 6'd{c};")
    out.append("    default: str_rom = 6'd0;")
    out.append("    endcase")
    out.append("endfunction")
    out.append("// 字模 ROM: {字符码, 行} -> 5 位行点阵(高位在左)")
    out.append("function [4:0] font_row(input [5:0] c, input [2:0] r);")
    out.append("    case ({c, r})")
    for ch, bits in FONT.items():
        cd = code(ch)
        for r in range(7):
            row = bits[5 * r:5 * r + 5]
            if row != "00000":
                out.append(f"    {{6'd{cd}, 3'd{r}}}: font_row = 5'b{row};")
    out.append("    default: font_row = 5'b00000;")
    out.append("    endcase")
    out.append("endfunction")
    p = Path(__file__).resolve().parents[1] / "rtl" / "t073_osd_rom.vh"
    p.write_text("\n".join(out) + "\n", encoding="utf-8", newline="\n")
    print("strings", len(STRS), "chars", len(rom))


if __name__ == "__main__":
    main()
