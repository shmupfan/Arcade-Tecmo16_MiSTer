//============================================================================
//  Tecmo 16 (Final Star Force, Riot, Ganbare Ginkun) for MiSTer -
//  framework shell (M4)
//
//  Wraps rtl/t16_board.sv (68000, Z80 sound board, video, YM2151, M6295,
//  SDRAM, download) in the Template_MiSTer `emu` interface. The MRA selects
//  the machine with the index-1 byte (0 Final Star Force, 1 Riot, 2 Ganbare
//  Ginkun) and streams the SDRAM image on index 0 (tools/make_mra.py). Final
//  Star Force is vertical (ROT90) and is rotated through the framework's
//  screen_rotate (DDR3 frame buffer, MISTER_FB=1).
//
//  Clocks (pll.v, as Dooyong and 1945k III): 96 MHz system, a -90 degree
//  copy for SDRAM_CLK, and 48 MHz for the video path (arcade_video's HQ2x
//  does not close timing at 96 MHz; Dooyong m4_findings 4). The core's
//  pixel enable is fractional, so each pixel is handed to the 48 MHz domain
//  with a toggle: the core side latches the pixel and flips the toggle on its
//  enable, the video side registers the toggle and makes a one-clock enable
//  from its change. Pixels are at least 16 core clocks apart (MAME raster:
//  5.82 MHz; the 6 MHz alternative: 16), so the latched pixel is long stable.
//
//  Raster (research item R3, decision pending): RASTER_MAME = 1 builds MAME's
//  59.17 Hz frame of 256 lines (the M2 gate configuration, frame-exact
//  against MAME's IRQ5 trace); 0 builds the 6 MHz 384 x 264 raster MAME's
//  TODO guesses (59.19 Hz).
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

localparam bit RASTER_MAME = 1'b1;
localparam int PIX_NUM = RASTER_MAME ? 47336  : 1;
localparam int PIX_DEN = RASTER_MAME ? 781250 : 16;
localparam int V_TOTAL = RASTER_MAME ? 256    : 264;

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign BUTTONS = 0;
assign VGA_F1 = 1'b0;
assign VGA_SCALER = 1'b0;
assign VGA_DISABLE = 1'b0;
assign HDMI_FREEZE = 1'b0;
assign HDMI_BLACKOUT = 1'b0;
assign HDMI_BOB_DEINT = 1'b0;
assign FB_FORCE_BLANK = 1'b0;
assign AUDIO_MIX = 2'b00;

// ---------------------------------------------------------------------------
// clocks
// ---------------------------------------------------------------------------
wire clk_sys, clk_sdram, clk_vid, pll_locked;
pll pll (
	.refclk(CLK_50M),
	.rst(1'b0),
	.outclk_0(clk_sys),      // 96 MHz
	.outclk_1(clk_sdram),    // 96 MHz, -90 degrees
	.outclk_2(clk_vid),      // 48 MHz, phase aligned with clk_sys
	.locked(pll_locked)
);
assign SDRAM_CLK = clk_sdram;

// ---------------------------------------------------------------------------
// hps_io
// ---------------------------------------------------------------------------
`include "build_id.v"
localparam CONF_STR = {
	"Tecmo16;;",
	"-;",
	"H0OMN,Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"H0O2,Orientation,Vertical,Horizontal;",
	"H1O7,Rotate,CW,CCW;",
	"O35,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"H0O[13:12],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"d2O[14],Vertical Crop,Disabled,216p(5x);",
	"d3O[18:15],Crop Offset,0,1,2,3,4,-4,-3,-2,-1;",
	"O6,Pause when OSD is open,On,Off;",
	"-;",
	"DIP;",
	"-;",
	"R0,Reset;",
	"J1,Button 1,Button 2,Button 3,Start,Coin;",
	"jn,A,B,X,Start,Select;",
	"V,v",`BUILD_DATE
};

