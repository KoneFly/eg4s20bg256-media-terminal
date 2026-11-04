// 仿真黄金/镜像生成器(WSL C++), 与 RTL 独立实现。
// 子命令:
//   bmp   <宽> <高> <topdown> <种子>        -> sim/bmp_in.hex, sim/bmp_expect.hex
//   video <fmt 1|2> <帧数> <fps> <音频块数> -> sim/vid_img.hex, sim/vid_expect.hex, sim/aud_expect.hex
// 规则与 scripts/make_bmp_case.py、scripts/make_video_image.py 逐项一致(二者保留为可读规格),
// 由 tools/check_golden.sh 交叉比对两套输出的 SHA256。
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
static void put64(std::vector<u8>& b, size_t o, u64 v) { for (int i = 0; i < 8; i++) b[o + i] = v >> (8 * i); }

static FILE* openw(const char* p) {
    FILE* f = fopen(p, "w");
    if (!f) { perror(p); exit(1); }
    setvbuf(f, nullptr, _IOFBF, 1 << 22);
    return f;
}
static void hex16(FILE* f, u16 v) { static const char* H = "0123456789abcdef";
    char s[6] = {H[v >> 12], H[(v >> 8) & 15], H[(v >> 4) & 15], H[v & 15], '\n', 0}; fwrite(s, 1, 5, f); }

// ---------------- BMP ----------------
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
    for (int k = 0; k < sh; k++) {                 // 文件第 k 行
        int y = td ? k : sh - 1 - k;
        u8* p = &d[54 + (size_t)stride * k];
        for (int x = 0; x < sw; x++) { u8 r, g, b; src_rgb(x, y, seed, r, g, b); p[3 * x] = b; p[3 * x + 1] = g; p[3 * x + 2] = r; }
    }
    return d;
}

// 显示顺序(0=顶行)的 640×480 期望帧
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

static int cmd_bmp(int sw, int sh, int td, int seed) {
    std::vector<u8> d = bmp_bytes(sw, sh, td, seed);
    d.resize(d.size() + ((4 - d.size() % 4) % 4) + 8, 0);
    FILE* f = openw("sim/bmp_in.hex");
    for (size_t i = 0; i < d.size(); i += 4) fprintf(f, "%02x%02x%02x%02x\n", d[i], d[i + 1], d[i + 2], d[i + 3]);
    fclose(f);
    std::vector<u16> e = bmp_expect(sw, sh, td, seed);
    f = openw("sim/bmp_expect.hex");
    for (u16 v : e) hex16(f, v);
    fclose(f);
    int win, xo, cw, ch, lft, top; geom(sw, sh, win, xo, cw, ch, lft, top);
    printf("%dx%d td=%d words=%zu geom cw=%d ch=%d lft=%d top=%d\n", sw, sh, td, d.size() / 4, cw, ch, lft, top);
    return 0;
}

// ---------------- FAT32 ----------------
struct FatImg {
    std::map<u32, std::vector<u8>> blk;
    std::map<u32, u32> fat = {{0, 0x0FFFFFF8}, {1, 0x0FFFFFFF}, {2, 0x0FFFFFFF}};
    int nent = 0;
    std::vector<u8>& b(u32 l) { auto& v = blk[l]; if (v.empty()) v.assign(512, 0); return v; }
};
static const u32 PART = 2048, SPC = 8, RSVD = 32, NFATS = 2, FATSZ = 1024;
static const u32 FAT_LBA = PART + RSVD, DATA_LBA = FAT_LBA + NFATS * FATSZ;
static u32 clus_lba(u32 c) { return DATA_LBA + (c - 2) * SPC; }

static u32 vsrc(int fmt, int f, int x, int y) {
    int v = (x * 7 + y * 13 + f * 101) ^ (x >> 3) ^ (y << 2);
    return (u32)(v ^ (v >> 9)) & (fmt == 1 ? 0xFFFF : 0xFF);
}
static u16 x332(u32 c) {
    u32 r3 = c >> 5, g3 = (c >> 2) & 7, b2 = c & 3;
    return (u16)((((r3 << 2) | (r3 >> 1)) << 11) | (((g3 << 3) | g3) << 5) | ((b2 << 3) | (b2 << 1) | (b2 >> 1)));
}

