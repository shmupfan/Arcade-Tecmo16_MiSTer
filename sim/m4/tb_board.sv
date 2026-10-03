// M4 board-level testbench top: t16_board + the SDRAM model on one DQ bus.
// Driven from sim/m4/tb_board.cpp. Port names follow t16_sys's where the
// M2 harness uses them, so tb_board.cpp keeps m2/tb_sys.cpp's logic.
module tb_board #(
    parameter int PIX_NUM  = 47336,
    parameter int PIX_DEN  = 781250,
    parameter int V_TOTAL  = 256,
    parameter int IRQ_HOLD = 96000
) (
    input  logic        clk,
    input  logic        i_sdram_rst_n,
    input  logic        i_reset,
    input  logic        i_ioctl_download,
    input  logic        i_ioctl_wr,
    input  logic [26:0] i_ioctl_addr,
    input  logic [7:0]  i_ioctl_dout,
    input  logic [15:0] i_ioctl_index,
    output logic        o_ioctl_wait,
    input  logic [15:0] i_p1p2,
    input  logic [15:0] i_extra,
    input  logic        i_pause,
    output logic [7:0]  o_r,
    output logic [7:0]  o_g,
    output logic [7:0]  o_b,
    output logic        o_de,
    output logic        o_ce_pix,
    output logic        o_vbl,
    output logic        o_vid_busy,
    output logic [23:0] o_cpu_pc_dbg,
    output logic [1:0]  o_machine,
    output logic signed [15:0] o_left,
    output logic signed [15:0] o_right,
    output logic [15:0] o_dbg_overruns,
    output logic [15:0] o_dbg_maxcyc,
    output logic [15:0] o_dbg_ref_forced,
    output logic [7:0]  o_dbg_cpu_maxlat,
    output logic [7:0]  o_dbg_verr,
    output logic [15:0] o_dbg_rom_writes,
    output logic [15:0] o_dbg_unmapped,
    output logic [15:0] o_dbg_prom_late,
    output logic [15:0] o_dbg_vreg_other,
    output logic [15:0] o_dbg_snd_unmapped
);
  wire [12:0] A;
  wire [1:0]  BA;
  wire [15:0] DQ;
  wire        DQML, DQMH, nCS, nRAS, nCAS, nWE, CKE;
  logic hb, vb;
  logic hs /* verilator public_flat_rd */, vs /* verilator public_flat_rd */;

  t16_board #(.CLK_HZ(96000000), .PIX_NUM(PIX_NUM), .PIX_DEN(PIX_DEN), .V_TOTAL(V_TOTAL),
              .IRQ_HOLD(IRQ_HOLD), .SHORT_INIT(1'b1)) u_board (
    .clk(clk), .i_sdram_rst_n(i_sdram_rst_n), .i_reset(i_reset),
    .i_ioctl_download(i_ioctl_download), .i_ioctl_wr(i_ioctl_wr),
    .i_ioctl_addr(i_ioctl_addr), .i_ioctl_dout(i_ioctl_dout),
    .i_ioctl_index(i_ioctl_index), .o_ioctl_wait(o_ioctl_wait),
    .i_p1p2(i_p1p2), .i_extra(i_extra), .i_pause(i_pause),
    .o_r(o_r), .o_g(o_g), .o_b(o_b), .o_hblank(hb), .o_vblank(vb),
    .o_hs(hs), .o_vs(vs), .o_de(o_de), .o_ce_pix(o_ce_pix),
    .o_left(o_left), .o_right(o_right), .o_machine(o_machine),
    .o_vbl(o_vbl), .o_vid_busy(o_vid_busy), .o_cpu_pc_dbg(o_cpu_pc_dbg),
    .o_dbg_overruns(o_dbg_overruns), .o_dbg_maxcyc(o_dbg_maxcyc),
    .o_dbg_ref_forced(o_dbg_ref_forced), .o_dbg_cpu_maxlat(o_dbg_cpu_maxlat),
    .o_dbg_verr(o_dbg_verr), .o_dbg_rom_writes(o_dbg_rom_writes),
    .o_dbg_unmapped(o_dbg_unmapped), .o_dbg_prom_late(o_dbg_prom_late),
    .o_dbg_vreg_other(o_dbg_vreg_other), .o_dbg_snd_unmapped(o_dbg_snd_unmapped),
    .SDRAM_A(A), .SDRAM_BA(BA), .SDRAM_DQ(DQ), .SDRAM_DQML(DQML),
    .SDRAM_DQMH(DQMH), .SDRAM_nCS(nCS), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS),
    .SDRAM_nWE(nWE), .SDRAM_CKE(CKE));

  sdram_model u_mem (
    .clk(clk), .A(A), .BA(BA), .DQ(DQ), .DQML(DQML), .DQMH(DQMH),
    .nCS(nCS), .nRAS(nRAS), .nCAS(nCAS), .nWE(nWE), .CKE(CKE));
endmodule
