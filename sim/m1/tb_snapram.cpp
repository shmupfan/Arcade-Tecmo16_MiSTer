// M1 unit test for t16_snapram MODE 2 (the sprite list double buffer):
// the snapshot must equal the live RAM at the clock of the snap request even
// when the CPU keeps writing while the copy engine walks the addresses
// (copy-before-write, m1_findings 4).
//
// Per round: random live RAM, then snap; during the walk the CPU writes
// random words at random addresses every +gap clocks (default 32, one 68000
// bus cycle at 96 MHz; `make m1-snapram` also runs 8, four times faster
// than a 68000 can write). A model keeps L, S, S2:
// at the snap clock S2 <- S, S <- L; CPU writes after that change only L.
// After the walk the renderer port (S2) must equal the model's S2, and one
// more snap with no writes must move the model's S into S2 for checking.
// Plusargs: +rounds=N +gap=N +seed=N

#include "Vt16_snapram.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <random>
#include <string>
#include <vector>
#include <unistd.h>

static std::unique_ptr<Vt16_snapram> top;
static void tick() { top->clk = 0; top->eval(); top->clk = 1; top->eval(); }

static std::string plus(const char *name, const char *def) {
    const char *v = Verilated::commandArgsPlusMatch(name);
    if (!v || !*v) return def;
    const char *eq = strchr(v, '=');
    return eq ? std::string(eq + 1) : std::string(def);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    top = std::make_unique<Vt16_snapram>();
    const int rounds = atoi(plus("rounds", "40").c_str());
    const int gap = atoi(plus("gap", "32").c_str());
    std::mt19937 rng(atoi(plus("seed", "1").c_str()));
    const int N = 2048;
    std::vector<uint16_t> L(N, 0), S(N, 0), S2(N, 0);
    top->rst_n = 0; top->i_snap = 0; top->i_cpu_we = 0;
    for (int i = 0; i < 8; i++) tick();
    top->rst_n = 1; tick();

    auto cpu_write = [&](int a, uint16_t d, int be) {
        top->i_cpu_addr = a; top->i_cpu_din = d; top->i_cpu_be = be; top->i_cpu_we = 1;
        tick();
        top->i_cpu_we = 0;
        uint16_t m = (be & 2 ? 0xFF00 : 0) | (be & 1 ? 0x00FF : 0);
        L[a] = (L[a] & ~m) | (d & m);
    };
    auto snap = [&](bool writes, long &nw, long &held) {
        // the snap clock: model copies first
        S2 = S; S = L;
        top->i_snap = 1; tick(); top->i_snap = 0;
        int k = 0;
        while (top->o_busy) {
            if (writes && ++k % gap == 0) {
                if (top->o_hold) held++;
                cpu_write(rng() % N, rng() & 0xFFFF, 1 + rng() % 3);
                nw++;
            } else tick();
        }
        for (int i = 0; i < 4; i++) tick();
    };
    auto check = [&](const char *what) {
        int bad = 0;
        for (int a = 0; a < N; a++) {
            top->i_vid_addr = a; tick();
            if (top->o_vid_q != S2[a] && bad++ < 4)
                printf("MISMATCH %s addr %d rtl %04x model %04x\n", what, a, top->o_vid_q, S2[a]);
        }
        return bad;
    };

    int bad = 0;
    long nw = 0, held = 0;
    for (int r = 0; r < rounds; r++) {
        for (int a = 0; a < N; a++) if (rng() % 3 == 0) cpu_write(a, rng() & 0xFFFF, 3);
        snap(true, nw, held);
        bad += check("after snap with writes (S2 = previous S)");
        snap(false, nw, held);
        bad += check("next snap (S2 = the snapshot taken while writing)");
    }
    // live port reads back what the CPU wrote
    for (int a = 0; a < N; a++) {
        top->i_cpu_addr = a; tick(); tick();
        if (top->o_cpu_dout != L[a] && bad++ < 4) printf("MISMATCH live addr %d\n", a);
    }
    printf("DONE rounds %d gap %d cpu writes during copies %ld (arriving while another was held: %ld) err %d mismatches %d\n",
           rounds, gap, nw, held, (int)top->o_err, bad);
    top->final();
    fflush(stdout);
    _exit(bad || top->o_err ? 1 : 0);
}
