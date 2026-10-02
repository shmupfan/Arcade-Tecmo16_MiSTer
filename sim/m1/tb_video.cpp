// M1 frame-replay harness for t16_video (Verilator, C++).
//
// For each frame file in the list: with the pixel enable stopped at the
// start of line 240 (vblank), write the palette, the tile RAMs and the live
// sprite RAM through the CPU ports, set the scroll and flip registers, copy
// the sprite list twice (so the renderer's buffer holds the dumped list),
// then run one whole frame (V_TOTAL lines of 384 pixels) and capture every
// o_de pixel. Mid-scan writes listed in the file are applied through the CPU
// ports when the beam reaches their (line, hcnt).
//
// Frame file (.t16f, written by sim/m1/replay.py), little-endian numbers:
//   "T16F", machine u8 (0 fstarfrc, 1 riot, 2 ginkun), flags u8 (bit 0:
//   text y has been written), nwrites u32,
//   regs u16 x 6 (text x, text y raw, fg x, fg y, bg x, bg y), flip u8, pad u8,
//   palette 8192 bytes, text 4096, fg codes 4096, fg colours 4096, bg codes
//   4096, bg colours 4096, sprite list 4096 (16-bit words, high byte first);
//   then nwrites x {line u16, hcnt u16, target u8, pad u8, addr u16,
//   data u16, mask u16}; target 0 palette, 1 text, 2 fg codes, 3 fg
//   colours, 4 bg codes, 5 bg colours, 8-13 scroll register 0-5, 16 flip.
// Output (.rgb): 256 x 224 x 3 bytes.
//
// Plusargs: +sdram=FILE +list=FILE (lines "in out"); ROM model: pipelined,
// in order, one request accepted every +intv=N clocks (default 8), data
// +lat=N clocks after acceptance (default 9): the Dooyong M1 pessimistic port.

#include "Vt16_video.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <memory>
#include <string>
#include <vector>
#include <unistd.h>

#ifndef VTOTAL
#define VTOTAL 264
#endif

static std::unique_ptr<Vt16_video> top;
static std::vector<uint8_t> sdram;
static int lat = 9, intv = 8;
static bool dbg = false;
static uint64_t cycles = 0, last_acc = 0;
struct Resp { uint64_t t; uint32_t d; };
static std::deque<Resp> rq;

static uint32_t rd32(uint32_t a) {
    uint32_t v = 0;
    for (int i = 0; i < 4; i++) v = (v << 8) | (a + i < sdram.size() ? sdram[a + i] : 0);
    return v;
}

static void tick(bool ce) {
    top->ce_pix = ce;
    bool rv = !rq.empty() && rq.front().t <= cycles;
    top->i_rom_rv = rv;
    if (rv) { top->i_rom_data = rq.front().d; rq.pop_front(); }
    bool gnt = cycles - last_acc >= (uint64_t)intv;
    top->i_rom_gnt = gnt;
    top->clk = 0; top->eval();
    if (gnt && top->o_rom_req) {
        rq.push_back({cycles + (uint64_t)lat, rd32(top->o_rom_addr)});
        last_acc = cycles;
    }
    top->clk = 1; top->eval();
    cycles++;
}

// one pixel: 15 clocks, then the clock with the pixel enable
static void run_pixel() {
    for (int i = 0; i < 15; i++) tick(false);
    tick(true);
}

static std::string plus(const char *name, const char *def) {
    const char *v = Verilated::commandArgsPlusMatch(name);
    if (!v || !*v) return def;
    const char *eq = strchr(v, '=');
    return eq ? std::string(eq + 1) : std::string(def);
}

static void clear_we() {
    top->i_pal_we = top->i_char_we = top->i_fgv_we = top->i_fgc_we = 0;
    top->i_bgv_we = top->i_bgc_we = top->i_spr_we = 0;
    top->i_reg_we = top->i_flip_we = 0;
}

// one CPU-port write; target as in the file format, 7 = sprite RAM
static void wr1(int target, int a, uint16_t d, uint16_t mask) {
    while (top->o_hold) tick(false);
    top->i_cpu_addr = a; top->i_cpu_din = d;
    top->i_cpu_be = ((mask & 0xFF00) ? 2 : 0) | ((mask & 0x00FF) ? 1 : 0);
    switch (target) {
        case 0: top->i_pal_we = 1; break;
        case 1: top->i_char_we = 1; break;
        case 2: top->i_fgv_we = 1; break;
        case 3: top->i_fgc_we = 1; break;
        case 4: top->i_bgv_we = 1; break;
        case 5: top->i_bgc_we = 1; break;
        case 7: top->i_spr_we = 1; break;
        case 16: top->i_flip_we = 1; break;
        default:
            if (target >= 8 && target <= 13) { top->i_reg_we = 1; top->i_reg_sel = target - 8; }
    }
    tick(false);
    clear_we();
}

static void wrblk(int target, const uint8_t *p, int nbytes) {
    for (int a = 0; a < nbytes; a += 2) wr1(target, a / 2, (p[a] << 8) | p[a + 1], 0xFFFF);
}

static void wait_idle() { while (top->o_busy || top->o_hold) tick(false); }

