// Tecmo 16 video for Final Star Force / Riot / Ganbare Ginkun (PLAN M1).
//
// Reference model: sim/oracle/t16_render.py, pixel-exact against MAME 0.288
// on every M0 capture. "spec N" = docs/tecmo16_system_spec.md; t16/spr/mix
// line numbers = reference/mame/tecmo16.cpp, tecmo_spr.cpp, tecmo_mix.cpp.
//
// Contents:
//   - raster: 384 pixels per line at a 6 MHz pixel enable (96 MHz / 16),
//     V_TOTAL lines (default 264, the 6 MHz / 384 x 264 guess of t16:20,
//     research item R3), visible 256 x 224 at lines 16-239 as in MAME
//     (t16:681-682); vblank starts at line 240
//   - CPU-side RAMs (t16_snapram): palette 4,096 words, text RAM, fg and bg
//     codes and colours (2,048 words each; Final Star Force uses the low
//     1,024 of the four tile RAMs, spec 3), sprite RAM 2,048 words
//   - sprite list double buffer (snapram MODE 2): at vblank start S2 <= S,
//     S <= live; the renderer reads S2, which gives MAME's two-frame sprite
//     lag exactly (spec 8, m0_findings 2)
//   - LATCH = 0 (default, Lee 2026-10-02): the renderer reads tile RAM,
//     palette, scroll and flip live while the frame is drawn, the most
//     plausible PCB behaviour (unconfirmed, research item R1). LATCH = 1:
//     those are snapshotted at the start of line LATCH_LINE and the frame is
//     drawn from the snapshot. MAME draws each frame once at vblank start
//     from the state at that moment (spec 10.1); neither choice reproduces a
//     write the game makes during the visible scan the way MAME shows it
//     (that needs one frame of display delay), see m1_findings.
//   - line renderer: during line L-1 the tile passes and the sprite pass
//     build line L into four double line buffers (bg, fg, text, sprites);
//     scan-out reads them and the mixer (tecmo_mix.cpp:70-323, spec 9)
//     looks up one or two palette entries per pixel
//
// ROM traffic per line, all on one graphics ROM port (pipelined, in-order
// returns, [31:24] = byte at the address):
//   bg and fg: 17 tiles x 2 words (16 pixels a tile row); text: 33 tiles x
//   1 word; sprites: one word per 8 x 8 cell row crossing the line. Each
//   word is 8 pixels of 4 bits, high nibble first (gfx_8x8x4_packed_msb).
// One writer drains the returned words at one pixel per clock.

