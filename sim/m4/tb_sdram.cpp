// M4 SDRAM controller test (t16_sdram + SDRAM model), sim/m4/tb_sdram.sv.
// Adapted from the 1945k III core's test for the Tecmo 16 layout (PLAN 4.3):
// one 68000 at 12 MHz, one graphics port, one M6295.
//
// 1. Downloads a set's sdram.bin (sim/build/regions/<set>/sdram.bin, the MRA
//    stream) through the ioctl byte port, honouring o_dl_busy as ioctl_wait.
// 2. Runs all clients at once for +cycles=N clocks and checks every returned
//    word against the image:
//      CPU   68000-like program fetches: a bus cycle every 32 clocks at the
//            earliest (12 MHz, 4 clocks per cycle, 96 MHz system clock),
//            about 70% program reads, sequential with jumps, occasional
//            repeats of the last word and idle stretches (internal cycles,
//            STOP); the request rises one clock after AS as t16_sys's MB_ROM
//      GFX   t16_video's port at full pressure: a request every clock,
//            random 4-byte reads in the bg, sprite and fg tile regions
//      OKI   the M6295 port, new byte address every 40-400 clocks
// 3. Reports CPU latency (request rise -> ok, clocks), its histogram,
//    graphics throughput, refreshes (and forced ones), and any mismatch.
//    The SDRAM model stops the run on any protocol or timing violation.
//
// Plusargs: +sdram=FILE +cycles=N +dlen=N (bytes, default the whole file)
//           +seed=N +quiet

#include "Vtb_sdram.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <map>
#include <memory>
#include <random>
#include <string>
#include <unistd.h>
#include <vector>

static std::unique_ptr<Vtb_sdram> top;
static uint64_t cyc = 0;

static void tick() {
    top->clk = 0; top->eval();
    top->clk = 1; top->eval();
    cyc++;
}