static uint16_t le16(const uint8_t *p) { return p[0] | (p[1] << 8); }
static uint32_t le32(const uint8_t *p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24); }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    top = std::make_unique<Vt16_video>();
    std::string sd = plus("sdram", ""), list = plus("list", "");
    lat = atoi(plus("lat", "9").c_str());
    intv = atoi(plus("intv", "8").c_str());
    dbg = plus("dbg", "0") == "1";
    last_acc = (uint64_t)-1000;
    {
        std::ifstream f(sd, std::ios::binary);
        if (!f) { fprintf(stderr, "cannot open sdram %s\n", sd.c_str()); return 2; }
        sdram.assign(std::istreambuf_iterator<char>(f), {});
    }
    std::vector<std::pair<std::string, std::string>> frames;
    {
        std::ifstream f(list);
        std::string a, b;
        while (f >> a >> b) frames.push_back({a, b});
    }
    if (frames.empty()) { fprintf(stderr, "empty list\n"); return 2; }

    const size_t HDR = 4 + 2 + 4 + 12 + 2, RAMS = 8192 + 6 * 4096;
    std::vector<uint8_t> fb;
    auto load = [&](const std::string &p) {
        std::ifstream f(p, std::ios::binary);
        fb.assign(std::istreambuf_iterator<char>(f), {});
        return fb.size() >= HDR + RAMS && memcmp(fb.data(), "T16F", 4) == 0;
    };
    if (!load(frames[0].first)) { fprintf(stderr, "bad frame %s\n", frames[0].first.c_str()); return 2; }
    top->i_machine = fb[4];
    top->rst_n = 0;
    top->i_spr_snap = 0;
    top->i_txy_unwrite = 0;
    clear_we();
    for (int i = 0; i < 16; i++) tick(false);
    top->rst_n = 1;
    tick(false);
    // counters are at the start of line 240 (the first vblank line)

    int bad = 0;
    for (auto &fr : frames) {
        if (!load(fr.first)) { fprintf(stderr, "bad frame %s\n", fr.first.c_str()); return 2; }
        if (fb[4] != top->i_machine) { fprintf(stderr, "machine changes within a list\n"); return 2; }
        const uint32_t nw = le32(&fb[6]);
        const uint8_t *rg = &fb[10];
        const uint8_t *ram = &fb[HDR];
        const uint8_t *wl = ram + RAMS;
        if (fb.size() < HDR + RAMS + (size_t)nw * 12) { fprintf(stderr, "short %s\n", fr.first.c_str()); return 2; }
        wait_idle();
        uint16_t over0 = top->o_dbg_overruns;
        wrblk(0, ram, 8192);
        for (int r = 0; r < 5; r++) wrblk(1 + r, ram + 8192 + r * 4096, 4096);
        wrblk(7, ram + 8192 + 5 * 4096, 4096);
        wr1(8, 0, le16(rg), 0xFFFF);
        if (fb[5] & 1) wr1(9, 0, le16(rg + 2), 0xFFFF);
        else { top->i_txy_unwrite = 1; tick(false); top->i_txy_unwrite = 0; }
        for (int r = 2; r < 6; r++) wr1(8 + r, 0, le16(rg + 2 * r), 0xFFFF);
        wr1(16, 0, rg[12], 0xFFFF);
        for (int k = 0; k < 2; k++) {
            top->i_spr_snap = 1; tick(false); top->i_spr_snap = 0;
            wait_idle();
        }

        std::vector<uint8_t> out, lay;
        out.reserve(256 * 224 * 3);
        uint32_t wi = 0;
        for (long i = 0; i < (long)VTOTAL * 384; i++) {
            long line = (240 + i / 384) % VTOTAL, h = i % 384;
            while (wi < nw) {
                const uint8_t *w = wl + 12 * wi;
                if (le16(w) != line || le16(w + 2) != h) break;
                wr1(w[4], le16(w + 6), le16(w + 8), le16(w + 10));
                wi++;
            }
            run_pixel();
            if (top->o_de) {
                out.push_back(top->o_r);
                out.push_back(top->o_g);
                out.push_back(top->o_b);
                uint64_t L = top->o_dbg_lay;
                for (int b = 0; b < 5; b++) lay.push_back((L >> (8 * b)) & 0xFF);
            }
        }
        if (wi != nw) { fprintf(stderr, "%s: applied %u of %u writes\n", fr.first.c_str(), wi, nw); bad++; }
        if (out.size() != 256u * 224 * 3) {
            fprintf(stderr, "%s: captured %zu pixels\n", fr.first.c_str(), out.size() / 3);
            bad++;
        }
        std::ofstream o(fr.second, std::ios::binary);
        o.write((const char *)out.data(), out.size());
        if (dbg) {
            std::ofstream ol(fr.second + ".lay", std::ios::binary);
            ol.write((const char *)lay.data(), lay.size());
        }
        printf("FRAME %s overruns %d maxcyc %d err %d\n", fr.first.c_str(),
               (int)(uint16_t)(top->o_dbg_overruns - over0), (int)top->o_dbg_maxcyc, (int)top->o_dbg_err);
    }
    printf("DONE frames %zu bad %d cycles %llu\n", frames.size(), bad, (unsigned long long)cycles);
    top->final();
    top.reset();
    fflush(stdout);
    _exit(bad ? 1 : 0);
}
