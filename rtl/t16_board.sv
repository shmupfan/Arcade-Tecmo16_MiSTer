// Tecmo 16 board (PLAN M4): everything below the MiSTer framework.
// t16_sys (68000, Z80 sound board, video, YM2151, M6295) + t16_sdram, plus
// the ioctl download handling, so the board simulation runs exactly what
// the RBF contains.
//
// ioctl indices (MRA, tools/make_mra.py):
//   0    ROM stream = the SDRAM image of PLAN 4.3 from byte 0 (each MRA is
//        proven to reproduce sim/build/regions/<set>/sdram.bin). While the
//        audiocpu region (0x2A0000-0x2AFFFF) streams past, its bytes are
//        also written into t16_sys's sound ROM (block RAM, i_snd_dl_*).
//   1    machine byte: 0 Final Star Force, 1 Riot, 2 Ganbare Ginkun (the
//        MAME machine configs base, riot, ginkun). Sampled while the core
//        is held in reset.
//   254  DIP switches: byte 0 = DSW1, byte 1 = DSW2 (each the switch byte
//        in the low half of its 16-bit port, as MAME reads them)
// The core is held in reset during any download and until the SDRAM is
// initialised.
//
// Program ROM: 512 KB, served by t16_sdram from its own bank; t16_sys needs
// the word within 17 clocks of the request (m2_findings 3), the controller
// answers within 10.