static std::string plus(const char *name, const char *def) {
    const char *v = Verilated::commandArgsPlusMatch(name);
    if (!v || !*v) return def;
    const char *eq = strchr(v, '=');
    return eq ? std::string(eq + 1) : std::string(def);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    top = std::make_unique<Vtb_sdram>();
    std::string sd = plus("sdram", "");
    uint64_t ncyc = strtoull(plus("cycles", "2000000").c_str(), nullptr, 0);
    unsigned seed = (unsigned)atoi(plus("seed", "1").c_str());
    std::mt19937 rng(seed);

    std::vector<uint8_t> img;
    {
        std::ifstream f(sd, std::ios::binary);
        if (!f) { fprintf(stderr, "cannot open +sdram=%s\n", sd.c_str()); return 2; }
        img.assign(std::istreambuf_iterator<char>(f), {});
    }
    size_t dlen = strtoull(plus("dlen", "0").c_str(), nullptr, 0);
    if (dlen == 0 || dlen > img.size()) dlen = img.size();
    printf("image %zu bytes, downloading %zu\n", img.size(), dlen);

    // reset + init
    top->rst_n = 0;
    for (int i = 0; i < 8; i++) tick();
    top->rst_n = 1;
    while (!top->o_ready) tick();

    // ---------------------------------------------------------------- download
    uint64_t t0 = cyc;
    for (size_t a = 0; a < dlen; a++) {
        while (top->o_dl_busy) { top->i_dl_wr = 0; tick(); }
        top->i_dl_wr = 1; top->i_dl_addr = (uint32_t)a; top->i_dl_data = img[a];
        tick();
        top->i_dl_wr = 0;
        tick();
    }
    for (int i = 0; i < 64; i++) tick();
    printf("download: %llu clocks, %u words written\n",
           (unsigned long long)(cyc - t0), (unsigned)top->o_dbg_dl_words);
    if (dlen < img.size()) img.resize(dlen);   // checks only cover what was loaded
    auto byte = [&](uint32_t a) -> uint32_t { return a < img.size() ? img[a] : 0; };

    // ---------------------------------------------------------------- traffic
    top->i_cpu_run = 1;
    // CPU state
    uint64_t next_as = cyc + 30, req_rise = 0;
    bool cpu_req = false;
    uint32_t pc = 0x400, last_word = 0;
    const uint64_t CYC = 32;                           // 68000 bus cycle, clocks
    std::map<int, uint64_t> hist;
    uint64_t fetches = 0, cpu_err = 0, maxlat = 0, repeats = 0;
    // GFX state
    std::deque<uint32_t> gq;
    uint32_t gaddr = 0x080000;
    uint64_t greq = 0, gret = 0, gerr = 0;
    auto new_gaddr = [&]() -> uint32_t {
        uint32_t r = rng() % 8;
        if (r < 3) return 0x080000 + (rng() % 0x100000 & ~3u);              // bg tiles
        if (r < 7) return 0x180000 + (rng() % 0x100000 & ~3u);              // sprites
        return 0x280000 + (rng() % 0x020000 & ~3u);                        // fg tiles
    };
    gaddr = new_gaddr();
    // OKI state
    uint32_t k1 = 0; uint64_t k1_next = cyc, k1n = 0, kerr = 0;
    bool k1_checked = true;

    const uint64_t end = cyc + ncyc;
    while (cyc < end && !Verilated::gotFinish()) {
        // ---- CPU: start a bus cycle?
        if (!cpu_req && cyc >= next_as) {
            uint32_t r = rng() % 100;
            if (r < 70) {                                  // program read
                uint32_t w;
                if (rng() % 100 < 4) { w = last_word; repeats++; }
                else if (rng() % 100 < 12) w = (rng() % 0x40000);   // jump
                else w = pc;
                pc = (w + 1) & 0x3FFFF;
                last_word = w;
                top->i_cpu_addr = w;                       // [18:1] word address
                cpu_req = true;
                req_rise = cyc + 1;                        // MB_ROM one clock after AS
            } else {                                       // other bus cycle or internal
                next_as = cyc + CYC + ((rng() % 100 < 15) ? 8 * (1 + rng() % 8) : 0)
                          + ((rng() % 1000 == 0) ? 3000 : 0);   // rare STOP-like gap
            }
        }
        top->i_cpu_req = (cpu_req && cyc >= req_rise) ? 1 : 0;

        // ---- GFX
        top->i_gfx_req = 1;
        top->i_gfx_addr = gaddr;

        // ---- OKI
        if (cyc >= k1_next) { k1 = rng() % 0x40000; k1_next = cyc + 40 + rng() % 360; k1_checked = false; }
        top->i_oki_addr = k1;

        // settle combinational outputs with the inputs of this clock
        top->clk = 0; top->eval();
        bool cpu_ok = top->i_cpu_req && top->o_cpu_ok;
        uint16_t cpu_d = top->o_cpu_data;
        bool g_acc = top->o_gfx_gnt && top->i_gfx_req;
        tick();

        if (cpu_ok) {
            uint32_t a = (uint32_t)top->i_cpu_addr * 2;
            uint16_t want = (uint16_t)((byte(a) << 8) | byte(a + 1));
            if (cpu_d != want) {
                if (cpu_err < 10) printf("CPU mismatch @%06x got %04x want %04x\n", a, cpu_d, want);
                cpu_err++;
            }
            uint64_t lat = cyc - req_rise;                 // clocks from request to the ok edge
            hist[(int)lat]++;
            if (lat > maxlat) maxlat = lat;
            fetches++;
            cpu_req = false;
            uint64_t as = req_rise - 1;
            next_as = std::max(as + CYC, cyc + 12);        // S7 + next S0/S1
        }
        if (g_acc) { gq.push_back(gaddr); greq++; gaddr = new_gaddr(); }
        if (top->o_gfx_rv) {
            if (gq.empty()) { printf("GFX: data with no request\n"); gerr++; }
            else {
                uint32_t a = gq.front(); gq.pop_front();
                uint32_t want = (byte(a) << 24) | (byte(a + 1) << 16) | (byte(a + 2) << 8) | byte(a + 3);
                if (top->o_gfx_data != want) {
                    if (gerr < 10) printf("GFX mismatch @%06x got %08x want %08x\n", a, top->o_gfx_data, want);
                    gerr++;
                }
                gret++;
            }
        }
        if (!k1_checked && top->o_oki_ok && top->i_oki_addr == k1) {
            if (top->o_oki_data != byte(0x2B0000 + k1)) { if (kerr < 10) printf("OKI mismatch @%05x\n", k1); kerr++; }
            k1_checked = true; k1n++;
        }
    }

    printf("traffic: %llu clocks\n", (unsigned long long)ncyc);
    printf("CPU: %llu fetches (%llu repeats of the last word), max latency %llu clocks, "
           "controller max %u, errors %llu\n",
           (unsigned long long)fetches, (unsigned long long)repeats, (unsigned long long)maxlat,
           (unsigned)top->o_dbg_cpu_maxlat, (unsigned long long)cpu_err);
    printf("CPU latency histogram (clocks: count):");
    for (auto &h : hist) printf(" %d:%llu", h.first, (unsigned long long)h.second);
    printf("\n");
    printf("GFX: %llu reads (one per %.2f clocks), %llu returned, errors %llu\n",
           (unsigned long long)greq, greq ? (double)ncyc / greq : 0.0,
           (unsigned long long)gret, (unsigned long long)gerr);
    printf("OKI: %llu reads checked, errors %llu\n",
           (unsigned long long)k1n, (unsigned long long)kerr);
    printf("refresh: %u issued, %u forced (outside the post-fetch window); %.1f expected\n",
           (unsigned)top->o_dbg_refreshes, (unsigned)top->o_dbg_ref_forced, ncyc / 750.0);
    // the 68000 needs the word within 17 clocks of the request (t16_sys
    // PROM_LIMIT, m2_findings 3); the latency here counts from the rising
    // request to the ok edge, the same measure
    bool ok = !cpu_err && !gerr && !kerr && fetches && greq && k1n && maxlat <= 17;
    printf("%s\n", ok ? "PASS" : "FAIL");
    top->final();
    // _exit: skip static destructors (libc++ aborts on a Verilator mutex at
    // teardown); flush first, the report is buffered
    fflush(stdout);
    _exit(ok ? 0 : 1);
}
