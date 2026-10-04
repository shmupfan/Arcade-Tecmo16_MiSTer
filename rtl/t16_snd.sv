// Tecmo 16 sound board (PLAN M2/M3; spec 2, 3): Z80 sound CPU, sound ROM
// (BRAM, loaded through the download port), RAM, the sound latch from the
// 68000, YM2151 (jt51) and M6295 (jt6295). Adapted from the Dooyong core's
// dy_snd.sv (YM2151 variant), which runs this chip set on hardware.
//
// Sound map (tecmo16.cpp:419-428, spec 3):
//   0x0000-0xEFFF  ROM (audiocpu region, 64 KB loaded; the top 4 KB unused)
//   0xF000-0xFBFF  RAM 3 KB
//   0xFC00         M6295 (read status / write command)
//   0xFC04-0xFC05  YM2151: write address (A0 = 0) / data (A0 = 1); reads
//                  return the status at 0xFC05 and 0xFF at 0xFC04, as MAME's
//                  ymfm ym2151::read (offset 0 is the "unused data port");
//                  the real chip's A0 = 0 read is not documented here
//                  (m2_findings 6)
//   0xFC08         sound latch (read; reading acknowledges it)
//   0xFC0C         no-op read and write
//   0xFFFE-0xFFFF  RAM 2 bytes
// Unmapped reads return 0 (MAME's unmap value) and are counted.
//
// Interrupts: NMI = latch pending (generic_latch_8 data_pending callback,
// tecmo16.cpp:703): a 68000 write to 0x150011 sets it, the Z80 read of
// 0xFC08 clears it; the Z80 takes the NMI on the falling edge of NMI_n, so a
// second write before the read raises no second NMI (as MAME's latch). INT =
// YM2151 IRQ (level, tecmo16.cpp:706); the acknowledge cycle reads 0xFF.
//
// Clock enables from the system clock (CLK_HZ, 96 MHz on hardware), all
// stopped by i_pause:
//   Z80    4 MHz  = 24 MHz / 6 (t16:670)
//   YM2151 4 MHz  = 24 MHz / 6 (t16:705); cen_p1 every other enable (jt51)
//   M6295  1 MHz  = 8 MHz / 8, pin 7 high (t16:710)
//
// Mix (M3 calibrates it against MAME's WAV): YM2151 left / right at 0.60 to
// their own side, M6295 at 0.40 to both (t16:707-712). jt51's xleft/xright
// are 16-bit full scale; jt6295's output is in 12-bit units that MAME
// converts at 1/2048 of full scale, so 0.40 = 6.4 in 16-bit units.