module t16_video #(
    parameter bit LATCH      = 1'b0,
    parameter int LATCH_LINE = 14,
    parameter int V_TOTAL    = 264,
    // 1 (MiSTer board): the raster counters and sync run from power-on and
    // keep going while the core is held in reset (ROM download, SDRAM
    // init), with black RGB; i_tim_rst reloads their power-on state once a
    // frame and t16_sys releases the core on the clock after that reload, so
    // the game starts exactly as from a plain reset release (M1/M2 state).
    // 0 (simulation default): counters and sync reset with rst_n.
    parameter bit FREE_TIMING = 1'b0
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        ce_pix,          // 6 MHz: exactly one clock in 16
    input  logic        i_tim_rst,       // FREE_TIMING: synchronous raster reload
    output logic        o_tim_evt,       // FREE_TIMING: the next pixel starts the power-on line
    input  logic [1:0]  i_machine,       // 0 Final Star Force, 1 Riot, 2 Ginkun

    // CPU side, decoded by the system (M2): word address within each RAM,
    // 68000 byte enables {UDS, LDS}
    input  logic [11:0] i_cpu_addr,
    input  logic [15:0] i_cpu_din,
    input  logic [1:0]  i_cpu_be,
    input  logic        i_pal_we,        // 0x140000-0x141fff (addr[11:0])
    input  logic        i_char_we,       // 0x110000-0x110fff (addr[10:0])
    input  logic        i_fgv_we,        // fg codes   (spec 3: per machine)
    input  logic        i_fgc_we,        // fg colours
    input  logic        i_bgv_we,        // bg codes
    input  logic        i_bgc_we,        // bg colours
    input  logic        i_spr_we,        // 0x130000-0x130fff
    output logic [15:0] o_pal_dout,
    output logic [15:0] o_char_dout,
    output logic [15:0] o_fgv_dout,
    output logic [15:0] o_fgc_dout,
    output logic [15:0] o_bgv_dout,
    output logic [15:0] o_bgc_dout,
    output logic [15:0] o_spr_dout,
    input  logic        i_reg_we,        // scroll registers 0x160000-0x16001f
    input  logic [2:0]  i_reg_sel,       // 0 text x, 1 text y, 2 fg x, 3 fg y, 4 bg x, 5 bg y
    input  logic        i_flip_we,       // 0x150000 bit 0
    input  logic        i_spr_snap,      // extra sprite buffer copy (sim harness)
    input  logic        i_txy_unwrite,   // sim harness: text y back to "never written"

    // graphics ROM port (byte address in the PLAN 4.3 SDRAM layout)
    output logic        o_rom_req,
    output logic [21:0] o_rom_addr,
    input  logic        i_rom_gnt,
    input  logic        i_rom_rv,
    input  logic [31:0] i_rom_data,

    // video
    output logic [7:0]  o_r,
    output logic [7:0]  o_g,
    output logic [7:0]  o_b,
    output logic        o_de,
    output logic        o_hblank,
    output logic        o_vblank,
    output logic        o_hs,
    output logic        o_vs,
    output logic        o_vbl,           // one clk at the start of line 240 (IRQ5, sprite copy)
    output logic        o_busy,          // a snapshot engine is running
    output logic        o_hold,          // a CPU write is held by a snapshot engine

    // gate counters
    output logic [15:0] o_dbg_overruns,
    output logic [15:0] o_dbg_maxcyc,
    output logic [7:0]  o_dbg_err,
    output logic [35:0] o_dbg_lay        // sim: {sprite 11, text 8, fg 9, bg 8} of the output pixel
);

  localparam logic [21:0] BG_BASE  = 22'h080000;   // PLAN 4.3
  localparam logic [21:0] SPR_BASE = 22'h180000;
  localparam logic [21:0] TX_BASE  = 22'h280000;
  localparam int H_ACT = 256, H_TOTAL = 384;
  localparam int V_VIS0 = 16, V_VIS1 = 239, V_VBL = 240;
  // sync positions are not in the driver (spec 5, research item R3)
  localparam int HS_START = 304, HS_END = 336;
  localparam int VS_START = 248;

  wire base  = i_machine == 2'd0;
  wire riot  = i_machine == 2'd1;

  // ================================================================ timing
  logic [8:0] hcnt /* verilator public_flat_rd */;
  logic [8:0] vcnt /* verilator public_flat_rd */;
  // Power-on phase as in MAME: the screen starts at the first vblank line
  // (the Dooyong oracle measured this, dooyong ym2203_findings)
  wire tim_rst = FREE_TIMING ? i_tim_rst : !rst_n;
  assign o_tim_evt = ce_pix && hcnt == 9'(H_TOTAL - 1) &&
                     ((vcnt == 9'(V_TOTAL - 1)) ? 9'd0 : vcnt + 9'd1) == 9'(V_VBL);
  always_ff @(posedge clk) begin
    if (tim_rst) begin
      hcnt <= '0;
      vcnt <= 9'(V_VBL);
    end else if (ce_pix) begin
      if (hcnt == 9'(H_TOTAL - 1)) begin
        hcnt <= '0;
        vcnt <= (vcnt == 9'(V_TOTAL - 1)) ? 9'd0 : vcnt + 9'd1;
      end else hcnt <= hcnt + 9'd1;
    end
  end
  wire last_px    = ce_pix && hcnt == 9'(H_TOTAL - 1);
  wire vbl_start  = last_px && vcnt == 9'(V_VBL - 1);
  wire latch_now  = last_px && vcnt == 9'(LATCH_LINE - 1);
  wire line_start = ce_pix && hcnt == 9'd0;
  always_ff @(posedge clk) o_vbl <= rst_n && vbl_start;

  // ================================================================ registers
  // MAME (t16:283-307): bg/fg/text x and y are the written 16-bit values;
  // the text layer's y is (written - 16) from the first write on, and -16
  // (Final Star Force, t16:203) or 0 before it (spec 7).
  logic [15:0] reg_v [0:5];
  logic        txy_written;
  logic        flip_r;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < 6; i++) reg_v[i] <= '0;
      txy_written <= 1'b0;
      flip_r <= 1'b0;
    end else begin
      if (i_reg_we && i_reg_sel <= 3'd5) begin
        if (i_cpu_be[1]) reg_v[i_reg_sel][15:8] <= i_cpu_din[15:8];
        if (i_cpu_be[0]) reg_v[i_reg_sel][7:0]  <= i_cpu_din[7:0];
        if (i_reg_sel == 3'd1) txy_written <= 1'b1;
      end
      if (i_txy_unwrite) txy_written <= 1'b0;
      if (i_flip_we && i_cpu_be[0]) flip_r <= i_cpu_din[0];
    end
  end
  wire [15:0] txy_eff_live = txy_written ? reg_v[1] - 16'd16 : (base ? 16'hFFF0 : 16'h0000);

  // registers the renderer uses: live, or the copy taken at LATCH_LINE
  logic [15:0] v_txx, v_txy, v_fgx, v_fgy, v_bgx, v_bgy;
  logic        v_flip;
  generate
    if (LATCH) begin : g_latch_regs
      always_ff @(posedge clk) begin
        if (latch_now) begin
          v_txx <= reg_v[0]; v_txy <= txy_eff_live;
          v_fgx <= reg_v[2]; v_fgy <= reg_v[3];
          v_bgx <= reg_v[4]; v_bgy <= reg_v[5];
          v_flip <= flip_r;
        end
      end
    end else begin : g_live_regs
      always_comb begin
        v_txx = reg_v[0]; v_txy = txy_eff_live;
        v_fgx = reg_v[2]; v_fgy = reg_v[3];
        v_bgx = reg_v[4]; v_bgy = reg_v[5];
        v_flip = flip_r;
      end
    end
  endgenerate

  // ================================================================ RAMs
  localparam int TMODE = LATCH ? 1 : 0;
  logic [11:0] pal_va;
  logic [10:0] tile_va, char_va, spr_va;
  logic [15:0] pal_q, char_q, fgv_q, fgc_q, bgv_q, bgc_q, spr_q;
  logic [6:0]  busy_v, hold_v;
  logic [7:0]  err_v [0:6];

  t16_snapram #(.AW(12), .MODE(TMODE)) u_pal (
      .clk, .rst_n, .i_cpu_addr(i_cpu_addr[11:0]), .i_cpu_din, .i_cpu_be, .i_cpu_we(i_pal_we),
      .o_cpu_dout(o_pal_dout), .i_snap(latch_now), .o_busy(busy_v[0]), .o_hold(hold_v[0]), .o_err(err_v[0]),
      .i_vid_addr(pal_va), .o_vid_q(pal_q));
  t16_snapram #(.AW(11), .MODE(TMODE)) u_char (
      .clk, .rst_n, .i_cpu_addr(i_cpu_addr[10:0]), .i_cpu_din, .i_cpu_be, .i_cpu_we(i_char_we),
      .o_cpu_dout(o_char_dout), .i_snap(latch_now), .o_busy(busy_v[1]), .o_hold(hold_v[1]), .o_err(err_v[1]),
      .i_vid_addr(char_va), .o_vid_q(char_q));
  t16_snapram #(.AW(11), .MODE(TMODE)) u_fgv (
      .clk, .rst_n, .i_cpu_addr(i_cpu_addr[10:0]), .i_cpu_din, .i_cpu_be, .i_cpu_we(i_fgv_we),
      .o_cpu_dout(o_fgv_dout), .i_snap(latch_now), .o_busy(busy_v[2]), .o_hold(hold_v[2]), .o_err(err_v[2]),
      .i_vid_addr(tile_va), .o_vid_q(fgv_q));
  t16_snapram #(.AW(11), .MODE(TMODE)) u_fgc (
      .clk, .rst_n, .i_cpu_addr(i_cpu_addr[10:0]), .i_cpu_din, .i_cpu_be, .i_cpu_we(i_fgc_we),
      .o_cpu_dout(o_fgc_dout), .i_snap(latch_now), .o_busy(busy_v[3]), .o_hold(hold_v[3]), .o_err(err_v[3]),
      .i_vid_addr(tile_va), .o_vid_q(fgc_q));
  t16_snapram #(.AW(11), .MODE(TMODE)) u_bgv (
      .clk, .rst_n, .i_cpu_addr(i_cpu_addr[10:0]), .i_cpu_din, .i_cpu_be, .i_cpu_we(i_bgv_we),
      .o_cpu_dout(o_bgv_dout), .i_snap(latch_now), .o_busy(busy_v[4]), .o_hold(hold_v[4]), .o_err(err_v[4]),
      .i_vid_addr(tile_va), .o_vid_q(bgv_q));
  t16_snapram #(.AW(11), .MODE(TMODE)) u_bgc (
      .clk, .rst_n, .i_cpu_addr(i_cpu_addr[10:0]), .i_cpu_din, .i_cpu_be, .i_cpu_we(i_bgc_we),
      .o_cpu_dout(o_bgc_dout), .i_snap(latch_now), .o_busy(busy_v[5]), .o_hold(hold_v[5]), .o_err(err_v[5]),
      .i_vid_addr(tile_va), .o_vid_q(bgc_q));
  t16_snapram #(.AW(11), .MODE(2)) u_spr (
      .clk, .rst_n, .i_cpu_addr(i_cpu_addr[10:0]), .i_cpu_din, .i_cpu_be, .i_cpu_we(i_spr_we),
      .o_cpu_dout(o_spr_dout), .i_snap(vbl_start || i_spr_snap), .o_busy(busy_v[6]), .o_hold(hold_v[6]),
      .o_err(err_v[6]), .i_vid_addr(spr_va), .o_vid_q(spr_q));
  assign o_busy = |busy_v;
  assign o_hold = |hold_v;
  always_comb begin
    o_dbg_err = '0;
    for (int i = 0; i < 7; i++) o_dbg_err = o_dbg_err | err_v[i];
  end

  // ================================================================ renderer
  // ---- line start: the pass for line L runs during line L-1
  wire [8:0] next_line = (vcnt == 9'(V_TOTAL - 1)) ? 9'd0 : vcnt + 9'd1;
  wire       want_line = line_start && next_line >= 9'(V_VIS0) && next_line <= 9'(V_VIS1);

  logic        busy, pend;
  logic [8:0]  pend_line;
  logic [7:0]  r_line;          // display line of the pass (16-239)
  logic [7:0]  r_srcy;          // flipped: 255 - line (tilemap.cpp)
  logic        r_flip;
  logic [15:0] r_txx, r_txy, r_fgx, r_fgy, r_bgx, r_bgy;
  logic [15:0] cyc, maxcyc, overruns;
  wire         go = !busy && (want_line || pend);
  wire [8:0]   go_line = want_line ? next_line : pend_line;

  // ---- tile issuer
  localparam logic [1:0] T_IDLE = 2'd0, T_ADDR = 2'd1, T_WAIT = 2'd2, T_ISS = 2'd3;
  logic [1:0]  t_st;
  logic [1:0]  t_layer;         // 0 bg, 1 fg, 2 text
  logic [5:0]  t_k;             // tile of the line
  logic        t_j;             // 8-pixel half of a 16-pixel tile row
  logic        t_done;
  logic [15:0] t_code, t_col;

  wire         t_tx    = t_layer == 2'd2;
  wire         t_fg    = t_layer == 2'd1;
  wire         cols64  = !base;                       // tecmo16.cpp:195-196, 219-220, 241-242
  wire [15:0]  t_sx    = t_tx ? r_txx : t_fg ? r_fgx : r_bgx;
  wire [15:0]  t_sy    = t_tx ? r_txy : t_fg ? r_fgy : r_bgy;
  // logical line: (src - dy + scroll) mod height; Riot's text dy is -16 (t16:248)
  wire [8:0]   t_ly    = t_tx ? 9'({1'b0, r_srcy} + (riot ? 9'd16 : 9'd0) + t_sy[8:0]) & 9'h0FF
                              : 9'({1'b0, r_srcy} + t_sy[8:0]);
  wire [5:0]   t_tc0   = t_tx ? t_sx[8:3] : t_sx[9:4];
  wire [5:0]   t_colx  = t_tc0 + t_k;                 // tile column (mod 64, masked below)
  wire [5:0]   t_cmask = t_tx ? t_colx : (cols64 ? t_colx : {1'b0, t_colx[4:0]});
  wire [10:0]  t_idx   = t_tx ? {t_ly[7:3], t_cmask} :
                         cols64 ? {t_ly[8:4], t_cmask} : {1'b0, t_ly[8:4], t_cmask[4:0]};
  wire [5:0]   t_last  = t_tx ? 6'd32 : 6'd16;
  // logical x of the word's first pixel, and its screen x (mod width)
  wire [9:0]   t_lx    = t_tx ? {1'b0, t_cmask, 3'd0} : {t_cmask, t_j, 3'd0};
  wire [9:0]   t_wm    = (t_tx || !cols64) ? 10'h1FF : 10'h3FF;
  wire [9:0]   t_x0    = (r_flip ? (10'd255 + t_sx[9:0] - t_lx) : (t_lx - t_sx[9:0])) & t_wm;
  wire [21:0]  t_addr  = t_tx ? TX_BASE + {5'd0, t_code[11:0], t_ly[2:0], 2'b00}
                              : BG_BASE + {2'd0, t_code[12:0], t_ly[3], t_j, t_ly[2:0], 2'b00};
  // colour bits carried with the word: bg colour & 0x0f, fg & 0x1f (bit 4
  // = blend), text char >> 12 (spec 7)
  wire [6:0]   t_attr  = t_tx ? {3'd0, t_code[15:12]} : t_fg ? {2'd0, t_col[4:0]} : {3'd0, t_col[3:0]};
  wire         t_req   = t_st == T_ISS;
  assign tile_va = t_idx;
  assign char_va = t_idx;

  // ---- sprite walker (tecmo_spr.cpp:74-178)
  localparam logic [2:0] W_A0 = 3'd0, W_A2 = 3'd1, W_A3 = 3'd2, W_HIT = 3'd3, W_A4 = 3'd4, W_PUSH = 3'd5, W_IDLE = 3'd6,
                         W_HIT2 = 3'd7;
  logic [2:0]  w_st;
  logic [7:0]  w_e;             // entry
  logic        w_done;
  logic [15:0] w_attr, w_colw;
  logic [10:0] w_ys;            // signed y after the flip transform
  logic [2:0]  w_row, w_ln;
  logic [10:0] w_ypos;          // y_pos registered in W_HIT (timing: RAM -> flip -> hit test was one clock)
  logic [15:0] w_num;
  wire  [1:0]  w_lx    = w_colw[1:0];
  wire  [1:0]  w_ly    = riot ? w_colw[1:0] : w_colw[3:2];     // t16:337-338
  wire         w_fx    = w_attr[0] ^ r_flip;
  wire         w_fy    = w_attr[1] ^ r_flip;

  // y position from word 3 (spr_q = word 3 in W_HIT), registered as w_ypos;
  // the hit test runs on w_ypos in W_HIT2
  wire  [10:0] y_raw   = {2'd0, spr_q[8:0]};
  wire  [10:0] y_sgn   = spr_q[8] ? y_raw - 11'd512 : y_raw;
  wire  [10:0] y_h8    = 11'd8 << w_ly;                          // 8 x cells
  wire  [10:0] y_fl0   = 11'd256 - y_h8 - y_sgn;
  wire  [10:0] y_fl    = ($signed(y_fl0) <= -11'sd256) ? y_fl0 + 11'd512 : y_fl0;
  wire  [10:0] y_pos   = r_flip ? y_fl : y_sgn;
  wire  [10:0] y_d     = {3'd0, r_line} - w_ypos;
  wire         y_hit   = !y_d[10] && y_d < y_h8;
  wire  [2:0]  y_cell  = y_d[5:3];
  wire  [2:0]  y_hm1   = 3'((11'd1 << w_ly) - 11'd1);
  // x on the word-4 cycle (spr_q = word 4)
  wire  [10:0] x_raw   = {2'd0, spr_q[8:0]};
  wire  [10:0] x_sgn   = spr_q[8] ? x_raw - 11'd512 : x_raw;
  wire  [10:0] x_w8    = 11'd8 << w_lx;
  wire  [10:0] x_fl0   = 11'd256 - x_w8 - x_sgn;
  wire  [10:0] x_fl    = ($signed(x_fl0) <= -11'sd256) ? x_fl0 + 11'd512 : x_fl0;
  wire  [10:0] x_pos   = r_flip ? x_fl : x_sgn;
  // tile number with the size bits cleared (spr:125-130)
  wire  [15:0] n_mask  = ~{10'd0, (w_ly >= 2'd3), (w_lx >= 2'd3), (w_ly >= 2'd2), (w_lx >= 2'd2),
                                  (w_ly >= 2'd1), (w_lx >= 2'd1)};

  // ---- hit queue: {x[10:0], lx[1:0], fx, num[14:0], row[2:0], ln[2:0], prio[1:0], blend, pal[3:0]}
  logic        h_push, h_pop, h_empty, h_full;
  logic [41:0] h_d, h_q;
  logic [4:0]  h_count;
  t16_fifo #(.W(42), .DEPTH(16)) u_hits (
      .clk, .clr(!rst_n), .push(h_push), .d(h_d), .pop(h_pop), .q(h_q),
      .empty(h_empty), .full(h_full), .count(h_count));

  // ---- request tags (one per accepted ROM request):
  //      {layer[1:0], x0[10:0], dir, wide, attr[6:0]}
  logic        m_push, m_pop, m_empty, m_full;
  logic [21:0] m_d, m_q;
  logic [3:0]  m_count;
  t16_fifo #(.W(22), .DEPTH(8)) u_tags (
      .clk, .clr(!rst_n), .push(m_push), .d(m_d), .pop(m_pop), .q(m_q),
      .empty(m_empty), .full(m_full), .count(m_count));

  // ---- returned words
  logic        d_pop, d_empty;
  logic [31:0] d_q;
  /* verilator lint_off PINCONNECTEMPTY */
  t16_fifo #(.W(32), .DEPTH(8)) u_ret (
      .clk, .clr(!rst_n), .push(i_rom_rv), .d(i_rom_data), .pop(d_pop), .q(d_q),
      .empty(d_empty), .full(), .count());
  /* verilator lint_on PINCONNECTEMPTY */

  // ---- sprite line buffer clear (the pass's half, before any sprite pixel)
  logic [8:0]  clr_i;
  wire         clr_done = clr_i[8];

  // ---- sprite fetcher: one request per 8 x 8 cell of the hit's row
  logic [2:0]  f_c;
  wire  [10:0] h_x     = h_q[41:31];
  wire  [1:0]  h_lx    = h_q[30:29];
  wire         h_fx    = h_q[28];
  wire  [14:0] h_num   = h_q[27:13];
  wire  [2:0]  h_row   = h_q[12:10];
  wire  [2:0]  h_ln    = h_q[9:7];
  wire  [6:0]  h_attr  = h_q[6:0];
  wire  [2:0]  h_wm1   = 3'((4'd1 << h_lx) - 4'd1);
  wire  [2:0]  f_col   = h_fx ? h_wm1 - f_c : f_c;
  // cell offset = interleave of row and column bits (the layout table, spr:41-51)
  wire  [5:0]  f_lay   = {h_row[2], f_col[2], h_row[1], f_col[1], h_row[0], f_col[0]};
  wire  [14:0] f_tile  = h_num + {9'd0, f_lay};                 // modulo the 32,768 tiles
  wire  [21:0] f_addr  = SPR_BASE + {2'd0, f_tile, h_ln, 2'b00};
  wire  [10:0] f_x0    = h_x + {5'd0, f_c, 3'd0} + (h_fx ? 11'd7 : 11'd0);
  wire         f_req   = t_done && clr_done && !h_empty && busy;

  assign o_rom_req  = (t_req || f_req) && !m_full;
  assign o_rom_addr = t_req ? t_addr : f_addr;
  wire   accept     = o_rom_req && i_rom_gnt;
  assign m_push     = accept;
  assign m_d        = t_req ? {t_layer, 1'b0, t_x0, r_flip, t_wm[9], t_attr}
                            : {2'd3, f_x0, h_fx, 1'b0, h_attr};
  assign h_pop      = accept && !t_req && f_c == h_wm1;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      busy <= 1'b0;
      pend <= 1'b0;
      t_st <= T_IDLE;
      t_done <= 1'b1;
      w_st <= W_IDLE;
      w_done <= 1'b1;
      f_c <= '0;
      clr_i <= 9'h100;
      cyc <= '0;
      maxcyc <= '0;
      overruns <= '0;
    end else begin
      // ---- line start / overrun bookkeeping
      if (want_line && busy) begin
        overruns <= overruns + 16'd1;
        pend <= 1'b1;
        pend_line <= next_line;
      end else if (go) pend <= 1'b0;

      if (go) begin
        busy <= 1'b1;
        r_line <= go_line[7:0];
        r_srcy <= v_flip ? 8'd255 - go_line[7:0] : go_line[7:0];
        r_flip <= v_flip;
        r_txx <= v_txx; r_txy <= v_txy;
        r_fgx <= v_fgx; r_fgy <= v_fgy;
        r_bgx <= v_bgx; r_bgy <= v_bgy;
        t_st <= T_ADDR;
        t_layer <= 2'd0;
        t_k <= '0;
        t_j <= 1'b0;
        t_done <= 1'b0;
        w_st <= W_A0;
        w_e <= '0;
        w_done <= 1'b0;
        f_c <= '0;
        clr_i <= '0;
        cyc <= '0;
      end else if (busy) begin
        cyc <= cyc + 16'd1;
        if (t_done && w_done && h_empty && m_empty && d_empty && clr_done) begin
          busy <= 1'b0;
          if (cyc > maxcyc) maxcyc <= cyc;
        end
      end

      if (!go && !clr_done) clr_i <= clr_i + 9'd1;

      // ---- tile issuer: tile RAM read, then 2 (bg, fg) or 1 (text) requests
      case (t_st)
        T_ADDR: t_st <= T_WAIT;
        T_WAIT: begin
          t_code <= t_tx ? char_q : t_fg ? fgv_q : bgv_q;
          t_col  <= t_fg ? fgc_q : bgc_q;
          t_st <= T_ISS;
        end
        T_ISS: if (accept) begin
          if (!t_tx && !t_j) t_j <= 1'b1;
          else begin
            t_j <= 1'b0;
            if (t_k == t_last) begin
              t_k <= '0;
              if (t_layer == 2'd2) begin
                t_st <= T_IDLE;
                t_done <= 1'b1;
              end else begin
                t_layer <= t_layer + 2'd1;
                t_st <= T_ADDR;
              end
            end else begin
              t_k <= t_k + 6'd1;
              t_st <= T_ADDR;
            end
          end
        end
        default: ;
      endcase

      // ---- sprite walker: each state presents the next word address; the
      // word arrives on spr_q in the following state
      if (!go) begin
        case (w_st)
          W_A0: w_st <= W_A2;                       // word 0 on its way
          W_A2: begin                               // spr_q = word 0
            w_attr <= spr_q;
            if (!spr_q[2]) begin                    // not enabled (spr:91)
              if (w_e == 8'd255) w_st <= W_IDLE;
              else begin
                w_e <= w_e + 8'd1;
                w_st <= W_A0;
              end
            end else w_st <= W_A3;
          end
          W_A3: begin                               // spr_q = word 2
            w_colw <= spr_q;
            w_st <= W_HIT;
          end
          W_HIT: begin                              // spr_q = word 3
            w_ypos <= y_pos;
            w_st <= W_HIT2;
          end
          W_HIT2: begin                             // hit test on w_ypos
            if (y_hit) begin
              w_row <= w_fy ? y_hm1 - y_cell : y_cell;
              w_ln  <= w_fy ? 3'd7 - y_d[2:0] : y_d[2:0];
              w_st <= W_A4;
            end else if (w_e == 8'd255) w_st <= W_IDLE;
            else begin
              w_e <= w_e + 8'd1;
              w_st <= W_A0;
            end
          end
          W_A4: begin                               // spr_q = word 1
            w_num <= spr_q & n_mask;
            w_st <= W_PUSH;
          end
          W_PUSH: if (!h_full) begin                // spr_q = word 4, pushed this clock
            if (w_e == 8'd255) w_st <= W_IDLE;
            else begin
              w_e <= w_e + 8'd1;
              w_st <= W_A0;
            end
          end
          default: ;
        endcase
        if (w_st == W_IDLE) w_done <= 1'b1;
      end

      // ---- fetcher cell counter
      if (accept && !t_req) f_c <= (f_c == h_wm1) ? 3'd0 : f_c + 3'd1;
    end
  end

  // word address on the sprite list port for the walker's next read
  always_comb begin
    case (w_st)
      W_A0:   spr_va = {w_e, 3'd0};
      W_A2:   spr_va = {w_e, 3'd2};
      W_A3:   spr_va = {w_e, 3'd3};
      W_HIT:  spr_va = {w_e, 3'd1};
      W_HIT2: spr_va = {w_e, 3'd1};
      W_A4:   spr_va = {w_e, 3'd4};
      W_PUSH: spr_va = {w_e, 3'd4};
      default: spr_va = {w_e, 3'd0};
    endcase
  end
  // the word arriving in a state is the one addressed in the previous state:
  // W_A0 -> word 0 in W_A2 (address presented in W_A0), W_A2 -> word 2 in
  // W_A3, W_A3 -> word 3 in W_HIT, W_HIT2 -> word 1 in W_A4 (W_HIT presents
  // the same address), W_A4 -> word 4 in W_PUSH
  assign h_push = !go && w_st == W_PUSH && !h_full && busy;
  assign h_d    = {x_pos, w_lx, w_fx, w_num[14:0], w_row, w_ln,
                   w_attr[7:6], w_attr[5], w_colw[7:4]};

  // ---- writer: one pixel per clock from the returned words
  logic [2:0]  wb;
  wire  [3:0]  pix    = d_q[31 - 4 * wb -: 4];
  wire  [1:0]  w_lay  = m_q[21:20];
  wire         is_sp  = w_lay == 2'd3;
  wire         w_dir  = m_q[8];
  wire         w_wide = m_q[7];
  wire  [6:0]  w_at   = m_q[6:0];
  wire  [10:0] wx_s   = w_dir ? m_q[19:9] - {8'd0, wb} : m_q[19:9] + {8'd0, wb};
  wire  [9:0]  wx_t0  = w_dir ? m_q[18:9] - {7'd0, wb} : m_q[18:9] + {7'd0, wb};
  wire  [9:0]  wx_t   = wx_t0 & (w_wide ? 10'h3FF : 10'h1FF);
  wire         wvis   = is_sp ? (wx_s[10:8] == 3'd0 && pix != 4'd0) : wx_t[9:8] == 2'd0;
  wire         wact   = !d_empty && !m_empty;
  wire  [7:0]  wx     = is_sp ? wx_s[7:0] : wx_t[7:0];
  wire  [8:0]  lb_wa  = {r_line[0], wx};
  wire         wr_en  = wact && wvis;
  assign d_pop = wact && wb == 3'd7;
  assign m_pop = d_pop;
  always_ff @(posedge clk) begin
    if (!rst_n) wb <= '0;
    else if (wact) wb <= wb + 3'd1;
  end

  assign o_dbg_overruns = overruns;
  assign o_dbg_maxcyc   = maxcyc;

  // ---- line buffers: port A written by the writer, port B read by scan-out.
  // A transparent tile pixel (pen 0) is stored as 0, colour bits included:
  // MAME draws each tilemap into a bitmap cleared to 0 and skips pen 0
  // (t16:199-201, 314-328), and one mixer branch reads the bg value even
  // when the bg pixel is transparent (mix:157-162: above-bg blended sprite
  // over a blended fg pixel, which MAME marks "WRONG??" and "needs if
  // bgpixel & 0xf check?").
  wire  [15:0] tile_wd = (pix == 4'd0) ? 16'd0 : {7'd0, w_at[4:0], pix};
  wire  [8:0]  lb_ra = {vcnt[0], hcnt[7:0]};
  logic [15:0] lbq_bg, lbq_fg, lbq_tx, lbq_sp;
  /* verilator lint_off PINCONNECTEMPTY */
  t16_dpram #(.AW(9), .DW(16)) u_lb_bg (
      .clk, .addr_a(lb_wa), .d_a({8'd0, tile_wd[7:0]}), .we_a(wr_en && w_lay == 2'd0), .be_a(2'b11),
      .q_a(), .addr_b(lb_ra), .q_b(lbq_bg));
  t16_dpram #(.AW(9), .DW(16)) u_lb_fg (
      .clk, .addr_a(lb_wa), .d_a(tile_wd), .we_a(wr_en && w_lay == 2'd1), .be_a(2'b11),
      .q_a(), .addr_b(lb_ra), .q_b(lbq_fg));
  t16_dpram #(.AW(9), .DW(16)) u_lb_tx (
      .clk, .addr_a(lb_wa), .d_a({8'd0, tile_wd[7:0]}), .we_a(wr_en && w_lay == 2'd2), .be_a(2'b11),
      .q_a(), .addr_b(lb_ra), .q_b(lbq_tx));
  t16_dpram #(.AW(9), .DW(16)) u_lb_sp (
      .clk, .addr_a(clr_done ? lb_wa : {r_line[0], clr_i[7:0]}),
      .d_a(clr_done ? {5'd0, w_at, pix} : 16'd0),
      .we_a(clr_done ? (wr_en && is_sp) : busy), .be_a(2'b11),
      .q_a(), .addr_b(lb_ra), .q_b(lbq_sp));
  /* verilator lint_on PINCONNECTEMPTY */

  // ================================================================ mixer
  // tecmo_mix.cpp:70-323 with tecmo16's configuration (t16:693-698, spec 9):
  // sprite priority bits XOR 3, regular palettes bg 0x300 fg 0x200 text
  // 0x100 sprites 0x000, blend palettes bg 0x700 fg 0x600 text 0x500 sprites
  // 0x400, blend sources sprites 0x800 fg 0x900, background pen 0x300
  // (blend 0x700). Blended pixels add two palette colours per channel with
  // saturation (mix:47-68; equal in 4 bits to MAME's 8-bit sum after
  // (c << 4) | c expansion). The four branches where MAME writes
  // machine().rand() (mix:120, 137, 214, 261) take the branch below them
  // (deterministic, research item R6; the same choice as jtgaiden_priority).
  logic [11:0] mx_a, mx_b;
  logic        mx_bl;
  always_comb begin
    logic [3:0] bgpn, fgpn, txpn, sppn;
    logic [7:0] bgp, fgp, txp, spix;
    logic       fgbln, sbl, bg_on, fg_on, tx_on, sp_on;
    logic [1:0] pri;
    bgp  = lbq_bg[7:0];
    fgp  = lbq_fg[7:0];
    fgbln = lbq_fg[8];
    txp  = lbq_tx[7:0];
    spix = lbq_sp[7:0];
    sbl  = lbq_sp[8];
    pri  = lbq_sp[10:9];
    bgpn = bgp[3:0]; fgpn = fgp[3:0]; txpn = txp[3:0]; sppn = spix[3:0];
    bg_on = bgpn != 4'd0;
    fg_on = fgpn != 4'd0;
    tx_on = txpn != 4'd0;
    sp_on = sppn != 4'd0;
    mx_a = 12'h300;
    mx_b = 12'h000;
    mx_bl = 1'b0;
    if (sp_on && pri == 2'd3) begin                 // behind everything (mix:109-145)
      if (tx_on)      mx_a = {4'h1, txp};
      else if (fg_on) mx_a = {4'h2, fgp};           // includes the fg-blend rand branch
      else if (bg_on) mx_a = {4'h3, bgp};
      else            mx_a = {4'h0, spix};          // includes the blended rand branch
    end else if (sp_on && pri == 2'd2) begin        // above bg (mix:146-197)
      if (tx_on) mx_a = {4'h1, txp};
      else if (fg_on && fgbln && sbl) begin mx_a = {4'h7, bgp}; mx_b = {4'h8, spix}; mx_bl = 1'b1; end
      else if (fg_on && fgbln) begin mx_a = {4'h9, fgp}; mx_b = {4'h4, spix}; mx_bl = 1'b1; end
      else if (fg_on) mx_a = {4'h2, fgp};
      else if (sbl && bg_on) begin mx_a = {4'h7, bgp}; mx_b = {4'h8, spix}; mx_bl = 1'b1; end
      else if (sbl) begin mx_a = 12'h700; mx_b = {4'h8, spix}; mx_bl = 1'b1; end
      else mx_a = {4'h0, spix};
    end else if (sp_on && pri == 2'd1) begin        // above bg and fg (mix:198-243)
      if (tx_on) mx_a = {4'h1, txp};
      else if (sbl && fg_on) begin mx_a = {4'h6, fgp}; mx_b = {4'h8, spix}; mx_bl = 1'b1; end
      else if (sbl && bg_on) begin mx_a = {4'h7, bgp}; mx_b = {4'h8, spix}; mx_bl = 1'b1; end
      else if (sbl) begin mx_a = 12'h700; mx_b = {4'h8, spix}; mx_bl = 1'b1; end
      else mx_a = {4'h0, spix};
    end else if (sp_on) begin                       // above all (mix:245-285)
      if (sbl && tx_on) begin mx_a = {4'h5, txp}; mx_b = {4'h8, spix}; mx_bl = 1'b1; end
      else if (sbl && fg_on) begin mx_a = {4'h6, fgp}; mx_b = {4'h8, spix}; mx_bl = 1'b1; end
      else if (sbl && bg_on) begin mx_a = {4'h7, bgp}; mx_b = {4'h8, spix}; mx_bl = 1'b1; end
      else if (sbl) begin mx_a = 12'h700; mx_b = {4'h8, spix}; mx_bl = 1'b1; end
      else mx_a = {4'h0, spix};
    end else begin                                  // no sprite pixel (mix:287-320)
      if (tx_on) mx_a = {4'h1, txp};
      else if (fg_on && fgbln && bg_on) begin mx_a = {4'h9, fgp}; mx_b = {4'h7, bgp}; mx_bl = 1'b1; end
      else if (fg_on && fgbln) begin mx_a = {4'h9, fgp}; mx_b = 12'h700; mx_bl = 1'b1; end
      else if (fg_on) mx_a = {4'h2, fgp};
      else if (bg_on) mx_a = {4'h3, bgp};
      else mx_a = 12'h300;
    end
  end

  // ================================================================ scan-out
  // Phase within the pixel (16 clocks): 0 line buffers addressed by the
  // counters, 1 mixer result registered, 2-3 palette entry A, 3-4 entry B,
  // 5 final colour; registered at the next pixel enable (one pixel of
  // pipeline delay on every output).
  logic [3:0]  ph;
  logic [11:0] ma, mb;
  logic        mbl;
  logic [11:0] col_a, col_b, col_f;
  logic [35:0] lay1;
  always_ff @(posedge clk) begin
    if (ce_pix) ph <= 4'd0;
    else if (ph != 4'd15) ph <= ph + 4'd1;
  end
  assign pal_va = (ph == 4'd2) ? ma : mb;
  function automatic [3:0] sat4(input [3:0] a, input [3:0] b);
    logic [4:0] s;
    s = {1'b0, a} + {1'b0, b};
    sat4 = s[4] ? 4'hF : s[3:0];
  endfunction
  always_ff @(posedge clk) begin
    if (ph == 4'd1) begin
      lay1 <= {lbq_sp[10:0], lbq_tx[7:0], lbq_fg[8:0], lbq_bg[7:0]};
      ma <= mx_a;
      mb <= mx_b;
      mbl <= mx_bl;
    end
    if (ph == 4'd3) col_a <= pal_q[11:0];
    if (ph == 4'd4) col_b <= pal_q[11:0];
    if (ph == 4'd5)
      col_f <= mbl ? {sat4(col_a[11:8], col_b[11:8]), sat4(col_a[7:4], col_b[7:4]), sat4(col_a[3:0], col_b[3:0])}
                   : col_a;
  end

  always_ff @(posedge clk) begin
    if (tim_rst) begin
      o_de <= 1'b0;
      o_hblank <= 1'b1;
      o_vblank <= 1'b1;
      o_hs <= 1'b0;
      o_vs <= 1'b0;
    end else if (ce_pix) begin
      o_de     <= hcnt < 9'(H_ACT) && vcnt >= 9'(V_VIS0) && vcnt <= 9'(V_VIS1);
      o_hblank <= hcnt >= 9'(H_ACT);
      o_vblank <= vcnt < 9'(V_VIS0) || vcnt > 9'(V_VIS1);
      o_hs     <= hcnt >= 9'(HS_START) && hcnt < 9'(HS_END);
      o_vs     <= vcnt >= 9'(VS_START) && vcnt < 9'(VS_START + 3);
      // xBGR_444 (t16:688): R bits 0-3, G 4-7, B 8-11, 4 to 8 bits as (c << 4) | c
      // black while the core is held in reset (FREE_TIMING keeps sync running)
      o_r <= (rst_n || !FREE_TIMING) ? {col_f[3:0], col_f[3:0]}   : 8'd0;
      o_g <= (rst_n || !FREE_TIMING) ? {col_f[7:4], col_f[7:4]}   : 8'd0;
      o_b <= (rst_n || !FREE_TIMING) ? {col_f[11:8], col_f[11:8]} : 8'd0;
      o_dbg_lay <= lay1;
    end
  end

endmodule