wire [127:0] status;
wire  [1:0] buttons;
wire        forced_scandoubler;
wire        allow_vcrop, vcrop_216;   // video options (assigned with video_freak below)
wire        direct_video;
wire [21:0] gamma_bus;
wire        video_rotated;

wire        ioctl_download;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire [15:0] ioctl_index;
wire        ioctl_wait;

wire [31:0] joystick_0, joystick_1;
wire [10:0] ps2_key;

wire [1:0]  machine;
wire        vertical = (machine == 2'd0);        // Final Star Force, ROT90

hps_io #(.CONF_STR(CONF_STR)) hps_io (
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),
	.buttons(buttons),
	.status(status),
	.status_menumask({12'd0, vcrop_216, allow_vcrop, ~vertical, direct_video}),
	.forced_scandoubler(forced_scandoubler),
	.direct_video(direct_video),
	.video_rotated(video_rotated),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),
	.ioctl_upload(),
	.ioctl_upload_req(1'b0),
	.ioctl_upload_index(8'd0),
	.ioctl_din(8'd0),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.ps2_key(ps2_key)
);

// ---------------------------------------------------------------------------
// keyboard, MAME default keys (ps2_key: [10] toggles per event, [9] pressed,
// [8] extended, [7:0] set-2 scancode). From the first build.
//   P1: arrows, LCtrl = B1, LAlt = B2, Space = B3, 1 = Start, 5 = Coin,
//       P = pause toggle
//   P2: R/F/D/G, A = B1, S = B2, Q = B3, 2 = Start, 6 = Coin
// ---------------------------------------------------------------------------
reg k_up, k_dn, k_lt, k_rt, k_b1, k_b2, k_b3, k_st1, k_co1;
reg k2_up, k2_dn, k2_lt, k2_rt, k2_b1, k2_b2, k2_b3, k_st2, k_co2;
reg ps2_last = 1'b0;
reg k_pause = 1'b0;
always @(posedge clk_sys) begin
	ps2_last <= ps2_key[10];
	if (ps2_key[10] != ps2_last) begin
		case ({ps2_key[8], ps2_key[7:0]})
			9'h175: k_up  <= ps2_key[9];
			9'h172: k_dn  <= ps2_key[9];
			9'h16B: k_lt  <= ps2_key[9];
			9'h174: k_rt  <= ps2_key[9];
			9'h014: k_b1  <= ps2_key[9];   // left ctrl
			9'h011: k_b2  <= ps2_key[9];   // left alt
			9'h029: k_b3  <= ps2_key[9];   // space
			9'h016: k_st1 <= ps2_key[9];   // 1
			9'h01E: k_st2 <= ps2_key[9];   // 2
			9'h02E: k_co1 <= ps2_key[9];   // 5
			9'h036: k_co2 <= ps2_key[9];   // 6
			9'h02D: k2_up <= ps2_key[9];   // R
			9'h02B: k2_dn <= ps2_key[9];   // F
			9'h023: k2_lt <= ps2_key[9];   // D
			9'h034: k2_rt <= ps2_key[9];   // G
			9'h01C: k2_b1 <= ps2_key[9];   // A
			9'h01B: k2_b2 <= ps2_key[9];   // S
			9'h015: k2_b3 <= ps2_key[9];   // Q
			9'h04D: if (ps2_key[9]) k_pause <= ~k_pause;   // P
			default: ;
		endcase
	end
end
// MiSTer joystick: 0 R, 1 L, 2 D, 3 U, then the J1 list: 4 B1, 5 B2, 6 B3,
// 7 Start, 8 Coin
wire [8:0] joy0 = joystick_0[8:0] | {k_co1, k_st1, k_b3, k_b2, k_b1, k_up, k_dn, k_lt, k_rt};
wire [8:0] joy1 = joystick_1[8:0] | {k_co2, k_st2, k2_b3, k2_b2, k2_b1, k2_up, k2_dn, k2_lt, k2_rt};

// ---------------------------------------------------------------------------
// inputs in MAME's layout (reference/mame/tecmo16.cpp INPUT_PORTS)
//   P1_P2  bits 0-3 P1 right, left, down, up; 4-5 P1 buttons; 6 Start 1;
//          7 Start 2; 8-11 P2 directions; 12-13 P2 buttons (all active low);
//          14 Coin 1, 15 Coin 2 (active high)
//          Final Star Force / Ginkun: the buttons are Button 1, Button 2
//          Riot: P1_P2 holds Button 2, Button 3; Button 1 is in EXTRA
//   EXTRA  Riot: bit 1 P1 Button 1, bit 5 P2 Button 1 (active low), others 1
//          (MAME 0xffdd unknown, active low); other games: MAME's empty port
// ---------------------------------------------------------------------------
wire       riot = (machine == 2'd1);
wire [1:0] p1b = riot ? joy0[6:5] : joy0[5:4];
wire [1:0] p2b = riot ? joy1[6:5] : joy1[5:4];
wire [15:0] p1p2 = {joy1[8], joy0[8], ~p2b, ~joy1[3:0], ~joy1[7], ~joy0[7], ~p1b, ~joy0[3:0]};
wire [15:0] extra = riot ? ~{10'd0, joy1[4], 3'd0, joy0[4], 1'b0} : 16'h0000;

// ---------------------------------------------------------------------------
// board
// ---------------------------------------------------------------------------
wire reset = RESET | status[0] | buttons[1];
// Pause: the menu is open (option O6, default on) or P was pressed. t16_sys
// holds the 68000 and the sound board; the video keeps scanning.
wire pause = (OSD_STATUS & ~status[6]) | k_pause;

wire [7:0] r, g, b;
wire       hbl, vbl, hs, vs, de, ce_pix;
wire signed [15:0] aud_l, aud_r;

t16_board #(.CLK_HZ(96000000), .PIX_NUM(PIX_NUM), .PIX_DEN(PIX_DEN), .V_TOTAL(V_TOTAL)) board (
	.clk(clk_sys), .i_sdram_rst_n(pll_locked), .i_reset(reset),
	.i_ioctl_download(ioctl_download), .i_ioctl_wr(ioctl_wr), .i_ioctl_addr(ioctl_addr),
	.i_ioctl_dout(ioctl_dout), .i_ioctl_index(ioctl_index), .o_ioctl_wait(ioctl_wait),
	.i_p1p2(p1p2), .i_extra(extra), .i_pause(pause),
	.o_r(r), .o_g(g), .o_b(b), .o_hblank(hbl), .o_vblank(vbl), .o_hs(hs), .o_vs(vs),
	.o_de(de), .o_ce_pix(ce_pix), .o_left(aud_l), .o_right(aud_r), .o_machine(machine),
	.o_vbl(), .o_vid_busy(), .o_cpu_pc_dbg(),
	.o_dbg_overruns(), .o_dbg_maxcyc(), .o_dbg_ref_forced(), .o_dbg_cpu_maxlat(),
	.o_dbg_verr(), .o_dbg_rom_writes(), .o_dbg_unmapped(), .o_dbg_prom_late(),
	.o_dbg_vreg_other(), .o_dbg_snd_unmapped(),
	.SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ),
	.SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_nCS(SDRAM_nCS),
	.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE),
	.SDRAM_CKE(SDRAM_CKE)
);

// ---------------------------------------------------------------------------
// video: 256 x 224 (MAME visarea 0-255 x 16-239). Final Star Force is ROT90:
// the picture is turned 90 degrees clockwise. Flip screen is the games' own
// DIP switch (the game writes the flip register, spec), not an OSD option.
// ---------------------------------------------------------------------------
wire no_rotate  = status[2] | direct_video | ~vertical;
// ROT90 turns the picture 90 degrees clockwise (MAME). OSD "Rotate CCW" turns
// it the other way, for monitors mounted for ROT270 games (status[7]).
wire rotate_ccw = status[7];
wire flip       = 1'b0;

wire [1:0] ar = status[23:22];

// HDMI options through the framework's video_freak (as the Hyper Duel core):
// aspect, integer scale, and a 216-line crop (an exact 5x on 1080p) of the
// 224-line picture. The crop masks VGA_DE, so it only applies to output that
// is not rotated (screen_rotate's frame buffer feeds the scaler for Final
// Star Force, which keeps the whole picture): it is offered for Riot and
// Ganbare Ginkun, and for Final Star Force with Orientation Horizontal.
// Scale applies either way. Rotate CW/CCW only affects the HDMI frame
// buffer; on a CRT the picture is not rotated (Flip Screen DIP instead).
wire [1:0] scale = status[13:12];
assign allow_vcrop = ~forced_scandoubler & (scale == 2'd0) & no_rotate;
assign vcrop_216   = allow_vcrop & status[14];
// offsets 0..4 then -4..-1, as a 5-bit two's complement for CROP_OFF
wire [4:0] crop_off = (status[18:15] < 4'd5) ? {1'b0, status[18:15]}
                                              : ({1'b0, status[18:15]} + 5'd23);
wire       vga_de_mix;

// core side: latch each pixel and flip the toggle
reg        px_tog = 1'b0;
reg  [7:0] r_h, g_h, b_h;
reg        hbl_h, vbl_h, hs_h, vs_h;
always @(posedge clk_sys) begin
	if (ce_pix) begin
		px_tog <= ~px_tog;
		{r_h, g_h, b_h} <= {r, g, b};
		{hbl_h, vbl_h, hs_h, vs_h} <= {hbl, vbl, hs, vs};
	end
end

// video side: one enable per toggle change, pixel taken one clock later
reg        tog1 = 1'b0, tog2 = 1'b0;
reg        ce_vid;
reg  [7:0] r_v, g_v, b_v;
reg        hbl_v, vbl_v, hs_v, vs_v;
always @(posedge clk_vid) begin
	tog1   <= px_tog;
	tog2   <= tog1;
	ce_vid <= (tog1 != tog2);
	if (tog1 != tog2) begin
		{r_v, g_v, b_v} <= {r_h, g_h, b_h};
		{hbl_v, vbl_v, hs_v, vs_v} <= {hbl_h, vbl_h, hs_h, vs_h};
	end
end

screen_rotate screen_rotate (.*);

arcade_video #(.WIDTH(256), .DW(24)) arcade_video (
	.*,
	.clk_video(clk_vid),
	.ce_pix(ce_vid),
	.RGB_in({r_v, g_v, b_v}),
	.HBlank(hbl_v),
	.VBlank(vbl_v),
	.HSync(hs_v),
	.VSync(vs_v),
	.fx(status[5:3]),
	.VGA_DE(vga_de_mix)
);

video_freak video_freak (
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),
	.VGA_DE_IN(vga_de_mix),
	.ARX((!ar) ? ((no_rotate) ? 12'd4 : 12'd3) : {10'd0, ar - 2'd1}),
	.ARY((!ar) ? ((no_rotate) ? 12'd3 : 12'd4) : 12'd0),
	.CROP_SIZE(vcrop_216 ? 12'd216 : 12'd0),
	.CROP_OFF(crop_off),
	.SCALE({1'b0, scale})
);

// ---------------------------------------------------------------------------
// audio (stereo, MAME's routing: YM2151 left/right, M6295 to both; mixed in
// t16_snd) / LEDs
// ---------------------------------------------------------------------------
assign AUDIO_L = aud_l;
assign AUDIO_R = aud_r;
assign AUDIO_S = 1'b1;

assign LED_USER  = ioctl_download;
assign LED_POWER = 2'b00;
assign LED_DISK  = 2'b00;

endmodule