module t16_board #(
    parameter int  CLK_HZ     = 96000000,
    // pixel enable fraction and lines per frame: MAME's raster by default
    // (59.17 Hz, 256 lines drawn as 384 pixel periods per line, the M2 gate
    // configuration); 1/16 and 264 give the 6 MHz 384 x 264 alternative
    // (research item R3, decision pending)
    parameter int  PIX_NUM    = 47336,
    parameter int  PIX_DEN    = 781250,
    parameter int  V_TOTAL    = 256,
    parameter int  IRQ_HOLD   = 96000,
    parameter bit  SHORT_INIT = 1'b0
) (
    input  logic        clk,
    input  logic        i_sdram_rst_n,  // PLL locked
    input  logic        i_reset,

    input  logic        i_ioctl_download,
    input  logic        i_ioctl_wr,
    input  logic [26:0] i_ioctl_addr,
    input  logic [7:0]  i_ioctl_dout,
    input  logic [15:0] i_ioctl_index,
    output logic        o_ioctl_wait,

    // inputs in MAME's port layout (spec, m2_findings 2.1): P1_P2 idle
    // 0x3FFF (coins active high in bits 14-15), EXTRA 0xFFFF on Riot (button
    // 1 in bits 1 and 5, active low) and 0x0000 on the others
    input  logic [15:0] i_p1p2,
    input  logic [15:0] i_extra,
    input  logic        i_pause,        // OSD / key pause (t16_sys holds CPU and sound enables)

    output logic [7:0]  o_r,
    output logic [7:0]  o_g,
    output logic [7:0]  o_b,
    output logic        o_hblank,
    output logic        o_vblank,
    output logic        o_hs,
    output logic        o_vs,
    output logic        o_de,
    output logic        o_ce_pix,
    output logic signed [15:0] o_left,
    output logic signed [15:0] o_right,
    output logic [1:0]  o_machine,
    output logic        o_vbl,          // sim/debug: one clock at the start of line 240
    output logic        o_vid_busy,     // sim/debug: sprite copy running
    output logic [23:0] o_cpu_pc_dbg,   // sim/debug

    // gate counters
    output logic [15:0] o_dbg_overruns,
    output logic [15:0] o_dbg_maxcyc,
    output logic [15:0] o_dbg_ref_forced,
    output logic [7:0]  o_dbg_cpu_maxlat,
    output logic [7:0]  o_dbg_verr,
    output logic [15:0] o_dbg_rom_writes,
    output logic [15:0] o_dbg_unmapped,
    output logic [15:0] o_dbg_prom_late,
    output logic [15:0] o_dbg_vreg_other,
    output logic [15:0] o_dbg_snd_unmapped,

    output logic [12:0] SDRAM_A,
    output logic [1:0]  SDRAM_BA,
    inout  wire  [15:0] SDRAM_DQ,
    output logic        SDRAM_DQML,
    output logic        SDRAM_DQMH,
    output logic        SDRAM_nCS,
    output logic        SDRAM_nRAS,
    output logic        SDRAM_nCAS,
    output logic        SDRAM_nWE,
    output logic        SDRAM_CKE
);

  // ------------------------------------------------------------------ ioctl
  wire rom_wr = i_ioctl_download && i_ioctl_wr && i_ioctl_index[7:0] == 8'd0;

  /* verilator lint_off PROCASSINIT */
  logic [1:0] machine = 2'd0;           // power-on values, as Dooyong
  logic [7:0] dsw0 = 8'hFF, dsw1 = 8'hFF;
  /* verilator lint_on PROCASSINIT */
  always_ff @(posedge clk) begin
    if (i_ioctl_wr && i_ioctl_index[7:0] == 8'd1 && i_ioctl_addr == 27'd0)
      machine <= i_ioctl_dout[1:0];
    if (i_ioctl_wr && i_ioctl_index[7:0] == 8'd254) begin
      if (i_ioctl_addr == 27'd0) dsw0 <= i_ioctl_dout;
      if (i_ioctl_addr == 27'd1) dsw1 <= i_ioctl_dout;
    end
  end
  assign o_machine = machine;

  // sound CPU ROM: the audiocpu region of the stream, registered once
  logic        snd_we;
  logic [15:0] snd_addr;
  logic [7:0]  snd_data;
  always_ff @(posedge clk) begin
    snd_we   <= rom_wr && i_ioctl_addr[26:16] == 11'h02A;
    snd_addr <= i_ioctl_addr[15:0];
    snd_data <= i_ioctl_dout;
  end

  // ------------------------------------------------------------------ SDRAM
  logic        core_rst_n;
  logic        core_run;
  logic        sd_ready;
  logic        prom_req, prom_ok;
  logic [18:1] prom_addr;
  logic [15:0] prom_data;
  logic        rom_req, rom_gnt, rom_rv;
  logic [21:0] rom_addr;
  logic [31:0] rom_data;
  logic [17:0] oki_addr;
  logic [7:0]  oki_data;
  logic        oki_ok;

  t16_sdram #(.P_SHORT_INIT(SHORT_INIT), .REFRESH_PERIOD(CLK_HZ / 128000),
              .INIT_CYCLES(CLK_HZ / 10000)) u_sdram (
    .clk(clk), .rst_n(i_sdram_rst_n), .o_ready(sd_ready),
    .i_dl_wr(rom_wr), .i_dl_addr(i_ioctl_addr[21:0]), .i_dl_data(i_ioctl_dout),
    .o_dl_busy(o_ioctl_wait),
    .i_cpu_run(core_run), .i_cpu_req(prom_req), .i_cpu_addr(prom_addr), .o_cpu_data(prom_data), .o_cpu_ok(prom_ok),
    .i_gfx_req(rom_req), .i_gfx_addr(rom_addr), .o_gfx_gnt(rom_gnt),
    .o_gfx_rv(rom_rv), .o_gfx_data(rom_data),
    .i_oki_addr(oki_addr), .o_oki_data(oki_data), .o_oki_ok(oki_ok),
    .o_dbg_refreshes(), .o_dbg_ref_forced(o_dbg_ref_forced),
    .o_dbg_cpu_maxlat(o_dbg_cpu_maxlat), .o_dbg_dl_words(),
    .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ),
    .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
    .SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE));

  // ------------------------------------------------------------------ core
  always_ff @(posedge clk) core_rst_n <= !i_reset && !i_ioctl_download && sd_ready;

  t16_sys #(.CLK_HZ(CLK_HZ), .PIX_NUM(PIX_NUM), .PIX_DEN(PIX_DEN), .V_TOTAL(V_TOTAL),
            .IRQ_HOLD(IRQ_HOLD), .FREE_TIMING(1'b1)) u_sys (
    // FREE_TIMING: sync keeps running (black picture) during the ROM
    // download and SDRAM init instead of stopping, so the MiSTer scaler
    // never loses the signal (Dooyong showed a green "no input" screen);
    // t16_sys releases the core on the raster's power-on phase (core_run).
    .clk(clk), .rst_n(core_rst_n), .i_pwr_rst_n(i_sdram_rst_n), .o_run(core_run),
    .i_machine(machine), .i_pause(i_pause),
    .o_prom_req(prom_req), .o_prom_addr(prom_addr), .i_prom_data(prom_data), .i_prom_ok(prom_ok),
    .o_rom_req(rom_req), .o_rom_addr(rom_addr),
    .i_rom_gnt(rom_gnt), .i_rom_rv(rom_rv), .i_rom_data(rom_data),
    .i_snd_dl_we(snd_we), .i_snd_dl_addr(snd_addr), .i_snd_dl_data(snd_data),
    .o_oki_addr(oki_addr), .i_oki_data(oki_data), .i_oki_ok(oki_ok),
    .i_p1p2(i_p1p2), .i_dsw1({8'h00, dsw0}), .i_dsw2({8'h00, dsw1}), .i_extra(i_extra),
    .o_r(o_r), .o_g(o_g), .o_b(o_b), .o_de(o_de),
    .o_hblank(o_hblank), .o_vblank(o_vblank), .o_hs(o_hs), .o_vs(o_vs), .o_ce_pix(o_ce_pix),
    .o_vbl(o_vbl), .o_vid_busy(o_vid_busy),
    .o_left(o_left), .o_right(o_right),
    .o_dbg_overruns(o_dbg_overruns), .o_dbg_maxcyc(o_dbg_maxcyc), .o_dbg_verr(o_dbg_verr),
    .o_dbg_rom_writes(o_dbg_rom_writes), .o_dbg_unmapped(o_dbg_unmapped), .o_dbg_prom_late(o_dbg_prom_late),
    .o_dbg_vreg_other(o_dbg_vreg_other), .o_dbg_snd_unmapped(o_dbg_snd_unmapped),
    .o_cpu_pc_dbg(o_cpu_pc_dbg));

endmodule
