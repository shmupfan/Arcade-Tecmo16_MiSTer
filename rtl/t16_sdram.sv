// SDRAM controller for the Tecmo 16 core (PLAN M4).
//
// One 16-bit SDRAM (MiSTer module: 4 banks x 8192 rows x 512 columns,
// AS4C32M16SB-7). The logical byte layout is PLAN 4.3 /
// tools/build_regions.py SDRAM_SLOTS (the MRA streams exactly that image
// from byte 0); this controller places the regions in banks so the 68000
// never shares a bank:
//   bank 0  maincpu   0x000000-0x07FFFF  (68000 program, latency critical)
//   bank 1  bgtiles   0x080000-0x17FFFF  (bank offset 0x000000)
//           fgtiles   0x280000-0x29FFFF  (bank offset 0x100000)
//   bank 2  sprites   0x180000-0x27FFFF
//   bank 3  audiocpu  0x2A0000-0x2AFFFF  (also loaded into block RAM by the
//                                         board; kept here so the image is
//                                         whole)
//           oki       0x2B0000-0x2EFFFF
// Every region boundary is a multiple of 64 KB, so the mapping only rebases
// the 6-bit 64 KB segment number (map_word below).
//
// Why banks: the program ROM is 512 KB, too large for block RAM beside the
// video, and the 68000 runs without wait states on the real board (MAME's
// memory model, m2_findings 3). A program fetch must finish inside one bus
// cycle whatever the video is doing: t16_sys keeps loading the word until
// ok and fx68k's last capture is 20 clocks after AS at 12 MHz, so ok must
// come within 17 clocks of the request (PROM_LIMIT). With the program alone
// in bank 0, a fetch never waits for another client's row: the two engines
// share only the command bus (one command per clock, the CPU first) and the
// data bus (BL1 reads at distinct command clocks return at distinct clocks).
//
// Timing (lesson of the 1945k III compile 1, which failed 96 MHz by about
// 1 ns with arbitration and the SDRAM_A mux fed straight from the 68000
// address bus, the OKI address and a FIFO RAM output): every client's
// request and address are registered before anything that reaches the
// command decode, and the next job is chosen one clock ahead into a pending
// slot, so the ACT/READ/WRITE that drives SDRAM_A/BA/cmd is decoded from
// registers only.
//
// Engines:
//   CPU     program ROM word reads, bank 0. Request and address registered at
//           edge e, ACT at e + 1, READ with auto precharge T_RCD later, data
//           P_RET after that, passed straight through to the CPU (o_cpu_ok and
//           o_cpu_data are combinational on the landing clock). Request seen
//           at edge e -> data at e + 1 + T_RCD + P_RET: 10 clocks worst case
//           including the request edge at the defaults, inside t16_sys's 17.
//   other   one job at a time, highest priority first, chosen one clock ahead
//           into the pending slot (pend_*):
//             download  ioctl bytes paired into words (core in reset)
//             OKI       jt6295 byte reads (address held until ok), bank 3
//             graphics  t16_video's pipelined 32-bit port (two words of one
//                       row: ACT, READ, READ with auto precharge), banks 1/2
//             refresh   while the CPU is held in reset, any time; while it
//                       runs, only in the window right after a CPU word lands
//                       (at 12 MHz the next 68000 bus cycle is at least 32
//                       clocks after this one's AS), or forced when the debt
//                       reaches REF_FORCE (counted in o_dbg_ref_forced: a
//                       forced refresh can delay a fetch)
//
// Protocol and constants from the Hyper Duel / Dooyong / 1945k III
// controllers (proven on the MiSTer SDRAM board): close page, CL2, capture
// P_RET clocks after the CAS command, full-word writes only (DQML/DQMH low),
// tRCD/tRP 3 clocks at 96 MHz (the -7 part needs 21 ns), init = wait, PALL,
// 2x REF, MODE. SDRAM_CLK is the PLL's phase-shifted copy of clk.
//
// Byte lanes: even byte address = word[15:8] (the big-endian region view
// used everywhere in this project).

