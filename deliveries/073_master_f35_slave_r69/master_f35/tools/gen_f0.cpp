// F0 系统仿真镜像与独立黄金(与 RTL 无关的闭式定义, 规则同 T071 gen_golden):
//   FAT32 卡镜像含 PIC1..3.BMP(尺寸/行序各异)、VID00000/VID00002.V29(RGB332, 帧交织伴音;
//   VID00001 缺号用于检验跳号)、WAV1/WAV3.WAV(WAV2 缺号)。
// 输出(均在 sim/):
//   f0_img.hex    卡模型 +img 块镜像("LBA 512字节hex", 只含非零块)
//   f0_hash.txt   每行 "<名> <64位FNV-1a> <标签>": P1..P3(1..3) 各图期望帧, V0..V3(10..13) 视频帧,
//                 U0..U3(40..43) 第二个视频的帧, B1..B3(51..53) 各图的播放器页期望帧,
//                 K0(0) 黑帧, Z2P2/Z4P2(22/24) PIC2 的 ÷2/÷4, W0F1..W1F8(31..38) 图墙(焦点槽 1..8)
//   f0_vaud.hex   视频伴音样本(文件顺序, 循环播放时按模回绕)
//   f0_wav.hex    WAV1 样本
//   f0_pics.hex   PIC1..3 期望帧依序拼接(转场中间帧逐像素核对用)
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>

using u8 = uint8_t; using u16 = uint16_t; using u32 = uint32_t; using u64 = uint64_t;
static const int DW = 640, DH = 480;
static void put16(std::vector<u8>& b, size_t o, u16 v) { b[o] = v; b[o + 1] = v >> 8; }
static void put32(std::vector<u8>& b, size_t o, u32 v) { for (int i = 0; i < 4; i++) b[o + i] = v >> (8 * i); }
static FILE* openw(const char* p) { FILE* f = fopen(p, "w"); if (!f) { perror(p); exit(1); } setvbuf(f, nullptr, _IOFBF, 1 << 22); return f; }
static u64 fnv(const std::vector<u16>& px) {
    u64 h = 0xcbf29ce484222325ULL;
    for (u16 v : px) { h ^= v; h *= 0x100000001b3ULL; }
    return h;
}

// ---- BMP(与 T071 gen_golden bmp 相同) ----
static void geom(int sw, int sh, int& win, int& xo, int& cw, int& ch, int& lft, int& top) {
    if (4LL * sh < 3LL * sw) { win = std::min(sw * 100 / 106, sw); xo = (sw - win) / 2; cw = DW; ch = std::min(DW * sh / win, DH); }
    else if (4LL * sh == 3LL * sw) { win = sw; xo = 0; cw = DW; ch = std::min(DW * sh / sw, DH); }
    else { win = sw; xo = 0; ch = DH; cw = std::min(DH * sw / sh, DW); }
    lft = (DW - cw) / 2; top = (DH - ch) / 2;
}
static void src_rgb(int x, int y, int seed, u8& r, u8& g, u8& b) {
    u32 h = (u32)(x * 40503u + y * 9973u + seed * 7919u + 0x5A5Au);
    h ^= h >> 7; r = h >> 16; g = h >> 8; b = h;
}
static u16 to565(u8 r, u8 g, u8 b) { return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3); }
static std::vector<u8> bmp_bytes(int sw, int sh, int td, int seed) {
    int stride = (sw * 3 + 3) & ~3;
    std::vector<u8> d(54 + (size_t)stride * sh, 0);
    d[0] = 'B'; d[1] = 'M';
    put32(d, 2, d.size()); put32(d, 10, 54); put32(d, 14, 40);
    put32(d, 18, sw); put32(d, 22, td ? (u32)(-sh) : (u32)sh);
    put16(d, 26, 1); put16(d, 28, 24); put32(d, 34, (u32)stride * sh); put32(d, 38, 2835); put32(d, 42, 2835);
    for (int k = 0; k < sh; k++) {
        int y = td ? k : sh - 1 - k;
        u8* p = &d[54 + (size_t)stride * k];
        for (int x = 0; x < sw; x++) { u8 r, g, b; src_rgb(x, y, seed, r, g, b); p[3 * x] = b; p[3 * x + 1] = g; p[3 * x + 2] = r; }
    }
    return d;
}
static std::vector<u16> bmp_expect(int sw, int sh, int td, int seed) {
    int win, xo, cw, ch, lft, top; geom(sw, sh, win, xo, cw, ch, lft, top);
    std::vector<int> sx(cw);
    for (int t = 0; t < cw; t++) sx[t] = (int)(((long long)(t + 1) * win + cw - 1) / cw - 1 + xo);
    std::vector<u16> byr((size_t)DW * DH, 0);
    for (int r = top; r < top + ch; r++) {
        int c = r - top;
        int k = (int)(((long long)(c + 1) * sh + ch - 1) / ch - 1);
        int vy = td ? k : sh - 1 - k;
        for (int t = 0; t < cw; t++) { u8 R, G, B; src_rgb(sx[t], vy, seed, R, G, B); byr[(size_t)r * DW + lft + t] = to565(R, G, B); }
    }
    std::vector<u16> out((size_t)DW * DH);
    for (int dr = 0; dr < DH; dr++) { int r = td ? dr : DH - 1 - dr; memcpy(&out[(size_t)dr * DW], &byr[(size_t)r * DW], DW * 2); }
    return out;
}

