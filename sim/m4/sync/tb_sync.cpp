// Sync check for t16_video (m4_findings 10): at 384 x 264 with every OSD CRT
// position, vsync edges land on hsync leading edges, the pulses have the
// right lengths and periods, and the sync sits where the offset puts it
// relative to the picture (first active pixel of a line, first visible line).
#include "Vt16_video.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>

static Vt16_video *top;
static long px = 0;
static void tick(bool ce) {
    top->ce_pix = ce; top->clk = 0; top->eval(); top->clk = 1; top->eval();
}
static void pixel() { for (int i = 0; i < 16; i++) tick(i == 15); px++; }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    top = new Vt16_video;
    const int HT = 384, VT = 264, LINE0_VIS = 16;
    int fails = 0;
    top->rst_n = 0; for (int i = 0; i < 64; i++) tick(false);
    top->rst_n = 1;
    for (int h = -8; h <= 7; h++) for (int v = -4; v <= 3; v++) {
        top->i_crt_h = h & 15; top->i_crt_v = v & 7;
        for (int i = 0; i < 2 * HT * VT; i++) pixel();      // offsets taken at vblank
        // measure one frame, starting at a vblank start edge
        bool phs = top->o_hs, pvs = top->o_vs, pde = top->o_de, pvb = top->o_vblank;
        long hs_rise = -1, hs_prev_rise = -1, hs_len = -1, vs_rise = -1, vs_fall = -1;
        long de_rise_line = -1, vb_fall = -1, first_de = -1, hs_rise_in_line = -1;
        bool vs_on_hs_r = false, vs_on_hs_f = false, hs_period_ok = true;
        for (long i = 0; i < 2L * HT * VT; i++) {
            pixel();
            bool hs = top->o_hs, vs = top->o_vs, de = top->o_de, vb = top->o_vblank;
            if (hs && !phs) {
                if (hs_rise >= 0 && px - hs_rise != HT) hs_period_ok = false;
                hs_prev_rise = hs_rise; hs_rise = px;
            }
            if (!hs && phs && hs_rise >= 0) hs_len = px - hs_rise;
            if (vs && !pvs) { vs_rise = px; vs_on_hs_r = (hs && !phs); }
            if (!vs && pvs && vs_rise >= 0) { vs_fall = px; vs_on_hs_f = (hs && !phs); }
            if (!vb && pvb) vb_fall = px;
            if (de && !pde && first_de < 0 && vb_fall >= 0) first_de = px;
            phs = hs; pvs = vs; pde = de; pvb = vb;
        }
        // hsync start relative to the line's first active pixel; expected 304 - 2h
        long hs_rel = ((hs_rise - first_de) % HT + HT) % HT;
        // pixels from the vsync start (line 248 - v, at the hsync) to the first visible pixel (line 16, pixel 0)
        long vs_lines = ((first_de - vs_rise) % ((long)HT * VT) + (long)HT * VT) % ((long)HT * VT);
        long vs_len = vs_fall - vs_rise;
        bool ok = hs_period_ok && hs_len == 32 && vs_on_hs_r && vs_on_hs_f && vs_len == 3L * HT &&
                  hs_rel == 304 - 2 * h && vs_lines == (long)(VT - 248 + LINE0_VIS + v) * HT - (304 - 2 * h);
        if (!ok) {
            fails++;
            printf("FAIL h=%d v=%d: hs_period_ok=%d hs_len=%ld vs_on_hs=%d/%d vs_len=%ld hs_rel=%ld vs_px_before_vis=%ld\n",
                   h, v, hs_period_ok, hs_len, vs_on_hs_r, vs_on_hs_f, vs_len, hs_rel, vs_lines);
        }
    }
    printf("sync: 128 offset pairs, %d fail\n", fails);
    delete top;
    return fails ? 1 : 0;
}