module t16_sdram #(
    parameter bit P_SHORT_INIT   = 1'b0,  // sim: skip the 100 us power-up wait
    parameter int P_RET          = 3,     // CAS command -> captured data, clocks
    parameter int REFRESH_PERIOD = 750,   // 7.8125 us at 96 MHz
    parameter int REF_FORCE      = 6,     // refresh debt that forces a refresh
    // clocks after a CPU landing in which a refresh may start: bank 0 is idle
    // T_RP + 2 - P_RET clocks after the landing, and the 68000's next fetch
    // cannot be requested before about 24 clocks after it at 12 MHz (next AS
    // >= 32 clocks after this one, data lands about 8 clocks after AS); a
    // refresh started inside the window ends (T_RFC) well before then
    parameter int REF_WIN        = 6,
    parameter int INIT_CYCLES    = 9600,  // 100 us at 96 MHz
    parameter int T_RCD          = 3,
    parameter int T_RP           = 3,
    parameter int T_RRD          = 2,     // 14 ns
    parameter int T_WR           = 2,     // 14 ns
    parameter int T_RFC          = 8      // 63 ns tRC, rounded up as Dooyong
) (
    input  logic        clk,
    input  logic        rst_n,
    output logic        o_ready,

    // download (byte writes, logical layout, PLAN 4.3)
    input  logic        i_dl_wr,
    input  logic [21:0] i_dl_addr,
    input  logic [7:0]  i_dl_data,
    output logic        o_dl_busy,

    // 68000 program ROM (word address within 0x000000-0x07FFFF)
    input  logic        i_cpu_run,      // 0: CPU held in reset (refresh any time)
    input  logic        i_cpu_req,
    input  logic [18:1] i_cpu_addr,
    output logic [15:0] o_cpu_data,
    output logic        o_cpu_ok,

    // graphics (t16_video ROM port, logical byte address, 4-byte aligned)
    input  logic        i_gfx_req,
    input  logic [21:0] i_gfx_addr,
    output logic        o_gfx_gnt,
    output logic        o_gfx_rv,
    output logic [31:0] o_gfx_data,     // [31:24] = byte at the address

    // M6295 samples: byte address within the oki region (0x2B0000, 256 KB)
    input  logic [17:0] i_oki_addr,
    output logic [7:0]  o_oki_data,
    output logic        o_oki_ok,

    // debug / gate counters
    output logic [15:0] o_dbg_refreshes,
    output logic [15:0] o_dbg_ref_forced,
    output logic [7:0]  o_dbg_cpu_maxlat,   // worst request -> ok, clocks
    output logic [15:0] o_dbg_dl_words,

    // SDRAM pins
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

  localparam logic [3:0] CMD_NOP  = 4'b0111;
  localparam logic [3:0] CMD_ACT  = 4'b0011;
  localparam logic [3:0] CMD_READ = 4'b0101;
  localparam logic [3:0] CMD_WRIT = 4'b0100;
  localparam logic [3:0] CMD_PALL = 4'b0010;
  localparam logic [3:0] CMD_REF  = 4'b0001;
  localparam logic [3:0] CMD_MODE = 4'b0000;
  localparam logic [12:0] MODE_REG = 13'h020;       // BL1, sequential, CL2
  localparam int INIT_WAIT = P_SHORT_INIT ? 32 : INIT_CYCLES;

  // return tags
  localparam logic [2:0] T_NONE = 3'd0, T_CPU = 3'd1, T_G0 = 3'd2, T_G1 = 3'd3,
                         T_OKI = 3'd4;

  // ------------------------------------------------------------------
  // logical byte address -> {bank, 22-bit word in the bank}
  // ------------------------------------------------------------------
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [23:0] map_word(input logic [21:0] a);
    logic [5:0] s, rs;
    logic [1:0] b;
    s = a[21:16];                                   // 64 KB segment
    if      (s < 6'h08) begin b = 2'd0; rs = s;                 end   // maincpu
    else if (s < 6'h18) begin b = 2'd1; rs = s - 6'h08;         end   // bgtiles
    else if (s < 6'h28) begin b = 2'd2; rs = s - 6'h18;         end   // sprites
    else if (s < 6'h2A) begin b = 2'd1; rs = s - 6'h28 + 6'h10; end   // fgtiles
    else                begin b = 2'd3; rs = s - 6'h2A;         end   // audiocpu, oki
    return {b, 1'b0, rs, a[15:1]};
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  /* verilator lint_off PROCASSINIT */
  logic [3:0] cmd = CMD_NOP;
  /* verilator lint_on PROCASSINIT */
  assign {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd;
  assign SDRAM_CKE = 1'b1;

  logic [15:0] dq_out;
  logic        dq_oe;
  assign SDRAM_DQ = dq_oe ? dq_out : 16'hzzzz;
  logic [15:0] dq_in;
  always_ff @(posedge clk) dq_in <= SDRAM_DQ;

  logic [2:0] ret_tag [P_RET+1];
  always_ff @(posedge clk)
    for (int i = P_RET; i > 0; i--) ret_tag[i] <= ret_tag[i-1];
  wire [2:0] land = ret_tag[P_RET];

  // ------------------------------------------------------------------
  // download: pair bytes into words, small FIFO of mapped words
  // ------------------------------------------------------------------
  // The FIFO holds the already mapped {bank, word} (mapped from the
  // registered ioctl address), so its read side feeds the pending slot
  // without any arithmetic.
  (* ramstyle = "logic" *) logic [39:0] dlf [4];   // {mapped word (24), data (16)}
  logic [1:0]  dlf_wp, dlf_rp;
  logic [2:0]  dlf_cnt;
  logic        dlf_pop;
  logic [7:0]  dl_even;
  logic        dl_push_q;
  logic [21:0] dl_addr_q;
  logic [7:0]  dl_data_q;
  wire         dlf_empty = (dlf_cnt == 3'd0);
  assign o_dl_busy = (dlf_cnt >= 3'd2);

  always_ff @(posedge clk) begin
    dl_push_q <= rst_n && i_dl_wr && i_dl_addr[0];
    dl_addr_q <= i_dl_addr;
    dl_data_q <= i_dl_data;
    if (i_dl_wr && !i_dl_addr[0]) dl_even <= i_dl_data;
    if (!rst_n) begin
      dlf_wp  <= '0;
      dlf_rp  <= '0;
      dlf_cnt <= '0;
    end else begin
      if (dl_push_q) begin
        dlf[dlf_wp] <= {map_word(dl_addr_q), dl_even, dl_data_q};
        dlf_wp <= dlf_wp + 2'd1;
      end
      if (dlf_pop) dlf_rp <= dlf_rp + 2'd1;
      dlf_cnt <= dlf_cnt + 3'(dl_push_q) - 3'(dlf_pop);
    end
  end

  // ------------------------------------------------------------------
  // shared state
  // ------------------------------------------------------------------
  logic        init_done;
  logic [3:0]  bank_t [4];              // clocks until the bank may be activated
  logic [3:0]  rrd_t;                   // clocks until another ACT is allowed
  logic [3:0]  rfc_t;                   // refresh in progress
  logic [9:0]  ref_cnt;
  logic [3:0]  ref_debt;
  logic [3:0]  ref_win;                 // refresh window after a CPU landing

  wire banks_idle = (bank_t[0] == 0) && (bank_t[1] == 0) && (bank_t[2] == 0) && (bank_t[3] == 0);

  // ------------------------------------------------------------------
  // CPU engine (bank 0)
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {C_IDLE, C_RCD, C_RD, C_LAND} cst_e;
  cst_e        cst;
  logic [2:0]  c_cnt;
  logic [18:1] c_addr, c_served;
  logic        c_have;
  logic [15:0] c_data;
  logic [7:0]  c_lat;

  wire c_hit     = c_have && (i_cpu_addr == c_served);   // live: o_cpu_ok only
  // Registered request (one clock): c_hit_q is the hit test against the
  // served word as it stands after the edge (a landing on this clock makes
  // c_addr the served word), so a request for the word just landed is never
  // fetched twice.
  logic        c_req_q, c_hit_q, cpu_run_q;
  logic [18:1] c_addr_q;
  wire         c_landing  = (land == T_CPU);
  wire         c_land_now = (cst == C_LAND) && c_landing;
  wire [18:1]  served_nx  = c_land_now ? c_addr : c_served;
  wire         have_nx    = c_have || c_land_now;
  always_ff @(posedge clk) begin
    c_req_q   <= rst_n && i_cpu_req;
    c_addr_q  <= i_cpu_addr;
    c_hit_q   <= rst_n && have_nx && (i_cpu_addr == served_nx);
    cpu_run_q <= i_cpu_run;
  end
  wire c_need    = init_done && c_req_q && !c_hit_q && (cst == C_IDLE);
  wire c_act     = c_need && (bank_t[0] == 0) && (rrd_t == 0) && (rfc_t == 0);
  wire c_rd      = (cst == C_RD);
  wire c_slot    = c_act || c_rd;                     // the CPU uses the command bus

  assign o_cpu_ok   = c_landing ? (i_cpu_addr == c_addr) : c_hit;
  assign o_cpu_data = c_landing ? dq_in : c_data;

  // ------------------------------------------------------------------
  // other engine
  // ------------------------------------------------------------------
  typedef enum logic [2:0] {O_IDLE, O_RCD, O_RD0, O_RD1, O_WR, O_REF} ost_e;
  typedef enum logic [1:0] {OW_GFX, OW_OKI, OW_DL} own_e;
  ost_e        ost;
  own_e        owner;
  logic [2:0]  o_cnt;
  logic [23:0] o_word;                  // {bank, word}
  logic [15:0] o_wdata;

  // OKI: the held address is registered (k_addr_q, and its mapped word),
  // and served whenever it differs from the one served. o_oki_ok compares
  // the live address so a changed address is never answered with old data.
  logic        k_have, k_busy;
  logic [17:0] k_served, k_q, k_addr_q;
  logic [23:0] k_word_q;
  always_ff @(posedge clk) begin
    k_addr_q <= i_oki_addr;
    k_word_q <= map_word(22'h2B0000 + 22'(i_oki_addr));
  end
  wire k_want = !k_busy && (!k_have || (k_addr_q != k_served)) && (k_addr_q == i_oki_addr);
  assign o_oki_ok = k_have && (i_oki_addr == k_served);

  // graphics: the address is mapped as it enters the pending slot (a 6-bit
  // segment compare and subtract feeding a register)
  wire [23:0] gfx_word = map_word(i_gfx_addr);

  wire o_free    = init_done && (ost == O_IDLE) && !c_slot && (rrd_t == 0) && (rfc_t == 0);
  wire ref_force = (ref_debt >= 4'(REF_FORCE));
  // a refresh is owed and a CPU fetch is in flight (its window opens at the
  // landing): start no new job, so every bank is idle when it opens
  wire ref_hold  = (ref_debt != 0) && cpu_run_q && (cst != C_IDLE || ref_win != 0);
  // refresh: no bank open, the CPU engine idle with nothing to fetch, and no
  // CPU request rising on this clock (the registered request sees it one
  // clock later; o_prom_req is a t16_sys state register, so this is short)
  wire c_rise    = i_cpu_req && !c_req_q;
  wire ref_ok    = (ref_debt != 0) && banks_idle && (cst == C_IDLE) && !c_need && !c_rise
                   && (ref_win != 0 || ref_force || !cpu_run_q);

  // Pending slot: the next job, chosen one clock before it can start
  // (download, OKI, graphics). A graphics request is granted when it enters
  // the slot; the grant depends on registers only.
  logic        pend_v;
  own_e        pend_own;
  logic [23:0] pend_word;
  logic [15:0] pend_wdata;
  wire sel_free  = init_done && !pend_v;
  wire sel_dl    = sel_free && !dlf_empty;
  wire sel_k     = sel_free && dlf_empty && k_want;
  wire gfx_ok    = sel_free && dlf_empty && !k_want;
  assign o_gfx_gnt = gfx_ok;
  wire sel_gfx   = gfx_ok && i_gfx_req;
  // start the pending job: the command bus and its bank free, no refresh due.
  // Refresh goes before a download write (the download is throttled by
  // ioctl_wait anyway; at full rate it would starve refresh).
  wire pend_bank_ok = (bank_t[pend_word[23:22]] == 0);
  wire pend_dl   = (pend_own == OW_DL);
  wire ref_go    = o_free && ref_ok;
  wire job_go    = o_free && pend_v && pend_bank_ok && !ref_ok && (pend_dl || !ref_hold);

  // ------------------------------------------------------------------
  // command issue, timers
  // ------------------------------------------------------------------
  typedef enum logic [2:0] {I_WAIT, I_PALL, I_REF1, I_REF2, I_MODE, I_DONE} ist_e;
  ist_e        ist;
  logic [13:0] init_cnt;
  logic [3:0]  i_cnt;

  always_ff @(posedge clk) begin
    cmd        <= CMD_NOP;
    SDRAM_A    <= '0;
    dq_oe      <= 1'b0;
    ret_tag[0] <= T_NONE;
    dlf_pop    <= 1'b0;

    for (int b = 0; b < 4; b++) if (bank_t[b] != 0) bank_t[b] <= bank_t[b] - 4'd1;
    if (rrd_t != 0) rrd_t <= rrd_t - 4'd1;
    if (rfc_t != 0) rfc_t <= rfc_t - 4'd1;
    if (ref_win != 0) ref_win <= ref_win - 4'd1;

    if (!rst_n) begin
      ist        <= I_WAIT;
      init_done  <= 1'b0;
      o_ready    <= 1'b0;
      init_cnt   <= '0;
      i_cnt      <= '0;
      cst        <= C_IDLE;
      ost        <= O_IDLE;
      pend_v     <= 1'b0;
      c_have     <= 1'b0;
      c_lat      <= '0;
      k_have     <= 1'b0;
      k_busy     <= 1'b0;
      for (int b = 0; b < 4; b++) bank_t[b] <= '0;
      rrd_t      <= '0;
      rfc_t      <= '0;
      ref_cnt    <= '0;
      ref_debt   <= '0;
      ref_win    <= '0;
      SDRAM_DQML <= 1'b1;
      SDRAM_DQMH <= 1'b1;
      o_dbg_refreshes  <= '0;
      o_dbg_ref_forced <= '0;
      o_dbg_cpu_maxlat <= '0;
      o_dbg_dl_words   <= '0;
    end else if (!init_done) begin
      case (ist)
        I_WAIT: begin
          init_cnt <= init_cnt + 14'd1;
          if (32'(init_cnt) == INIT_WAIT) ist <= I_PALL;
        end
        I_PALL: begin cmd <= CMD_PALL; SDRAM_A <= 13'h400; i_cnt <= 4'd2; ist <= I_REF1; end
        I_REF1: if (i_cnt != 0) i_cnt <= i_cnt - 4'd1;
                else begin cmd <= CMD_REF; i_cnt <= 4'd8; ist <= I_REF2; end
        I_REF2: if (i_cnt != 0) i_cnt <= i_cnt - 4'd1;
                else begin cmd <= CMD_REF; i_cnt <= 4'd8; ist <= I_MODE; end
        I_MODE: if (i_cnt != 0) i_cnt <= i_cnt - 4'd1;
                else begin
                  cmd <= CMD_MODE; SDRAM_A <= MODE_REG; SDRAM_BA <= 2'b00;
                  i_cnt <= 4'd2; ist <= I_DONE;
                end
        I_DONE: if (i_cnt != 0) i_cnt <= i_cnt - 4'd1;
                else begin
                  init_done <= 1'b1; o_ready <= 1'b1;
                  SDRAM_DQML <= 1'b0; SDRAM_DQMH <= 1'b0;
                end
        default: ist <= I_WAIT;
      endcase
    end else begin
      // ---------------- refresh debt
      if (32'(ref_cnt) == REFRESH_PERIOD - 1) begin
        ref_cnt <= '0;
        if (ref_debt != 4'd15) ref_debt <= ref_debt + 4'd1;
      end else ref_cnt <= ref_cnt + 10'd1;

      // ---------------- CPU latency monitor
      if (i_cpu_req && !o_cpu_ok) begin
        if (c_lat != 8'hFF) c_lat <= c_lat + 8'd1;
      end else c_lat <= '0;
      if (i_cpu_req && o_cpu_ok && (c_lat + 8'd1) > o_dbg_cpu_maxlat && !c_hit)
        o_dbg_cpu_maxlat <= c_lat + 8'd1;

      // ---------------- CPU engine (has the command bus first)
      case (cst)
        C_IDLE: if (c_act) begin
          cmd      <= CMD_ACT;
          SDRAM_BA <= 2'd0;
          SDRAM_A  <= 13'(c_addr_q[18:10]);            // word[21:9] of bank 0
          c_addr   <= c_addr_q;
          rrd_t    <= 4'(T_RRD - 1);
          c_cnt    <= 3'(T_RCD - 1);
          cst      <= C_RCD;
        end
        C_RCD: if (c_cnt > 3'd1) c_cnt <= c_cnt - 3'd1;
               else cst <= C_RD;
        C_RD: begin
          cmd        <= CMD_READ;
          SDRAM_BA   <= 2'd0;
          SDRAM_A    <= {4'b0010, c_addr[9:1]};         // auto precharge
          ret_tag[0] <= T_CPU;
          bank_t[0]  <= 4'(T_RP + 2);
          cst        <= C_LAND;
        end
        C_LAND: if (c_landing) begin
          c_data   <= dq_in;
          c_served <= c_addr;
          c_have   <= 1'b1;
          ref_win  <= 4'(REF_WIN);
          cst      <= C_IDLE;
        end
        default: cst <= C_IDLE;
      endcase

      // ---------------- other engine
      case (ost)
        O_IDLE: begin
          // Address and bank of the pending job's ACT are driven whenever the
          // CPU engine leaves the command bus free: with a NOP or REF command
          // the SDRAM ignores them, so only cmd waits for the full start
          // decision (job_go), which keeps it off the address path.
          if (!c_slot) begin
            SDRAM_BA <= pend_word[23:22];
            SDRAM_A  <= pend_word[21:9];
          end
          if (ref_go) begin
            cmd      <= CMD_REF;
            rfc_t    <= 4'(T_RFC);
            ref_debt <= ref_debt - 4'd1;
            o_dbg_refreshes <= o_dbg_refreshes + 16'd1;
            if (ref_win == 0 && cpu_run_q) o_dbg_ref_forced <= o_dbg_ref_forced + 16'd1;
          end else if (job_go) begin
            owner    <= pend_own;
            o_word   <= pend_word;
            o_wdata  <= pend_wdata;
            pend_v   <= 1'b0;
            cmd      <= CMD_ACT;
            rrd_t    <= 4'(T_RRD - 1);
            o_cnt    <= 3'(T_RCD - 1);
            ost      <= O_RCD;
          end
        end
        O_RCD: if (o_cnt > 3'd1) o_cnt <= o_cnt - 3'd1;
               else ost <= (owner == OW_DL) ? O_WR : O_RD0;
        O_RD0: if (!c_slot) begin                       // the CPU has the bus first
          cmd      <= CMD_READ;
          SDRAM_BA <= o_word[23:22];
          if (owner == OW_GFX) begin
            SDRAM_A    <= {4'b0000, o_word[8:0]};
            ret_tag[0] <= T_G0;
            o_word     <= o_word + 24'd1;
            ost        <= O_RD1;
          end else begin
            SDRAM_A    <= {4'b0010, o_word[8:0]};
            ret_tag[0] <= T_OKI;
            bank_t[o_word[23:22]] <= 4'(T_RP + 2);
            ost        <= O_IDLE;
          end
        end
        O_RD1: if (!c_slot) begin
          cmd        <= CMD_READ;
          SDRAM_BA   <= o_word[23:22];
          SDRAM_A    <= {4'b0010, o_word[8:0]};
          ret_tag[0] <= T_G1;
          bank_t[o_word[23:22]] <= 4'(T_RP + 2);
          ost        <= O_IDLE;
        end
        O_WR: if (!c_slot) begin
          cmd      <= CMD_WRIT;
          SDRAM_BA <= o_word[23:22];
          SDRAM_A  <= {4'b0010, o_word[8:0]};
          dq_oe    <= 1'b1;
          dq_out   <= o_wdata;
          bank_t[o_word[23:22]] <= 4'(T_WR + T_RP + 1);
          o_dbg_dl_words <= o_dbg_dl_words + 16'd1;
          ost      <= O_IDLE;
        end
        default: ost <= O_IDLE;
      endcase

      // ---------------- pending slot fill (the slot is empty this clock)
      if (sel_dl) begin
        pend_v <= 1'b1; pend_own <= OW_DL; pend_word <= dlf[dlf_rp][39:16];
        pend_wdata <= dlf[dlf_rp][15:0];
        dlf_pop <= 1'b1;
      end else if (sel_k) begin
        pend_v <= 1'b1; pend_own <= OW_OKI; pend_word <= k_word_q;
        k_q <= k_addr_q; k_busy <= 1'b1;
      end else if (sel_gfx) begin
        pend_v <= 1'b1; pend_own <= OW_GFX; pend_word <= gfx_word;
      end

      // OKI landing
      if (land == T_OKI) begin
        o_oki_data <= k_q[0] ? dq_in[7:0] : dq_in[15:8];
        k_served   <= k_q;
        k_have     <= 1'b1;
        k_busy     <= 1'b0;
      end
    end
  end

  // ------------------------------------------------------------------
  // graphics landing
  // ------------------------------------------------------------------
  logic [15:0] g_w0;
  always_ff @(posedge clk) begin
    o_gfx_rv <= 1'b0;
    if (land == T_G0) g_w0 <= dq_in;
    if (land == T_G1) begin
      o_gfx_data <= {g_w0, dq_in};
      o_gfx_rv   <= 1'b1;
    end
  end

endmodule
