// Tecmo 16 main system (PLAN M2; Final Star Force, Riot, Ganbare Ginkun):
// 68000 (fx68k), work RAMs, memory map, IRQ5, sound latch, inputs, the
// video (t16_video) and the sound board (t16_snd).
//
// Spec sections are docs/tecmo16_system_spec.md; "t16:n" lines are
// reference/mame/tecmo16.cpp.
//
// Clocks: one system clock (CLK_HZ, 96 MHz on hardware). Every enable is
// fractional, so the ratios hold at any system clock:
//   - pixel enable PIX_NUM / PIX_DEN of the clock. Hardware default 1/16
//     (6 MHz, the 384 x 264 raster MAME's TODO guesses, t16:20, research item
//     R3). MAME parity (the M2 gate): 47336 / 781250 with V_TOTAL = 256, which
//     is exactly MAME's 59.17 Hz frame of 256 lines (t16:679-681) drawn as
//     384 pixel periods per line (m2_findings 2)
//   - 68000 two-phase enables at 2 x 12 MHz (24 MHz / 2, t16:663)
//   - sound board enables in t16_snd
// i_pause stops the 68000 and the sound board; the video keeps scanning.
//
// Bus: no wait states (MAME's memory model). The program ROM is external
// (512 KB, SDRAM on the board): a program read asserts DTACK at once like
// every other read and keeps loading i_prom_data into the read latch until
// i_prom_ok. fx68k captures read data on every phi2 from T3 until the cycle
// ends (rtl/vendor/fx68k/fx68k.sv busControl), last at AS + 20 clocks at
// 96 MHz (2.5 CPU clocks of 8), so a ROM that answers within PROM_LIMIT
// gives the right word with no wait state, as a zero-wait EPROM would.
// o_dbg_prom_late counts program reads whose ok came too late (must stay 0;
// the M2 harness models the M4 SDRAM latency, 9 clocks by default).
//
// Memory map (spec 3; t16:368-417), byte addresses, exact decodes, no mirrors
// (MAME maps none). Unmapped reads return 0 (MAME's unmap value) and
// unmapped writes are ignored; both are counted in o_dbg_unmapped.
//   0x000000-0x07ffff  program ROM (writes ignored, counted)
//   0x100000-0x103fff  main RAM 16 KB
//   0x110000-0x110fff  text RAM
//   Final Star Force (i_machine 0, fstarfrc_map t16:395-405):
//     0x120000 fg codes, 0x120800 fg colours, 0x121000 bg codes,
//     0x121800 bg colours (2 KB each), 0x122000-0x127fff work RAM 24 KB
//   Riot / Ginkun (i_machine 1 / 2, ginkun_map t16:407-417):
//     0x120000 fg codes, 0x121000 fg colours, 0x122000 bg codes,
//     0x123000 bg colours (4 KB each), 0x124000-0x124fff extra RAM 4 KB
//   0x130000-0x130fff  sprite RAM
//   0x140000-0x141fff  palette
//   0x150000-0x150001  W flip screen: data bit 0, any byte lane (the handler
//                      takes the 16-bit value without a mask, t16:276-279;
//                      byte writes carry the byte on both lanes)
//   0x150011           W sound latch (low byte, t16:379)
//   0x150020-0x150021  R EXTRA; W clears IRQ5 (t16:354-360)
//   0x150030-0x150031  R DSW2; W no effect (t16:362-366), counted per frame
//   0x150040-0x150041  R DSW1
//   0x150050-0x150051  R P1_P2
//   0x160000-0x16001f  W scroll registers at word offsets 0, 3, 6, 9, 12, 15
//                      (t16:385-390); writes to the other ten words are
//                      ignored as in MAME and counted in o_dbg_vreg_other
//                      (research item R9); reads are unmapped (0x160000 is
//                      read at scene changes by Final Star Force, R7)
//
// IRQ5 (spec 4): the line follows the screen's vblank signal in MAME
// (t16:684): asserted at the start of line 240 and released IRQ_HOLD clocks
// later, or earlier by a write to 0x150020-0x150021. Level-held, so the
// 68000 takes it again after each RTE while it stays asserted (Final Star
// Force never acknowledges it and takes 1 to 5 per frame in MAME). Default
// IRQ_HOLD = MAME's 1000 us vblank (t16:680, "not accurate"; R3).
// Autovectored (VPA), as MAME's default for the 68000.

