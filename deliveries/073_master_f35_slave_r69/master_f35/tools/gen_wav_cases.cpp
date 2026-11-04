// WAV 解析器对照用例生成(合法/各类畸形 RIFF 文件, 含随机字节扰动)。
// 输出 sim/wav_cases.txt: 每例 "C <file_size> <words>" 后跟 words 行 32 位大端字(首字节在最高位)。
// 期望值不在此计算: 由同一用例驱动参考实现与精简实现, 比较两者的样本序列与结局。
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <random>
#include <string>
#include <vector>

using u8 = uint8_t; using u32 = uint32_t;
static std::mt19937 rng(20261101);
static u32 rnd(u32 n) { return rng() % n; }
static void p16(std::vector<u8>& v, u32 x) { v.push_back(x); v.push_back(x >> 8); }
static void p32(std::vector<u8>& v, u32 x) { for (int i = 0; i < 4; i++) v.push_back(x >> (8 * i)); }
static void tag(std::vector<u8>& v, const char* t) { for (int i = 0; i < 4; i++) v.push_back(t[i]); }

struct Opt {
    int fmt_size = 16, ch = 1, rate = 48000, bits = 16, align = 2, fmt_tag = 1;
    u32 byterate = 96000;
    int nsamp = 37, list_before = 0, list_after = 0, list_size = 9, data_first = 0, dup_fmt = 0;
    int odd_data = 0, riff_delta = 0, trailer = 0, truncate = 0, file_extra = 0;
    const char* riff = "RIFF"; const char* wave = "WAVE";
};

static std::vector<u8> chunk_list(int n) {
    std::vector<u8> v; tag(v, "LIST"); p32(v, n);
    for (int i = 0; i < n; i++) v.push_back(rnd(256));
    if (n & 1) v.push_back(0);
    return v;
}
static std::vector<u8> chunk_fmt(const Opt& o) {
    std::vector<u8> v; tag(v, "fmt "); p32(v, o.fmt_size);
    std::vector<u8> b; p16(b, o.fmt_tag); p16(b, o.ch); p32(b, o.rate); p32(b, o.byterate); p16(b, o.align); p16(b, o.bits);
    while ((int)b.size() < o.fmt_size) b.push_back(rnd(256));
    b.resize(o.fmt_size);
    v.insert(v.end(), b.begin(), b.end());
    if (o.fmt_size & 1) v.push_back(0);
    return v;
}
static std::vector<u8> chunk_data(const Opt& o) {
    std::vector<u8> v; tag(v, "data");
    u32 n = o.nsamp * 2 + (o.odd_data ? 1 : 0);
    p32(v, n);
    for (u32 i = 0; i < n; i++) v.push_back(rnd(256));
    if (n & 1) v.push_back(0);
    return v;
}
static std::vector<u8> build(const Opt& o) {
    std::vector<u8> body;
    auto add = [&](const std::vector<u8>& c) { body.insert(body.end(), c.begin(), c.end()); };
    tag(body, o.wave);
    if (o.list_before) add(chunk_list(o.list_size));
    if (o.data_first) add(chunk_data(o));
    add(chunk_fmt(o));
    if (o.dup_fmt) add(chunk_fmt(o));
    if (o.list_after) add(chunk_list(o.list_size + 3));
    if (!o.data_first) add(chunk_data(o));
    if (o.trailer) add(chunk_list(5));
    std::vector<u8> f; tag(f, o.riff); p32(f, (u32)((int)body.size() + o.riff_delta));
    f.insert(f.end(), body.begin(), body.end());
    for (int i = 0; i < o.file_extra; i++) f.push_back(rnd(256));
    if (o.truncate && (int)f.size() > o.truncate) f.resize(f.size() - o.truncate);
    return f;
}

int main() {
    FILE* out = fopen("sim/wav_cases.txt", "w");
    if (!out) { perror("open"); return 1; }
    int ncase = 0;
    auto emit = [&](std::vector<u8> f, u32 fsize) {
        u32 nw = (fsize + 3) / 4 + 2;                          // 与读文件侧一致: 按目录长度取字, 尾补 2 个 0 字
        f.resize(nw * 4, 0);
        fprintf(out, "C %u %u\n", fsize, nw);
        for (u32 i = 0; i < nw; i++) fprintf(out, "%02x%02x%02x%02x\n", f[4 * i], f[4 * i + 1], f[4 * i + 2], f[4 * i + 3]);
        ncase++;
    };
    for (int k = 0; k < 400; k++) {
        Opt o;
        o.nsamp = rnd(60);
        o.list_before = rnd(4) == 0; o.list_after = rnd(4) == 0; o.list_size = 1 + rnd(20);
        o.trailer = rnd(3) == 0; o.file_extra = rnd(3) == 0 ? rnd(9) : 0;
        int kind = rnd(16);
        switch (kind) {
        case 0: o.fmt_size = 18; break;
        case 1: o.fmt_size = 17 + 2 * rnd(12); break;
        case 2: o.data_first = 1; break;
        case 3: o.odd_data = 1; break;
        case 4: o.rate = 44100; o.byterate = 88200; break;
        case 5: o.ch = 2; break;
        case 6: o.bits = 8; break;
        case 7: o.fmt_size = 14; break;
        case 8: o.dup_fmt = 1; break;
        case 9: o.riff = "RIFX"; break;
        case 10: o.wave = "WAVX"; break;
        case 11: o.riff_delta = (int)rnd(40) - 20; break;
        case 12: o.truncate = 1 + rnd(30); break;
        case 13: o.nsamp = 0; break;
        case 14: o.fmt_tag = 3; break;
        default: break;
        }
        std::vector<u8> f = build(o);
        u32 fsize = f.size();
        int fs = rnd(10);
        if (fs == 0) fsize = rnd(12);                          // 文件过短
        else if (fs == 1) fsize = fsize > 6 ? fsize - 1 - rnd(6) : fsize;   // 目录长度短于内容
        if (rnd(5) == 0 && f.size() > 8) {                     // 随机扰动头部 1 字节
            int pos = rnd(std::min<int>(f.size(), 80));
            f[pos] ^= 1u << rnd(8);
        }
        emit(f, fsize);
    }
    fprintf(out, "E 0 0\n");
    fclose(out);
    printf("wav cases %d\n", ncase);
    return 0;
}
