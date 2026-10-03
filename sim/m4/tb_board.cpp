// M4 board harness for t16_board + SDRAM model (sim/m4/tb_board.sv).
//
// Generated once from m2/tb_sys.cpp at commit 4eaadb7 (the M2 gate harness)
// and changed only where the board replaces the C++ memory models:
//   - everything arrives as on the MiSTer: the machine byte (ioctl index 1),
//     the DIP switches (index 254: byte 0 = DSW1, byte 1 = DSW2) and the ROM
//     stream (index 0 = the set's sdram.bin, which every MRA is proven to
//     reproduce, tools/make_mra.py) go through t16_board's ioctl port,
//     honouring ioctl_wait, into t16_sdram and the cycle-checked SDRAM model;
//     the board copies the audiocpu bytes of the stream into the sound ROM
//   - the program ROM, graphics ROM and M6295 samples then come from
//     t16_sdram, not from the harness
//   - hierarchy prefix tb_board.u_board.u_sys instead of t16_sys
// Outputs, file formats, frame numbering, input replay and plusargs are
// m2/tb_sys.cpp's (see below), so m2/compare.py checks a board run against
// MAME exactly as an M2 run; +lat/+intv/+okilat/+promlat no longer apply.
// The end line adds the SDRAM controller's worst CPU latency (clocks, must
// stay within t16_sys's 17) and forced refreshes.
//
// ---- m2/tb_sys.cpp header (formats and plusargs) follows ----
// M2 full-system harness for t16_sys (Verilator, C++).
//
// Loads the set's sdram.bin (PLAN 4.3 layout: maincpu 0x000000, bgtiles
// 0x080000, sprites 0x180000, fgtiles 0x280000, audiocpu 0x2a0000, oki
// 0x2b0000), downloads the sound ROM, resets and runs the system from
// power-on.
//
// Frame numbering: vblank N = the N-th o_vbl (start of line 240), the same
// instant as MAME's N-th frame notifier (t16_oracle.lua). MAME frame N is
// drawn at vblank N from the state the scan-out before it used, so our image
// N is the pixels scanned out between vblank N-1 and vblank N.
//
// Outputs in +out=DIR for every frame number N in +cap=FILE:
//   NNNNNN.rgb    image N: 256 x 224 x 3 (native orientation)
//   NNNNNN.wlog   every main CPU write to 0x110000-0x16001f during image N's
//                 window (vblank N-1 to vblank N): "line hcnt addr data mask"
//                 (byte address of the word; data as on the bus, a byte
//                 write carries the byte on both lanes, as MAME's taps)
//   at vblank N (16-bit words high byte first, as the oracle):
//   .pal (8 KB), .char (4 KB), .fgv .fgc .bgv .bgc (4 KB each; Final Star
//   Force uses the first 2 KB), .spr (live sprite RAM, 4 KB), .main (16 KB),
//   .work (Final Star Force 24 KB / Riot, Ginkun 4 KB), .snd (sound RAM
//   0xf000-0xfbff, then 0xfffe-0xffff), .regs (text x, text y raw, fg x,
//   fg y, bg x, bg y, then "txy_written flip")
//   after the vblank-N sprite copy has finished: .sprb (buffer S, the live
//   RAM at vblank N) and .sprb2 (S2, the list the renderer draws image N+1
//   from)
// Whole run:
//   +io=FILE     every write to 0x150000-0x16001f: "vblank line hcnt addr data mask"
//   +ftrace=FILE per vblank N: "N irq31 irq21 iack latch" (writes to
//                0x150030-31 and 0x150020-21, IRQ acknowledges, sound latch
//                writes during the frame that ends at vblank N), as the
//                oracle's frames.csv
//
// Plusargs: +sdram=FILE +machine=0|1|2 +frames=N +cap=FILE +out=DIR
//   +p1p2=HEX +dsw1=HEX +dsw2=HEX +extra=HEX (16-bit port values at idle)
//   +inputs=FILE: the oracle's inputs.csv (frame,port,field,value); each
//   event applied at vblank frame + inlag (+inlag=N, default 1)
//   graphics ROM model as m1/tb_video.cpp: +intv=N (default 8) +lat=N (9)
//   +okilat=N: clocks after each OKI ROM address change before ok (8)
//   +promlat=N: program ROM latency, request to ok (default 9, the M4
//   SDRAM controller's worst case at 96 MHz)
//   +pause=F:N: hold i_pause high for N frames from vblank F
//   +events=FILE: each line-pass overrun and the first 200 unmapped accesses