module t16_sys #(
    parameter int CLK_HZ   = 96000000,
    parameter int PIX_NUM  = 1,
    parameter int PIX_DEN  = 16,
    parameter int V_TOTAL  = 264,
    parameter int IRQ_HOLD = 96000,       // clocks: 1000 us at 96 MHz
    parameter bit LATCH    = 1'b0         // t16_video LATCH (Lee 2026-10-02: live)
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [1:0]  i_machine,       // 0 Final Star Force, 1 Riot, 2 Ginkun
    input  logic        i_pause,

    // program ROM (512 KB, 16-bit words, high byte = even address)
    output logic        o_prom_req,
    output logic [18:1] o_prom_addr,
    input  logic [15:0] i_prom_data,
    input  logic        i_prom_ok,

    // graphics ROM port (t16_video; byte address in the PLAN 4.3 layout)
    output logic        o_rom_req,
    output logic [21:0] o_rom_addr,
    input  logic        i_rom_gnt,
    input  logic        i_rom_rv,
    input  logic [31:0] i_rom_data,

    // sound ROM download (64 KB) and M6295 ROM (256 KB)
    input  logic        i_snd_dl_we,
    input  logic [15:0] i_snd_dl_addr,
    input  logic [7:0]  i_snd_dl_data,
    output logic [17:0] o_oki_addr,
    input  logic [7:0]  i_oki_data,
    input  logic        i_oki_ok,

    // inputs (spec 11): P1_P2 (joysticks and buttons active low, coins
    // active high in bits 14-15), DSW1, DSW2, EXTRA (Riot's fire buttons)
    input  logic [15:0] i_p1p2,
    input  logic [15:0] i_dsw1,
    input  logic [15:0] i_dsw2,
    input  logic [15:0] i_extra,

    // video
    output logic [7:0]  o_r,
    output logic [7:0]  o_g,
    output logic [7:0]  o_b,
    output logic        o_de,
    output logic        o_hblank,
    output logic        o_vblank,
    output logic        o_hs,
    output logic        o_vs,
    output logic        o_ce_pix,
    output logic        o_vbl,           // one clock at the start of line 240
    output logic        o_vid_busy,      // a video snapshot engine is running (sprite copy)

    // audio (t16_snd)
    output logic signed [15:0] o_left,
    output logic signed [15:0] o_right,

    // gate counters
    output logic [15:0] o_dbg_overruns,
    output logic [15:0] o_dbg_maxcyc,
    output logic [7:0]  o_dbg_verr,
    output logic [15:0] o_dbg_rom_writes,
    output logic [15:0] o_dbg_unmapped,
    output logic [15:0] o_dbg_prom_late,
    output logic [15:0] o_dbg_vreg_other,
    output logic [15:0] o_dbg_snd_unmapped,
    output logic [23:0] o_cpu_pc_dbg
);

  wire base = i_machine == 2'd0;

  // ================================================================ enables
  logic        ce_pix /* verilator public_flat_rd */;
  logic [31:0] pix_acc;
  logic [27:0] m_acc;
  logic        m_ph, en_phi1, en_phi2;
  localparam int F68 = 12000000;   // 24 MHz / 2 (t16:663)
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pix_acc <= '0;
      ce_pix  <= 1'b0;
    end else if (pix_acc + 32'(PIX_NUM) >= 32'(PIX_DEN)) begin
      pix_acc <= pix_acc + 32'(PIX_NUM) - 32'(PIX_DEN);
      ce_pix  <= 1'b1;
    end else begin
      pix_acc <= pix_acc + 32'(PIX_NUM);
      ce_pix  <= 1'b0;
    end
  end
  always_ff @(posedge clk) begin
    en_phi1 <= 1'b0;
    en_phi2 <= 1'b0;
    if (!rst_n) begin
      m_acc <= '0;
      m_ph  <= 1'b0;
    end else if (!i_pause) begin
      if (m_acc + 28'(2 * F68) >= 28'(CLK_HZ)) begin
        m_acc <= m_acc + 28'(2 * F68) - 28'(CLK_HZ);
        m_ph  <= !m_ph;
        if (m_ph) en_phi2 <= 1'b1;
        else      en_phi1 <= 1'b1;
      end else
        m_acc <= m_acc + 28'(2 * F68);
    end
  end
  assign o_ce_pix = ce_pix;

  // ================================================================ 68000
  logic        m_rw /* verilator public_flat_rd */, m_asn;
  logic        m_ldsn /* verilator public_flat_rd */, m_udsn /* verilator public_flat_rd */;
  logic        m_fc0, m_fc1, m_fc2;
  logic        m_dtackn, m_vpan;
  logic [2:0]  m_ipl;
  logic [15:0] m_din;
  logic [15:0] m_dout /* verilator public_flat_rd */;
  logic [23:1] m_a /* verilator public_flat_rd */;

  fx68k u_m68k (
    .clk(clk), .HALTn(1'b1),
    .extReset(!rst_n), .pwrUp(!rst_n),
    .enPhi1(en_phi1), .enPhi2(en_phi2),
    .eRWn(m_rw), .ASn(m_asn), .LDSn(m_ldsn), .UDSn(m_udsn),
    .E(), .VMAn(),
    .FC0(m_fc0), .FC1(m_fc1), .FC2(m_fc2),
    .BGn(), .oRESETn(), .oHALTEDn(),
    .DTACKn(m_dtackn), .VPAn(m_vpan),
    .BERRn(1'b1), .BRn(1'b1), .BGACKn(1'b1),
    .IPL0n(~m_ipl[0]), .IPL1n(~m_ipl[1]), .IPL2n(~m_ipl[2]),
    .iEdb(m_din), .oEdb(m_dout), .eab(m_a));

  wire [23:0] m_ba /* verilator public_flat_rd */ = {m_a, 1'b0};
  wire        m_iack /* verilator public_flat_rd */ = m_fc2 && m_fc1 && m_fc0 && !m_asn;

  // ================================================================ decode
  wire s_rom   = m_ba[23:19] == 5'h00;                       // 000000-07ffff
  wire s_ram   = m_ba[23:14] == 10'(24'h100000 >> 14);       // 100000-103fff
  wire s_char  = m_ba[23:12] == 12'h110;
  wire s_fgv   = base ? m_ba[23:11] == 13'(24'h120000 >> 11) : m_ba[23:12] == 12'h120;
  wire s_fgc   = base ? m_ba[23:11] == 13'(24'h120800 >> 11) : m_ba[23:12] == 12'h121;
  wire s_bgv   = base ? m_ba[23:11] == 13'(24'h121000 >> 11) : m_ba[23:12] == 12'h122;
  wire s_bgc   = base ? m_ba[23:11] == 13'(24'h121800 >> 11) : m_ba[23:12] == 12'h123;
  // Final Star Force work RAM 0x122000-0x127fff; Riot/Ginkun 0x124000-0x124fff
  wire s_work  = base ? (m_ba[23:15] == 9'(24'h120000 >> 15) && m_ba[14:13] != 2'b00)
                      : m_ba[23:12] == 12'h124;
  wire s_spr   = m_ba[23:12] == 12'h130;
  wire s_pal   = m_ba[23:13] == 11'(24'h140000 >> 13);
  wire s_flip  = m_ba[23:1] == 23'(24'h150000 >> 1);
  wire s_latch = m_ba[23:1] == 23'(24'h150010 >> 1);
  wire s_x21   = m_ba[23:1] == 23'(24'h150020 >> 1);
  wire s_x31   = m_ba[23:1] == 23'(24'h150030 >> 1);
  wire s_dsw1  = m_ba[23:1] == 23'(24'h150040 >> 1);
  wire s_p12   = m_ba[23:1] == 23'(24'h150050 >> 1);
  wire s_vreg  = m_ba[23:5] == 19'(24'h160000 >> 5);
  wire s_tile  = s_fgv || s_fgc || s_bgv || s_bgc;
  // mapped for reads / for writes (write-only and read-only ports differ)
  wire s_rd_ok = s_rom || s_ram || s_char || s_tile || s_work || s_spr || s_pal
              || s_x21 || s_x31 || s_dsw1 || s_p12;
  wire s_wr_ok = s_ram || s_char || s_tile || s_work || s_spr || s_pal
              || s_flip || s_latch || s_x21 || s_x31 || s_vreg;

  // scroll register select by word offset (t16:385-390)
  logic [2:0] vsel;
  logic       vsel_ok;
  always_comb begin
    vsel_ok = 1'b1;
    case (m_ba[4:1])
      4'd0:    vsel = 3'd0;     // 0x160000 text x
      4'd3:    vsel = 3'd1;     // 0x160006 text y
      4'd6:    vsel = 3'd2;     // 0x16000c fg x
      4'd9:    vsel = 3'd3;     // 0x160012 fg y
      4'd12:   vsel = 3'd4;     // 0x160018 bg x
      4'd15:   vsel = 3'd5;     // 0x16001e bg y
      default: begin vsel = 3'd7; vsel_ok = 1'b0; end
    endcase
  end

  // ================================================================ bus
  // Writes: DTACK at once and the write performed when a data strobe
  // appears. Reads: one clock for the memory outputs; program ROM reads
  // assert DTACK at once and latch the ROM word when it arrives.
  typedef enum logic [1:0] {MB_IDLE, MB_RD, MB_ROM, MB_ACK} mbst_t;
  // fx68k's last read-data capture is at AS + 20 clocks (2.5 CPU clocks of
  // 8 at 96 MHz). prom_cnt counts from the first MB_ROM clock (AS + 1); data
  // that arrives with ok at count k is in the latch from AS + k + 2, so with
  // one clock kept spare for the exact capture edge k must be at most 17
  // (the same rule as the 1945k III core at 16 MHz, where it is 12).
  localparam int PROM_LIMIT = (CLK_HZ / F68) * 5 / 2 - 3;
  logic [7:0]  prom_cnt;
  logic        prom_got;
  mbst_t       mbst;
  logic        m_wdone;
  logic [15:0] m_rdata;
  wire         m_ds = !(m_udsn && m_ldsn);
  wire         m_wstb /* verilator public_flat_rd */ = (mbst == MB_ACK) && !m_rw && m_ds && !m_wdone;
  assign m_dtackn    = !(mbst == MB_ACK || mbst == MB_ROM);
  assign m_din       = m_rdata;
  assign o_prom_req  = (mbst == MB_ROM);
  assign o_prom_addr = m_a[18:1];
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      mbst    <= MB_IDLE;
      m_wdone <= 1'b0;
      o_dbg_prom_late <= '0;
      prom_cnt <= '0;
      prom_got <= 1'b0;
    end else begin
      case (mbst)
        MB_IDLE: if (!m_asn && !m_iack) begin
          if (!m_rw) begin
            m_wdone <= 1'b0;
            mbst <= MB_ACK;
          end else if (m_ds) begin
            mbst     <= s_rom ? MB_ROM : MB_RD;
            prom_cnt <= '0;
            prom_got <= 1'b0;
          end
        end
        MB_RD: mbst <= MB_ACK;
        MB_ROM: begin   // DTACK asserted; data latched when ok, cycle ends on AS
          if (prom_cnt != 8'hFF) prom_cnt <= prom_cnt + 8'd1;
          if (i_prom_ok) begin
            prom_got <= 1'b1;
            if (!prom_got && prom_cnt > 8'(PROM_LIMIT)) o_dbg_prom_late <= o_dbg_prom_late + 16'd1;
          end
          if (m_asn) begin
            mbst <= MB_IDLE;
            if (!prom_got && !i_prom_ok) o_dbg_prom_late <= o_dbg_prom_late + 16'd1;
          end
        end
        MB_ACK: begin
          if (m_wstb) m_wdone <= 1'b1;
          if (m_asn) mbst <= MB_IDLE;
        end
        default: mbst <= MB_IDLE;
      endcase
    end
  end

  // byte writes carry the byte on both lanes (68000 bus, and MAME's taps)
  wire [15:0] wdata = m_udsn ? {m_dout[7:0], m_dout[7:0]}
                    : (m_ldsn ? {m_dout[15:8], m_dout[15:8]} : m_dout);
  wire [1:0]  m_be  = {~m_udsn, ~m_ldsn};

  // ================================================================ IRQ5
  logic        vbl;
  logic [23:0] hold_cnt;
  logic        irq5 /* verilator public_flat_rd */;
  wire         irq_clr_w = m_wstb && s_x21;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      irq5     <= 1'b0;
      hold_cnt <= '0;
    end else begin
      if (hold_cnt != 24'd0) begin
        hold_cnt <= hold_cnt - 24'd1;
        if (hold_cnt == 24'd1) irq5 <= 1'b0;     // vblank end (t16:684)
      end
      if (vbl) begin
        irq5     <= 1'b1;
        hold_cnt <= 24'(IRQ_HOLD);
      end
      if (irq_clr_w) irq5 <= 1'b0;               // t16:354-360
    end
  end
  assign m_ipl  = irq5 ? 3'd5 : 3'd0;
  assign m_vpan = !m_iack;

  // ================================================================ memories
  logic [15:0] ram_q, work_q;
  t16_dpram #(.AW(13), .DW(16)) u_ram (
    .clk, .addr_a(m_a[13:1]), .d_a(wdata), .we_a(m_wstb && s_ram), .be_a(m_be),
    .q_a(ram_q), .addr_b(13'd0), .q_b());
  // work RAM: Final Star Force 0x122000-0x127fff (word index 0x1000-0x3fff of
  // the 0x120000 window), Riot/Ginkun 0x124000-0x124fff (index 0x2000-0x27ff)
  t16_dpram #(.AW(14), .DW(16)) u_work (
    .clk, .addr_a(m_a[14:1]), .d_a(wdata), .we_a(m_wstb && s_work), .be_a(m_be),
    .q_a(work_q), .addr_b(14'd0), .q_b());

  // ================================================================ latch, flip
  wire latch_we = m_wstb && s_latch && !m_ldsn;

  // ================================================================ video
  logic [15:0] pal_q, char_q, fgv_q, fgc_q, bgv_q, bgc_q, spr_q;
  wire  [11:0] vaddr = s_pal ? m_a[12:1] : (base && s_tile) ? {2'b00, m_a[10:1]} : {1'b0, m_a[11:1]};
  wire         flip_w = m_wstb && s_flip;
  t16_video #(.LATCH(LATCH), .V_TOTAL(V_TOTAL)) u_video (
    .clk, .rst_n, .ce_pix, .i_machine,
    .i_cpu_addr(vaddr), .i_cpu_din(wdata), .i_cpu_be(flip_w ? 2'b11 : m_be),
    .i_pal_we(m_wstb && s_pal), .i_char_we(m_wstb && s_char),
    .i_fgv_we(m_wstb && s_fgv), .i_fgc_we(m_wstb && s_fgc),
    .i_bgv_we(m_wstb && s_bgv), .i_bgc_we(m_wstb && s_bgc),
    .i_spr_we(m_wstb && s_spr),
    .o_pal_dout(pal_q), .o_char_dout(char_q), .o_fgv_dout(fgv_q), .o_fgc_dout(fgc_q),
    .o_bgv_dout(bgv_q), .o_bgc_dout(bgc_q), .o_spr_dout(spr_q),
    .i_reg_we(m_wstb && s_vreg && vsel_ok), .i_reg_sel(vsel),
    .i_flip_we(flip_w), .i_spr_snap(1'b0), .i_txy_unwrite(1'b0),
    .o_rom_req, .o_rom_addr, .i_rom_gnt, .i_rom_rv, .i_rom_data,
    .o_r, .o_g, .o_b, .o_de, .o_hblank, .o_vblank, .o_hs, .o_vs,
    .o_vbl(vbl), .o_busy(o_vid_busy), .o_hold(),
    .o_dbg_overruns, .o_dbg_maxcyc, .o_dbg_err(o_dbg_verr), .o_dbg_lay());
  assign o_vbl = vbl;

  // ================================================================ sound
  t16_snd #(.CLK_HZ(CLK_HZ)) u_snd (
    .clk, .rst_n, .i_pause,
    .i_dl_we(i_snd_dl_we), .i_dl_addr(i_snd_dl_addr), .i_dl_data(i_snd_dl_data),
    .i_latch_we(latch_we), .i_latch_d(m_dout[7:0]),
    .o_oki_addr, .i_oki_data, .i_oki_ok,
    .o_left, .o_right, .o_ym_l(), .o_ym_r(), .o_oki(), .o_ym_sample(),
    .o_dbg_rom_writes(), .o_dbg_unmapped(o_dbg_snd_unmapped), .o_dbg_nmis());

  // ================================================================ read mux
  always_ff @(posedge clk) begin
    if (mbst == MB_ROM && i_prom_ok && !prom_got) m_rdata <= i_prom_data;
    else if (mbst == MB_RD) begin
      if (s_ram)        m_rdata <= ram_q;
      else if (s_work)  m_rdata <= work_q;
      else if (s_char)  m_rdata <= char_q;
      else if (s_fgv)   m_rdata <= fgv_q;
      else if (s_fgc)   m_rdata <= fgc_q;
      else if (s_bgv)   m_rdata <= bgv_q;
      else if (s_bgc)   m_rdata <= bgc_q;
      else if (s_spr)   m_rdata <= spr_q;
      else if (s_pal)   m_rdata <= pal_q;
      else if (s_x21)   m_rdata <= i_extra;
      else if (s_x31)   m_rdata <= i_dsw2;
      else if (s_dsw1)  m_rdata <= i_dsw1;
      else if (s_p12)   m_rdata <= i_p1p2;
      else              m_rdata <= 16'h0000;      // write-only and unmapped
    end
  end

  // ================================================================ counters
  logic m_asn_q;
  always_ff @(posedge clk) begin
    m_asn_q <= m_asn;
    if (!rst_n) begin
      o_dbg_rom_writes <= '0;
      o_dbg_unmapped   <= '0;
      o_dbg_vreg_other <= '0;
      o_cpu_pc_dbg     <= '0;
    end else begin
      if (m_wstb && s_rom) o_dbg_rom_writes <= o_dbg_rom_writes + 16'd1;
      if (m_wstb && s_vreg && !vsel_ok) o_dbg_vreg_other <= o_dbg_vreg_other + 16'd1;
      if (m_asn_q && !m_asn && !m_iack) begin
        if (m_rw ? !s_rd_ok : !(s_wr_ok || s_rom)) o_dbg_unmapped <= o_dbg_unmapped + 16'd1;
        if (m_fc1 && !m_fc0 && m_rw) o_cpu_pc_dbg <= m_ba;   // program space read (opcode/ext)
      end
    end
  end


endmodule