static int cmd_video(int fmt, int nfr, int fps, int ab) {
    const u64 RN = 25200000ULL * 25, RD = 13104;
    u32 fbytes = DW * DH * (fmt == 1 ? 2 : 1);
    std::vector<u8> data(512, 0);
    memcpy(&data[0], "T29V", 4);
    put16(data, 4, ab ? 2 : 1); put16(data, 6, 512); put16(data, 8, DW); put16(data, 10, DH);
    data[12] = fmt; data[13] = ab; put16(data, 14, 0); put32(data, 16, fps); put32(data, 20, 1);
    put32(data, 24, fbytes); put32(data, 28, nfr); put32(data, 32, 0); put32(data, 36, 0xFFFFFFFF);
    put64(data, 40, 0); put32(data, 48, 7);
    FILE* fe = openw("sim/vid_expect.hex");
    FILE* fa = openw("sim/aud_expect.hex");
    u64 sidx = 0; bool any_aud = false;
    for (int f = 0; f < nfr; f++) {
        for (int y = 0; y < DH; y++) for (int x = 0; x < DW; x++) {
            u32 p = vsrc(fmt, f, x, y);
            if (fmt == 1) { data.push_back(p); data.push_back(p >> 8); hex16(fe, p); }
            else { data.push_back(p); hex16(fe, x332(p)); }
        }
        if (ab) {
            u64 n = (u64)(f + 1) * RN / (RD * fps) - sidx;
            size_t o = data.size(); data.resize(o + 512 * ab, 0); put32(data, o, (u32)n);
            for (u64 i = 0; i < n; i++) { u16 v = (u16)(((sidx + i) * 2654435761ULL) >> 7); put16(data, o + 4 + 2 * i, v); hex16(fa, v); }
            sidx += n; any_aud = true;
        }
    }
    if (!any_aud) fputs("0000\n", fa);
    fclose(fe); fclose(fa);

    u32 size = data.size();
    u32 ncl = (size + SPC * 512 - 1) / (SPC * 512), a = ncl / 3, b = ncl / 3;
    std::vector<u32> cl;
    for (u32 i = 0; i < a; i++) cl.push_back(200 + i);
    for (u32 i = 0; i < b; i++) cl.push_back(4000 + i);
    for (u32 i = 0; i < ncl - a - b; i++) cl.push_back(9000 + i);
    std::map<u32, std::vector<u8>> blk;
    auto blkref = [&](u32 l) -> std::vector<u8>& { auto& v = blk[l]; if (v.empty()) v.assign(512, 0); return v; };
    { auto& m = blkref(0); m[446 + 4] = 0x0C; put32(m, 446 + 8, PART); m[510] = 0x55; m[511] = 0xAA; }
    { auto& p = blkref(PART); p[0] = 0xEB; p[1] = 0x58; p[2] = 0x90; put16(p, 11, 512); p[13] = SPC;
      put16(p, 14, RSVD); p[16] = NFATS; put32(p, 36, FATSZ); put32(p, 44, 2); p[510] = 0x55; p[511] = 0xAA; }
    { auto& e = blkref(clus_lba(2)); memcpy(&e[0], "VID00000V29", 11); e[11] = 0x20;
      put16(e, 20, cl[0] >> 16); put16(e, 26, cl[0] & 0xFFFF); put32(e, 28, size); }
    std::map<u32, u32> fat = {{0, 0x0FFFFFF8}, {1, 0x0FFFFFFF}, {2, 0x0FFFFFFF}};
    for (size_t i = 0; i < cl.size(); i++) {
        fat[cl[i]] = (i + 1 < cl.size()) ? cl[i + 1] : 0x0FFFFFFF;
        for (u32 s = 0; s < SPC; s++) {
            size_t off = (i * SPC + s) * 512;
            if (off >= size) continue;
            bool nz = false; size_t e = std::min<size_t>(off + 512, size);
            for (size_t k = off; k < e; k++) if (data[k]) { nz = true; break; }
            if (!nz) continue;
            auto& v = blkref(clus_lba(cl[i]) + s); memcpy(&v[0], &data[off], e - off);
        }
    }
    for (auto& kv : fat) for (u32 c = 0; c < NFATS; c++) put32(blkref(FAT_LBA + c * FATSZ + kv.first / 128), (kv.first % 128) * 4, kv.second);
    FILE* fi = openw("sim/vid_img.hex");
    static const char* H = "0123456789abcdef";
    std::vector<char> line(8 + 1 + 1024 + 1);
    for (auto& kv : blk) {
        snprintf(line.data(), 10, "%08x ", kv.first);
        for (int i = 0; i < 512; i++) { line[9 + 2 * i] = H[kv.second[i] >> 4]; line[10 + 2 * i] = H[kv.second[i] & 15]; }
        line[9 + 1024] = '\n';
        fwrite(line.data(), 1, 9 + 1024 + 1, fi);
    }
    fclose(fi);
    printf("fmt %d frames %d A %d samples %llu size %u blocks %zu\n", fmt, nfr, ab, (unsigned long long)sidx, size, blk.size());
    return 0;
}