#include "Vtb_board.h"
#include "Vtb_board___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <string>
#include <tuple>
#include <unistd.h>
#include <vector>

static std::unique_ptr<Vtb_board> top;
static std::vector<uint8_t> sdram;
static uint64_t cycles = 0;

static void tick() {
    top->clk = 0; top->eval();
    top->clk = 1; top->eval();
    cycles++;
}

static void send(int index, uint32_t addr, uint8_t data) {
    while (top->o_ioctl_wait) tick();
    top->i_ioctl_index = index; top->i_ioctl_addr = addr; top->i_ioctl_dout = data;
    top->i_ioctl_wr = 1;
    tick();
    top->i_ioctl_wr = 0;
    tick();
}

static std::string plus(const char *name, const char *def) {
    const char *v = Verilated::commandArgsPlusMatch(name);
    if (!v || !*v) return def;
    const char *eq = strchr(v, '=');
    return eq ? std::string(eq + 1) : std::string(def);
}

static void dump(const std::string &path, const void *p, size_t n) {
    std::ofstream o(path, std::ios::binary);
    o.write((const char *)p, n);
}

template <typename A> static void dumpw(const std::string &path, const A &mem, int first, int nwords) {
    std::vector<uint8_t> b(2 * nwords);
    for (int i = 0; i < nwords; i++) { uint16_t w = mem[first + i]; b[2 * i] = w >> 8; b[2 * i + 1] = w & 0xFF; }
    dump(path, b.data(), b.size());
}