// ---- V29(与 T071 gen_golden video 相同) ----
static u32 vsrc(int f, int x, int y) { int v = (x * 7 + y * 13 + f * 101) ^ (x >> 3) ^ (y << 2); return (u32)(v ^ (v >> 9)) & 0xFF; }
static u16 x332(u32 c) {
    u32 r3 = c >> 5, g3 = (c >> 2) & 7, b2 = c & 3;
    return (u16)((((r3 << 2) | (r3 >> 1)) << 11) | (((g3 << 3) | g3) << 5) | ((b2 << 3) | (b2 << 1) | (b2 >> 1)));
}

// ---- FAT32 ----
static const u32 PART = 2048, SPC = 8, RSVD = 32, NFATS = 2, FATSZ = 1024;
static const u32 FAT_LBA = PART + RSVD, DATA_LBA = FAT_LBA + NFATS * FATSZ;
static u32 clus_lba(u32 c) { return DATA_LBA + (c - 2) * SPC; }
static std::map<u32, std::vector<u8>> blk;
static std::map<u32, u32> fat = {{0, 0x0FFFFFF8}, {1, 0x0FFFFFFF}, {2, 0x0FFFFFFF}};
static std::vector<u8>& b(u32 l) { auto& v = blk[l]; if (v.empty()) v.assign(512, 0); return v; }
static u32 next_cl = 100;
static int nent = 0;
// 文件簇链拆成两段不连续 extent
static void add_file(const char* name83, const std::vector<u8>& d) {
    u32 size = d.size(), ncl = (size + SPC * 512 - 1) / (SPC * 512), h1 = ncl / 2;
    std::vector<u32> cl;
    for (u32 k = 0; k < h1; k++) cl.push_back(next_cl + k);
    for (u32 k = h1; k < ncl; k++) cl.push_back(next_cl + 37 + k);
    next_cl += 37 + ncl + 11;
    for (size_t k = 0; k < cl.size(); k++) {
        fat[cl[k]] = (k + 1 < cl.size()) ? cl[k + 1] : 0x0FFFFFFF;
        for (u32 s = 0; s < SPC; s++) {
            size_t off = (k * SPC + s) * 512;
            if (off >= size) continue;
            size_t e = std::min<size_t>(off + 512, size);
            bool nz = false; for (size_t q = off; q < e; q++) if (d[q]) { nz = true; break; }
            if (nz) memcpy(&b(clus_lba(cl[k]) + s)[0], &d[off], e - off);
        }
    }
    u8* ent = &b(clus_lba(2))[32 * nent++];
    memcpy(ent, name83, 11); ent[11] = 0x20;
    ent[20] = (cl[0] >> 16) & 0xFF; ent[21] = cl[0] >> 24; ent[26] = cl[0] & 0xFF; ent[27] = (cl[0] >> 8) & 0xFF;
    for (int q = 0; q < 4; q++) ent[28 + q] = size >> (8 * q);
}