// 轮播镜像: PIC1..PICn.BMP(尺寸/行序各异), 每个文件簇链拆成两段不连续 extent。
// 输出 sim/vid_img.hex(块镜像, 卡模型 +img 载入) 与 sim/slide_expect.hex(各图期望帧依序拼接)。
static int cmd_slides() {
    struct Pic { int w, h, td; };
    const Pic pics[] = {{800, 600, 0}, {320, 240, 1}, {1024, 576, 0}};
    const int npic = 3;
    FatImg fi;
    { auto& m = fi.b(0); m[446 + 4] = 0x0C; put32(m, 446 + 8, PART); m[510] = 0x55; m[511] = 0xAA; }
    { auto& p = fi.b(PART); p[0] = 0xEB; p[1] = 0x58; p[2] = 0x90; put16(p, 11, 512); p[13] = SPC;
      put16(p, 14, RSVD); p[16] = NFATS; put32(p, 36, FATSZ); put32(p, 44, 2); p[510] = 0x55; p[511] = 0xAA; }
    FILE* fe = openw("sim/slide_expect.hex");
    u32 next_cl = 100;
    for (int i = 0; i < npic; i++) {
        std::vector<u8> d = bmp_bytes(pics[i].w, pics[i].h, pics[i].td, i + 1);
        u32 size = d.size();
        u32 ncl = (size + SPC * 512 - 1) / (SPC * 512), h1 = ncl / 2;
        std::vector<u32> cl;
        for (u32 k = 0; k < h1; k++) cl.push_back(next_cl + k);
        for (u32 k = h1; k < ncl; k++) cl.push_back(next_cl + 50 + k);        // 中间留 50 簇空洞
        next_cl += 50 + ncl + 20;
        for (size_t k = 0; k < cl.size(); k++) {
            fi.fat[cl[k]] = (k + 1 < cl.size()) ? cl[k + 1] : 0x0FFFFFFF;
            for (u32 s = 0; s < SPC; s++) {
                size_t off = (k * SPC + s) * 512;
                if (off >= size) continue;
                size_t e = std::min<size_t>(off + 512, size);
                memcpy(&fi.b(clus_lba(cl[k]) + s)[0], &d[off], e - off);
            }
        }
        auto& de = fi.b(clus_lba(2));
        u8* ent = &de[32 * i];
        char nm[12]; snprintf(nm, sizeof nm, "PIC%d    BMP", i + 1);
        memcpy(ent, nm, 11); ent[11] = 0x20;
        ent[20] = (cl[0] >> 16) & 0xFF; ent[21] = cl[0] >> 24; ent[26] = cl[0] & 0xFF; ent[27] = (cl[0] >> 8) & 0xFF;
        for (int b = 0; b < 4; b++) ent[28 + b] = size >> (8 * b);
        std::vector<u16> ex = bmp_expect(pics[i].w, pics[i].h, pics[i].td, i + 1);
        for (u16 v : ex) hex16(fe, v);
    }
    fclose(fe);
    for (auto& kv : fi.fat) for (u32 c = 0; c < NFATS; c++) put32(fi.b(FAT_LBA + c * FATSZ + kv.first / 128), (kv.first % 128) * 4, kv.second);
    FILE* f = openw("sim/vid_img.hex");
    static const char* H = "0123456789abcdef";
    std::vector<char> line(9 + 1024 + 1);
    for (auto& kv : fi.blk) {
        snprintf(line.data(), 10, "%08x ", kv.first);
        for (int k = 0; k < 512; k++) { line[9 + 2 * k] = H[kv.second[k] >> 4]; line[10 + 2 * k] = H[kv.second[k] & 15]; }
        line[9 + 1024] = '\n';
        fwrite(line.data(), 1, line.size(), f);
    }
    fclose(f);
    printf("slides %d blocks %zu\n", npic, fi.blk.size());
    return 0;
}

int main(int argc, char** argv) {
    if (argc >= 6 && !strcmp(argv[1], "bmp"))   return cmd_bmp(atoi(argv[2]), atoi(argv[3]), atoi(argv[4]), atoi(argv[5]));
    if (argc >= 6 && !strcmp(argv[1], "video")) return cmd_video(atoi(argv[2]), atoi(argv[3]), atoi(argv[4]), atoi(argv[5]));
    if (argc >= 2 && !strcmp(argv[1], "slides")) return cmd_slides();
    fprintf(stderr, "usage: gen_golden bmp W H TD SEED | video FMT NFR FPS AB | slides\n");
    return 2;
}