// inputs.csv field -> (port 0 P1_P2 / 1 EXTRA, bit, active_high)
static bool field_bit(int machine, const std::string &port, const std::string &field, int &p, int &bit, bool &hi) {
    static const char *dir[4] = {"Right", "Left", "Down", "Up"};
    hi = false;
    if (port == "P1_P2") {
        p = 0;
        for (int pl = 1; pl <= 2; pl++) {
            std::string pre = "P" + std::to_string(pl) + " ";
            if (field.compare(0, pre.size(), pre) != 0) continue;
            std::string r = field.substr(pre.size());
            for (int d = 0; d < 4; d++) if (r == dir[d]) { bit = (pl - 1) * 8 + d; return true; }
            if (r.compare(0, 7, "Button ") == 0) {
                int b = r[7] - '1';                    // Final Star Force / Ginkun: 1, 2 in bits 4, 5
                if (machine == 1) b -= 1;              // Riot: 2, 3 in bits 4, 5 (t16:624-640)
                if (b < 0 || b > 1) return false;
                bit = (pl - 1) * 8 + 4 + b;
                return true;
            }
        }
        if (field == "1 Player Start") { bit = 6; return true; }
        if (field == "2 Players Start") { bit = 7; return true; }
        if (field == "Coin 1") { bit = 14; hi = true; return true; }
        if (field == "Coin 2") { bit = 15; hi = true; return true; }
        return false;
    }
    if (port == "EXTRA" && machine == 1) {             // Riot button 1 (t16:642-645)
        p = 1;
        if (field == "P1 Button 1") { bit = 1; return true; }
        if (field == "P2 Button 1") { bit = 5; return true; }
    }
    return false;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    top = std::make_unique<Vtb_board>();
    std::string sdf = plus("sdram", ""), out = plus("out", "."), capf = plus("cap", "");
    long nframes = atol(plus("frames", "600").c_str());
    const int machine = atoi(plus("machine", "0").c_str());
    long pause_f = -1, pause_n = 0;
    {
        std::string ps = plus("pause", "");
        if (!ps.empty()) sscanf(ps.c_str(), "%ld:%ld", &pause_f, &pause_n);
    }
    std::string iof = plus("io", ""), ftf = plus("ftrace", "");
    FILE *fio = iof.empty() ? nullptr : fopen(iof.c_str(), "w");
    FILE *fft = ftf.empty() ? nullptr : fopen(ftf.c_str(), "w");
    {
        std::ifstream f(sdf, std::ios::binary);
        if (!f) { fprintf(stderr, "cannot open sdram %s\n", sdf.c_str()); return 2; }
        sdram.assign(std::istreambuf_iterator<char>(f), {});
    }
    std::set<long> cap;
    if (!capf.empty()) {
        std::ifstream f(capf);
        long n;
        while (f >> n) cap.insert(n);
    }
    std::multimap<long, std::tuple<int, int, bool, int>> events;
    const int inlag = atoi(plus("inlag", "1").c_str());
    {
        std::string inf = plus("inputs", "");
        if (!inf.empty()) {
            std::ifstream f(inf);
            std::string ln;
            std::getline(f, ln);                       // header
            while (std::getline(f, ln)) {
                std::stringstream ss(ln);
                std::string fr, port, field, val;
                std::getline(ss, fr, ','); std::getline(ss, port, ',');
                std::getline(ss, field, ','); std::getline(ss, val, ',');
                if (val.compare(0, 10, "user_value") == 0) continue;   // DIP set at start (+dsw)
                int p, bit; bool hi;
                if (!field_bit(machine, port, field, p, bit, hi)) {
                    fprintf(stderr, "unknown input %s %s\n", port.c_str(), field.c_str()); return 2;
                }
                events.insert({atol(fr.c_str()) + inlag, {p, bit, hi, atoi(val.c_str())}});
            }
        }
    }
    uint16_t ports[2];
    ports[0] = strtol(plus("p1p2", "3FFF").c_str(), nullptr, 16);
    ports[1] = strtol(plus("extra", machine == 1 ? "FFFF" : "0000").c_str(), nullptr, 16);
    top->i_p1p2 = ports[0];
    top->i_extra = ports[1];
    const unsigned dsw1 = strtoul(plus("dsw1", "00FF").c_str(), nullptr, 16);
    const unsigned dsw2 = strtoul(plus("dsw2", machine == 1 ? "00FC" : "00FF").c_str(), nullptr, 16);
    top->i_pause = 0;
    // power-on: PLL locked, SDRAM initialised, then the MiSTer's download
    // sequence (machine byte, DIP switches, ROM stream) with the core in
    // reset; the core leaves reset when the download ends
    top->i_reset = 0;
    top->i_ioctl_download = 0;
    top->i_ioctl_wr = 0;
    top->i_sdram_rst_n = 0;
    for (int i = 0; i < 16; i++) tick();
    top->i_sdram_rst_n = 1;
    top->i_ioctl_download = 1;
    send(1, 0, (uint8_t)machine);
    send(254, 0, (uint8_t)dsw1);
    send(254, 1, (uint8_t)dsw2);
    size_t dlen = strtoull(plus("dlen", "0").c_str(), nullptr, 0);
    if (dlen == 0 || dlen > sdram.size()) dlen = sdram.size();
    for (size_t a = 0; a < dlen; a++) send(0, (uint32_t)a, sdram[a]);
    for (int i = 0; i < 64; i++) tick();
    printf("download: %zu bytes, %llu clocks, machine %u\n", dlen, (unsigned long long)cycles, (unsigned)top->o_machine);
    top->i_ioctl_download = 0;

    auto *r = top->rootp;
#define V(x) r->tb_board__DOT__u_board__DOT__u_sys__DOT__u_video__DOT__##x
    // scroll registers, text-y-written and flip, tracked from the bus as
    // t16_video applies them (COMBINE_DATA; flip = data bit 0, M1)
    uint16_t regs[6] = {0, 0, 0, 0, 0, 0};
    int txy_written = 0, flip = 0;
    static const int vsel_of[16] = {0, -1, -1, 1, -1, -1, 2, -1, -1, 3, -1, -1, 4, -1, -1, 5};
    long frame = 0;                                // vblanks seen
    long irq31 = 0, irq21 = 0, iacks = 0, latches = 0;
    bool iack_prev = false;
    std::vector<uint8_t> px;
    px.reserve(256 * 224 * 3);
    std::string wlog;
    int prev_over = 0, prev_unm = 0, unm_shown = 0;
    std::string evf = plus("events", "");
    FILE *fev = evf.empty() ? nullptr : fopen(evf.c_str(), "w");
    bool sprb_pending = false, sprb_seen_busy = false;
    long sprb_frame = 0;
    const int base = machine == 0;
    while (frame < nframes) {
        bool ce = r->tb_board__DOT__u_board__DOT__u_sys__DOT__ce_pix;          // enable going into this edge
        if (r->tb_board__DOT__u_board__DOT__u_sys__DOT__m_wstb) {
            uint32_t ba = (uint32_t)r->tb_board__DOT__u_board__DOT__u_sys__DOT__m_a << 1;
            bool uds = !r->tb_board__DOT__u_board__DOT__u_sys__DOT__m_udsn, lds = !r->tb_board__DOT__u_board__DOT__u_sys__DOT__m_ldsn;
            unsigned mask = (uds ? 0xFF00 : 0) | (lds ? 0x00FF : 0);
            unsigned d = r->tb_board__DOT__u_board__DOT__u_sys__DOT__m_dout;
            if (!uds) d = (d & 0xFF) | ((d & 0xFF) << 8);
            else if (!lds) d = (d & 0xFF00) | (d >> 8);
            int line = V(vcnt), hp = V(hcnt);
            if (ba >= 0x110000 && ba < 0x160020) {
                char b[64];
                snprintf(b, sizeof b, "%d %d %06x %04x %04x\n", line, hp, ba, d, mask);
                wlog += b;
            }
            if (fio && ba >= 0x150000 && ba < 0x160020)
                fprintf(fio, "%ld %d %d %06x %04x %04x\n", frame, line, hp, ba, d, mask);
            if ((ba & ~1u) == 0x150030) irq31++;
            if ((ba & ~1u) == 0x150020) irq21++;
            if ((ba & ~1u) == 0x150010 && lds) latches++;
            if (ba >= 0x160000 && ba < 0x160020) {
                int s = vsel_of[(ba >> 1) & 15];
                if (s >= 0) {
                    regs[s] = (regs[s] & ~mask) | (d & mask);
                    if (s == 1) txy_written = 1;
                }
            }
            if ((ba & ~1u) == 0x150000) flip = d & 1;
        }
        bool ia = r->tb_board__DOT__u_board__DOT__u_sys__DOT__m_iack;
        if (ia && !iack_prev) iacks++;
        iack_prev = ia;
        tick();
        if (fev && top->o_dbg_overruns != prev_over) {
            fprintf(fev, "overrun vblank %ld line %d maxcyc %d\n", frame, (int)V(vcnt), top->o_dbg_maxcyc);
            prev_over = top->o_dbg_overruns;
        }
        if (fev && top->o_dbg_unmapped != prev_unm) {
            if (unm_shown++ < 200)
                fprintf(fev, "unmapped vblank %ld line %d %s %06x\n", frame, (int)V(vcnt),
                        r->tb_board__DOT__u_board__DOT__u_sys__DOT__m_rw ? "read" : "write", (uint32_t)r->tb_board__DOT__u_board__DOT__u_sys__DOT__m_a << 1);
            prev_unm = top->o_dbg_unmapped;
        }
        if (ce && top->o_de) {
            px.push_back(top->o_r);
            px.push_back(top->o_g);
            px.push_back(top->o_b);
        }
        if (sprb_pending) {
            bool busy = top->o_vid_busy;
            if (busy) sprb_seen_busy = true;
            else if (sprb_seen_busy) {
                std::string b = out + "/" + std::to_string(1000000 + sprb_frame).substr(1);
                dumpw(b + ".sprb", V(u_spr__DOT__g_snap__DOT__g_two__DOT__u_s__DOT__mem), 0, 2048);
                dumpw(b + ".sprb2", V(u_spr__DOT__g_snap__DOT__g_two__DOT__u_s2__DOT__mem), 0, 2048);
                sprb_pending = false;
            }
        }
        if (top->o_vbl) {
            frame++;
            if (cap.count(frame)) {
                std::string b = out + "/" + std::to_string(1000000 + frame).substr(1);
                if (px.size() != 256 * 224 * 3)
                    fprintf(stderr, "frame %ld: %zu pixels\n", frame, px.size() / 3);
                else
                    dump(b + ".rgb", px.data(), px.size());
                dump(b + ".wlog", wlog.data(), wlog.size());
                dumpw(b + ".pal", V(u_pal__DOT__g_plain__DOT__u_l__DOT__mem), 0, 4096);
                dumpw(b + ".char", V(u_char__DOT__g_plain__DOT__u_l__DOT__mem), 0, 2048);
                dumpw(b + ".fgv", V(u_fgv__DOT__g_plain__DOT__u_l__DOT__mem), 0, 2048);
                dumpw(b + ".fgc", V(u_fgc__DOT__g_plain__DOT__u_l__DOT__mem), 0, 2048);
                dumpw(b + ".bgv", V(u_bgv__DOT__g_plain__DOT__u_l__DOT__mem), 0, 2048);
                dumpw(b + ".bgc", V(u_bgc__DOT__g_plain__DOT__u_l__DOT__mem), 0, 2048);
                dumpw(b + ".spr", V(u_spr__DOT__g_snap__DOT__u_l__DOT__mem), 0, 2048);
                dumpw(b + ".main", r->tb_board__DOT__u_board__DOT__u_sys__DOT__u_ram__DOT__mem, 0, 8192);
                if (base) dumpw(b + ".work", r->tb_board__DOT__u_board__DOT__u_sys__DOT__u_work__DOT__mem, 0x1000, 0x3000);
                else      dumpw(b + ".work", r->tb_board__DOT__u_board__DOT__u_sys__DOT__u_work__DOT__mem, 0x2000, 0x800);
                {
                    std::vector<uint8_t> s(3074);
                    for (int i = 0; i < 3072; i++) s[i] = r->tb_board__DOT__u_board__DOT__u_sys__DOT__u_snd__DOT__u_ram__DOT__mem[i];
                    s[3072] = r->tb_board__DOT__u_board__DOT__u_sys__DOT__u_snd__DOT__hi_ram[0];
                    s[3073] = r->tb_board__DOT__u_board__DOT__u_sys__DOT__u_snd__DOT__hi_ram[1];
                    dump(b + ".snd", s.data(), s.size());
                }
                {
                    FILE *fr = fopen((b + ".regs").c_str(), "w");
                    fprintf(fr, "%d %d %d %d %d %d %d %d\n", regs[0], regs[1], regs[2], regs[3], regs[4], regs[5],
                            txy_written, flip);
                    fclose(fr);
                }
                sprb_pending = true;
                sprb_seen_busy = false;
                sprb_frame = frame;
            }
            if (fft) fprintf(fft, "%ld %ld %ld %ld %ld\n", frame, irq31, irq21, iacks, latches);
            irq31 = irq21 = iacks = latches = 0;
            wlog.clear();
            px.clear();
            for (auto it = events.lower_bound(frame); it != events.upper_bound(frame); ++it) {
                auto [p, bit, hi, v] = it->second;
                bool set = hi ? v != 0 : v == 0;
                if (set) ports[p] |= 1u << bit; else ports[p] &= ~(1u << bit);
            }
            top->i_p1p2 = ports[0];
            top->i_extra = ports[1];
            top->i_pause = pause_f >= 0 && frame >= pause_f && frame < pause_f + pause_n;
            if (frame % 100 == 0) {
                if (fio) fflush(fio);
                if (fft) fflush(fft);
                if (fev) fflush(fev);
            }
            if (frame % 500 == 0) {
                printf("vblank %ld pc %06x overruns %d maxcyc %d verr %d romwr %d unmapped %d promlate %d vregother %d sndunmapped %d\n",
                       frame, top->o_cpu_pc_dbg, top->o_dbg_overruns, top->o_dbg_maxcyc, top->o_dbg_verr,
                       top->o_dbg_rom_writes, top->o_dbg_unmapped, top->o_dbg_prom_late, top->o_dbg_vreg_other,
                       top->o_dbg_snd_unmapped);
                fflush(stdout);
            }
        }
    }
    printf("DONE vblanks %ld cycles %llu overruns %d maxcyc %d verr %d romwr %d unmapped %d promlate %d vregother %d sndunmapped %d sdram_cpu_maxlat %d ref_forced %d\n",
           frame, (unsigned long long)cycles, top->o_dbg_overruns, top->o_dbg_maxcyc, top->o_dbg_verr,
           top->o_dbg_rom_writes, top->o_dbg_unmapped, top->o_dbg_prom_late, top->o_dbg_vreg_other,
           top->o_dbg_snd_unmapped, top->o_dbg_cpu_maxlat, top->o_dbg_ref_forced);
    if (fio) fclose(fio);
    if (fft) fclose(fft);
    if (fev) fclose(fev);
    top->final();
    top.reset();
    fflush(stdout);
    _exit(0);
}