module t16_snd #(
    parameter int CLK_HZ   = 96000000,
    parameter int YM_GAIN  = 154,     // x/256: 0.60
    parameter int OKI_GAIN = 1638     // x/256: 6.4
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        i_pause,

    // sound ROM download (64 KB, audiocpu region)
    input  logic        i_dl_we,
    input  logic [15:0] i_dl_addr,
    input  logic [7:0]  i_dl_data,

    // sound latch from the 68000
    input  logic        i_latch_we,
    input  logic [7:0]  i_latch_d,

    // M6295 sample ROM (256 KB region); data valid when i_oki_ok
    output logic [17:0] o_oki_addr,
    input  logic [7:0]  i_oki_data,
    input  logic        i_oki_ok,

    output logic signed [15:0] o_left,
    output logic signed [15:0] o_right,
    output logic signed [15:0] o_ym_l,
    output logic signed [15:0] o_ym_r,
    output logic signed [13:0] o_oki,
    output logic        o_ym_sample,

    // debug
    output logic [15:0] o_dbg_rom_writes,
    output logic [15:0] o_dbg_unmapped,
    output logic [15:0] o_dbg_nmis
);

  // ================================================================ enables
  localparam int FCPU = 4000000, FYM = 4000000, FOKI = 1000000;
  logic [27:0] c_acc, y_acc, o_acc;
  logic        ce_cpu, ym_cen, ym_ph, oki_cen;
  always_ff @(posedge clk) begin
    ce_cpu  <= 1'b0;
    ym_cen  <= 1'b0;
    oki_cen <= 1'b0;
    if (!rst_n) begin
      c_acc <= '0;
      y_acc <= '0;
      o_acc <= '0;
      ym_ph <= 1'b0;
    end else if (!i_pause) begin
      if (c_acc + 28'(FCPU) >= 28'(CLK_HZ)) begin
        c_acc <= c_acc + 28'(FCPU) - 28'(CLK_HZ);
        ce_cpu <= 1'b1;
      end else c_acc <= c_acc + 28'(FCPU);
      if (y_acc + 28'(FYM) >= 28'(CLK_HZ)) begin
        y_acc <= y_acc + 28'(FYM) - 28'(CLK_HZ);
        ym_cen <= 1'b1;
        ym_ph  <= !ym_ph;
      end else y_acc <= y_acc + 28'(FYM);
      if (o_acc + 28'(FOKI) >= 28'(CLK_HZ)) begin
        o_acc <= o_acc + 28'(FOKI) - 28'(CLK_HZ);
        oki_cen <= 1'b1;
      end else o_acc <= o_acc + 28'(FOKI);
    end
  end
  wire ym_cen_p1 = ym_cen && ym_ph;

  // Reset-time enable for jt51. jt51 loads its reset values only by shifting
  // with cen while rst is high (jt51_sh); with the enable held at 0 in reset
  // it never reset at all: from power-on its state was all zeros, and after
  // a warm reset it kept the previous game's operator state
  // (m3_findings 12). This enable runs only while rst_n is low, one pulse
  // every 8 clocks for RST_CEN pulses; the normal enables above still
  // restart from 0 at the release, so every enable after reset is unchanged.
  localparam logic [12:0] RST_CEN = 13'd4608;   // 72 x 64: whole jt51 slot cycles (as in the Dooyong core)
  logic [2:0]  rst_div;
  logic [12:0] rst_cnt;
  logic        rst_cen, rst_ph;
  always_ff @(posedge clk) begin
    rst_cen <= 1'b0;
    if (rst_n) begin
      rst_div <= '0;
      rst_cnt <= '0;
      rst_ph  <= 1'b0;
    end else if (rst_cnt != RST_CEN) begin
      rst_div <= rst_div + 3'd1;
      if (rst_div == 3'd0) begin
        rst_cen <= 1'b1;
        rst_ph  <= !rst_ph;
        rst_cnt <= rst_cnt + 13'd1;
      end
    end
  end
  wire fm_cen    = rst_n ? ym_cen    : rst_cen;
  wire fm_cen_p1 = rst_n ? ym_cen_p1 : (rst_cen && rst_ph);

  // ================================================================ CPU
  logic [15:0] A /* verilator public_flat_rd */;
  logic [7:0]  dout /* verilator public_flat_rd */;
  logic [7:0]  din /* verilator public_flat_rd */;
  logic        m1_n /* verilator public_flat_rd */;
  logic        rd_n /* verilator public_flat_rd */;
  logic        mreq_n /* verilator public_flat_rd */;
  logic        iorq_n, wr_n, rfsh_n, halt_n, busak_n;
  logic        ym_irq_n /* verilator public_flat_rd */;
  logic        pending /* verilator public_flat_rd */;
  logic [7:0]  latch /* verilator public_flat_rd */;

  T80s u_cpu (
    .RESET_n(rst_n), .CLK(clk), .CEN(ce_cpu),
    .WAIT_n(1'b1), .INT_n(ym_irq_n), .NMI_n(!pending), .BUSRQ_n(1'b1), .OUT0(1'b0),
    .DI(din),
    .M1_n(m1_n), .MREQ_n(mreq_n), .IORQ_n(iorq_n), .RD_n(rd_n), .WR_n(wr_n),
    .RFSH_n(rfsh_n), .HALT_n(halt_n), .BUSAK_n(busak_n),
    .A(A), .DOUT(dout));

  wire mem     = !mreq_n && rfsh_n;
  wire int_ack = !m1_n && !iorq_n;
  logic wr_q, rd_q;
  always_ff @(posedge clk) begin
    wr_q <= mem && !wr_n;
    rd_q <= mem && !rd_n;
  end
  wire wr /* verilator public_flat_rd */ = mem && !wr_n && !wr_q;
  wire rd_start = mem && !rd_n && !rd_q;

  wire s_rom  = A < 16'hF000;
  wire s_ram  = A >= 16'hF000 && A < 16'hFC00;
  wire s_oki  = A == 16'hFC00;
  wire s_ym   = A[15:1] == 15'h7E02;          // FC04-FC05
  wire s_lat  = A == 16'hFC08;
  wire s_nop  = A == 16'hFC0C;
  wire s_hi   = A[15:1] == 15'h7FFF;          // FFFE-FFFF
  wire s_any  = s_rom || s_ram || s_oki || s_ym || s_lat || s_nop || s_hi;

  // ================================================================ memories
  logic [7:0] rom_q, ram_q;
  logic [7:0] hi_ram [0:1] /* verilator public_flat_rd */;
  t16_dpram #(.AW(16), .DW(8)) u_rom (
    .clk(clk),
    .addr_a(i_dl_addr), .d_a(i_dl_data), .we_a(i_dl_we), .be_a(1'b1), .q_a(),
    .addr_b(A), .q_b(rom_q));
  t16_dpram #(.AW(12), .DW(8)) u_ram (
    .clk(clk),
    .addr_a(A[11:0]), .d_a(dout), .we_a(wr && s_ram), .be_a(1'b1), .q_a(ram_q),
    .addr_b(12'd0), .q_b());
  always_ff @(posedge clk) if (wr && s_hi) hi_ram[A[0]] <= dout;

  // ================================================================ latch
  // The 68000 write wins over a Z80 read in the same clock (the read then
  // returns the new value and the flag stays set for it).
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pending <= 1'b0;
      latch   <= 8'h00;
      o_dbg_nmis <= '0;
    end else begin
      if (rd_start && s_lat) pending <= 1'b0;
      if (i_latch_we) begin
        latch   <= i_latch_d;
        pending <= 1'b1;
        if (!pending) o_dbg_nmis <= o_dbg_nmis + 16'd1;
      end
    end
  end

  // ================================================================ chips
  logic [7:0] ym_dout, oki_dout;
  logic signed [15:0] ym_xl /* verilator public_flat_rd */;
  logic signed [15:0] ym_xr /* verilator public_flat_rd */;
  logic       ym_smp;
  // A Z80 write reaches jt51 on the next cen_p1 clock. jt51 takes register
  // writes on any clock but sets its busy flag only for a write that
  // coincides with cen_p1 (jt51_mmr: busy updates under cen); a one-clock
  // strobe at 96 MHz hit cen_p1 about once in 48 writes, so the status
  // read after a data write showed "not busy" where the chip (and MAME's
  // ymfm, 32 x prescale 2 = 64 master clocks) shows busy for 16 us, and
  // the sound driver's busy-wait loops ran short (m3_findings 3). Holding
  // the write until cen_p1 moves the register update by at most one P1
  // period (0.5 us), below the chip's own internal sampling.
  logic       ym_wpend;
  logic       ym_wa0;
  logic [7:0] ym_wd;
  always_ff @(posedge clk) begin
    if (!rst_n) ym_wpend <= 1'b0;
    else if (wr && s_ym) begin
      ym_wpend <= 1'b1;
      ym_wa0   <= A[0];
      ym_wd    <= dout;
    end else if (ym_cen_p1) ym_wpend <= 1'b0;
  end
  jt51 u_ym (
    .rst(!rst_n), .clk(clk), .cen(fm_cen), .cen_p1(fm_cen_p1),
    .cs_n(!(ym_wpend && ym_cen_p1)), .wr_n(1'b0), .a0(ym_wa0), .din(ym_wd),
    .dout(ym_dout),
    .ct1(), .ct2(), .irq_n(ym_irq_n),
    .sample(ym_smp), .left(), .right(), .xleft(ym_xl), .xright(ym_xr));

  logic signed [13:0] oki_snd /* verilator public_flat_rd */;
  jt6295 #(.INTERPOL(0)) u_oki (
    .rst(!rst_n), .clk(clk), .cen(oki_cen), .ss(1'b1),
    .wrn(!(wr && s_oki)), .din(dout), .dout(oki_dout),
    .rom_addr(o_oki_addr), .rom_data(i_oki_data), .rom_ok(i_oki_ok),
    .sound(oki_snd), .sample());

  always_ff @(posedge clk) begin
    if (int_ack)    din <= 8'hFF;
    else if (s_rom) din <= rom_q;
    else if (s_ram) din <= ram_q;
    else if (s_hi)  din <= hi_ram[A[0]];
    else if (s_lat) din <= latch;
    else if (s_ym)  din <= A[0] ? ym_dout : 8'hFF;
    else if (s_oki) din <= oki_dout;
    else            din <= 8'h00;           // 0xFC0C and unmapped
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      o_dbg_rom_writes <= '0;
      o_dbg_unmapped   <= '0;
    end else begin
      if (wr && s_rom) o_dbg_rom_writes <= o_dbg_rom_writes + 16'd1;
      if ((wr || rd_start) && !s_any) o_dbg_unmapped <= o_dbg_unmapped + 16'd1;
    end
  end

  // ================================================================ mix
  assign o_ym_l = ym_xl;
  assign o_ym_r = ym_xr;
  assign o_oki  = oki_snd;
  assign o_ym_sample = ym_smp;
  function automatic logic signed [15:0] sat(input logic signed [27:0] m);
    if (m > 28'sd32767)       sat = 16'sd32767;
    else if (m < -28'sd32768) sat = -16'sd32768;
    else                      sat = m[15:0];
  endfunction
  // every term signed (an unsigned operand would make >>> logical, the
  // Dooyong mix bug, m3/ym2203 findings)
  wire signed [27:0] oki_t = 28'(oki_snd) * $signed(28'(OKI_GAIN));
  assign o_left  = sat((28'(ym_xl) * $signed(28'(YM_GAIN)) + oki_t) >>> 8);
  assign o_right = sat((28'(ym_xr) * $signed(28'(YM_GAIN)) + oki_t) >>> 8);

  wire unused = &{1'b0, halt_n, busak_n, iorq_n};

endmodule