int main() {
    { auto& m = b(0); m[446 + 4] = 0x0C; put32(m, 446 + 8, PART); m[510] = 0x55; m[511] = 0xAA; }
    { auto& p = b(PART); p[0] = 0xEB; p[1] = 0x58; p[2] = 0x90; put16(p, 11, 512); p[13] = SPC;
      put16(p, 14, RSVD); p[16] = NFATS; put32(p, 36, FATSZ); put32(p, 44, 2); p[510] = 0x55; p[511] = 0xAA; }
    FILE* fh = openw("sim/f0_hash.txt");
    FILE* fp = openw("sim/f0_pics.hex");
    struct Pic { int w, h, td; };
    const Pic pics[] = {{320, 240, 1}, {200, 150, 0}, {640, 480, 0}};
    std::vector<std::vector<u16>> full;
    for (int i = 0; i < 3; i++) {
        char nm[12]; snprintf(nm, sizeof nm, "PIC%d    BMP", i + 1);
        add_file(nm, bmp_bytes(pics[i].w, pics[i].h, pics[i].td, i + 1));
        std::vector<u16> ex = bmp_expect(pics[i].w, pics[i].h, pics[i].td, i + 1);
        fprintf(fh, "P%d %016llx %d\n", i + 1, (unsigned long long)fnv(ex), i + 1);
        full.push_back(ex);
        for (u16 q : ex) fprintf(fp, "%04x\n", q);
    }
    // 视频: RGB332 4 帧 30fps, 每帧 7 个音频块; 第二个视频帧号偏移 50(内容不同)
    auto make_vid = [&](int foff, int label0, const char* afn, const char* name) {
        const int NFR = 4, FPS = 30, AB = 7;
        const u64 RN = 25200000ULL * 25, RD = 13104;
        std::vector<u8> v(512, 0);
        memcpy(&v[0], "T29V", 4);
        put16(v, 4, 2); put16(v, 6, 512); put16(v, 8, DW); put16(v, 10, DH);
        v[12] = 2; v[13] = AB; put32(v, 16, FPS); put32(v, 20, 1);
        put32(v, 24, DW * DH); put32(v, 28, NFR); put32(v, 36, 0xFFFFFFFF); put32(v, 48, 7);
        FILE* fa = openw(afn);
        u64 sidx = 0;
        for (int f = 0; f < NFR; f++) {
            std::vector<u16> ex;
            for (int y = 0; y < DH; y++) for (int x = 0; x < DW; x++) { u32 q = vsrc(f + foff, x, y); v.push_back(q); ex.push_back(x332(q)); }
            fprintf(fh, "%c%d %016llx %d\n", foff ? 'U' : 'V', f, (unsigned long long)fnv(ex), label0 + f);
            u64 n = (u64)(f + 1) * RN / (RD * FPS) - sidx;
            size_t o = v.size(); v.resize(o + 512 * AB, 0); put32(v, o, (u32)n);
            for (u64 i = 0; i < n; i++) { u16 sm = (u16)(((sidx + i + foff * 7777) * 2654435761ULL) >> 7); put16(v, o + 4 + 2 * i, sm); fprintf(fa, "%04x\n", sm); }
            sidx += n;
        }
        fclose(fa);
        add_file(name, v);
    };
    // 启动动画 BOOT.V29: RGB565、无伴音、3 帧; 末帧与 PIC1 期望帧逐像素相同(标签 60/61, 末帧即 P1)
    {
        const int NB = 3;
        std::vector<u8> v(512, 0);
        memcpy(&v[0], "T29V", 4);
        put16(v, 4, 1); put16(v, 6, 512); put16(v, 8, DW); put16(v, 10, DH);
        v[12] = 1; v[13] = 0; put32(v, 16, 30); put32(v, 20, 1);
        put32(v, 24, DW * DH * 2); put32(v, 28, NB); put32(v, 36, 0xFFFFFFFF); put32(v, 48, 7);
        for (int f = 0; f < NB; f++) {
            std::vector<u16> ex((size_t)DW * DH);
            for (int y = 0; y < DH; y++) for (int x = 0; x < DW; x++)
                ex[(size_t)y * DW + x] = (f == NB - 1) ? full[0][(size_t)y * DW + x] : (u16)(x * 31 + y * 17 + f * 999);
            for (u16 q : ex) { v.push_back(q & 0xFF); v.push_back(q >> 8); }
            if (f < NB - 1) fprintf(fh, "BT%d %016llx %d\n", f, (unsigned long long)fnv(ex), 60 + f);
        }
        add_file("BOOT    V29", v);
    }
    make_vid(0, 10, "sim/f0_vaud.hex", "VID00000V29");
    make_vid(50, 40, "sim/f0_vaud2.hex", "VID00002V29");
    fclose(fp);
    // WAV1/WAV3: PCM16 单声道 48000Hz, 各 0.75s(大于音频缓冲 170ms, 跨过若干次换图)
    const int NW = 36000;
    std::vector<u8> w(44 + 2 * NW, 0);
    memcpy(&w[0], "RIFF", 4); put32(w, 4, 36 + 2 * NW); memcpy(&w[8], "WAVEfmt ", 8);
    put32(w, 16, 16); put16(w, 20, 1); put16(w, 22, 1); put32(w, 24, 48000); put32(w, 28, 96000);
    put16(w, 32, 2); put16(w, 34, 16); memcpy(&w[36], "data", 4); put32(w, 40, 2 * NW);
    FILE* fw = openw("sim/f0_wav.hex");
    for (int i = 0; i < NW; i++) { u16 s = (u16)((i * 40503u + 0x1234u) ^ (i << 5)); if (!s) s = 1; put16(w, 44 + 2 * i, s); fprintf(fw, "%04x\n", s); }
    fclose(fw);
    add_file("WAV1    WAV", w);
    {
        std::vector<u8> w3 = w;
        FILE* f3 = openw("sim/f0_wav3.hex");
        for (int i = 0; i < NW; i++) { u16 sm = (u16)((i * 2246822519u + 0x5A5Au) >> 9); if (!sm) sm = 1; put16(w3, 44 + 2 * i, sm); fprintf(f3, "%04x\n", sm); }
        fclose(f3);
        add_file("WAV3    WAV", w3);
    }
    std::vector<u16> black((size_t)DW * DH, 0);
    fprintf(fh, "K0 %016llx 0\n", (unsigned long long)fnv(black));
    // 播放器页: 封面窗口 (24..343, 96..335) 为该图缩略(全屏帧偶数行偶数列);
    //   窗口外为该图 ÷4 块状再各通道减半(虚化背景)
    for (int i = 0; i < 3; i++) {
        std::vector<u16> pl((size_t)DW * DH);
        for (int y = 0; y < DH; y++) for (int x = 0; x < DW; x++) {
            u16 q;
            if (x >= 24 && x < 344 && y >= 96 && y < 336) q = full[i][(size_t)(2 * (y - 96)) * DW + 2 * (x - 24)];
            else {
                u16 b = full[i][(size_t)((y >> 2) << 2) * DW + ((x >> 2) << 2)];
                q = (u16)((((b >> 11) & 31) >> 1) << 11 | (((b >> 5) & 63) >> 1) << 5 | ((b & 31) >> 1));
            }
            pl[(size_t)y * DW + x] = q;
        }
        fprintf(fh, "B%d %016llx %d\n", i + 1, (unsigned long long)fnv(pl), 51 + i);
    }
    // 三级缩放(块状): 像素 (x,y) 取源 ((x>>b)<<b, (y>>b)<<b)
    for (int b = 1; b <= 2; b++) {
        std::vector<u16> z((size_t)DW * DH);
        for (int y = 0; y < DH; y++) for (int x = 0; x < DW; x++)
            z[(size_t)y * DW + x] = full[1][(size_t)((y >> b) << b) * DW + ((x >> b) << b)];
        fprintf(fh, "Z%dP2 %016llx %d\n", 1 << b, (unsigned long long)fnv(z), 20 + (1 << b));
        // PIC1 的缩放(标签 21/23 = ÷2/÷4)
        for (int y = 0; y < DH; y++) for (int x = 0; x < DW; x++)
            z[(size_t)y * DW + x] = full[0][(size_t)((y >> b) << b) * DW + ((x >> b) << b)];
        fprintf(fh, "Z%dP1 %016llx %d\n", 1 << b, (unsigned long long)fnv(z), 19 + (1 << b));
    }
    // 图墙: 槽 s(0..7) 在组 s>>2, 格 (s&1, (s>>1)&1), 缩略 = 全屏帧偶数行偶数列; 缺图为黑
    //       焦点格外缘 4 像素黄框(0xFFE0)
    for (int f = 0; f < 8; f++) {
        int g = f >> 2;
        std::vector<u16> w((size_t)DW * DH, 0);
        for (int y = 0; y < DH; y++) for (int x = 0; x < DW; x++) {
            int s = g * 4 + (y >= 240) * 2 + (x >= 320);
            if (s < 3) w[(size_t)y * DW + x] = full[s][(size_t)(2 * (y % 240)) * DW + 2 * (x % 320)];
            int fx = (f & 1) * 320, fy = ((f >> 1) & 1) * 240, dx = x - fx, dy = y - fy;
            if (dx >= 0 && dx < 320 && dy >= 0 && dy < 240 && (dx < 4 || dx >= 316 || dy < 4 || dy >= 236))
                w[(size_t)y * DW + x] = 0xFFE0;
        }
        fprintf(fh, "W%dF%d %016llx %d\n", g, f + 1, (unsigned long long)fnv(w), 31 + f);
    }
    fclose(fh);
    for (auto& kv : fat) for (u32 c = 0; c < NFATS; c++) put32(b(FAT_LBA + c * FATSZ + kv.first / 128), (kv.first % 128) * 4, kv.second);
    FILE* fi = openw("sim/f0_img.hex");
    static const char* H = "0123456789abcdef";
    std::vector<char> line(9 + 1024 + 1);
    for (auto& kv : blk) {
        snprintf(line.data(), 10, "%08x ", kv.first);
        for (int k = 0; k < 512; k++) { line[9 + 2 * k] = H[kv.second[k] >> 4]; line[10 + 2 * k] = H[kv.second[k] & 15]; }
        line[9 + 1024] = '\n';
        fwrite(line.data(), 1, line.size(), fi);
    }
    fclose(fi);
    printf("f0 image blocks %zu wav %d\n", blk.size(), NW);
    return 0;
}
