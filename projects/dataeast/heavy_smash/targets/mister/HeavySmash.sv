//  Heavy Smash -- MiSTer target wrapper.
//
//  Everything hps_io / ioctl / MRA lives on this side of the line and out
//  of rtl/ (root CLAUDE.md section 4).  Structure follows stadium_hero's
//  StadiumHero.sv, which is running on hardware.
//
//  First bring-up build: no debug overlay yet.  What is here is the minimum
//  honest MiSTer core: standard OSD (docs/OSD_POLICY.md), download, SDRAM,
//  video, audio, pause.
module emu
(
	`include "sys/emu_ports.vh"
);

///////// Ports this core does not use /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN,
        DDRAM_BE, DDRAM_WE, DDRAM_RD} = 0;

// 320x240 on a 4:3 monitor is the original.
wire [1:0] ar = status[122:121];
assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

assign VGA_F1        = 0;
assign VGA_SCALER    = 0;
assign VGA_DISABLE   = 0;
assign HDMI_FREEZE   = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

// Mono board: both OKIs route into one speaker (hvysmsh.cpp:377-383).
assign AUDIO_S   = 1;
assign AUDIO_L   = snd_l;
assign AUDIO_R   = snd_r;
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
// Solid while ROMs load, then a slow blink while the third PLL output counts.
assign LED_USER  = ioctl_download | pll_alive;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

`include "build_id.v"
localparam CONF_STR = {
	"HVYSMSH;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[4:2],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"-;",
	// DIP section: the loader only applies an .mra <switches> block when
	// the core's OSD has a DIP section to put it in.  Without this line
	// the probe .mra's default (ROM probe On at load, <switches base="11">)
	// was silently dropped and the board ran the game path -- probe6/7
	// showed white liveness, never probe yellow (2026-09-20).
	"DIP;",
	"-;",
	"O[12],Pause when OSD open,On,Off;",
	"-;",
	"O[6],Swap Joysticks,Off,On;",
	// Service is a cabinet switch, so docs/OSD_POLICY.md section 3 sends it
	// to the .mra <switches> block first -- but hvysmsh.mra has none (this
	// board reads service through the input port, not a DIP bank), which is
	// that section's second case: an OSD item, and never a key mapping.
	"O[13],Service,Off,On;",
	"-;",
	// Everything diagnostic lives on this page (root CLAUDE.md 1.4.5).  The
	// BITS DO NOT MOVE: .mra files ship defaults by bit number --
	// games/hvysmsh_probe.mra sets ROM probe via <switches base="11"> -- so
	// moving one re-points every .mra that carries it.  Page and order only.
	"P1,Debug;",
	"P1O[11],ROM probe,Off,On;",
	// Default Off now.  It was On through bring-up, when the overlay was the
	// only instrument on this board; the board draws MAME's picture and runs
	// a match now, and these rows cover the top 64 lines of it.
	"P1O[14],Debug overlay,Off,On;",
	// Bring-up switches.  Both rely on the ONE default mechanism this board
	// has proven (DEBUG_LOG D3): MiSTer zeroes status on core load
	// (docs/OSD_POLICY.md section 1), so the FIRST-listed value is the
	// default.  No loader cooperation of any kind.
	//   ROM probe      Off by default: the game path.  (Until D9 it was ON by
	//                  default, which -- with the probe/CPU ownership bug --
	//                  meant the ARM never once ran against real ROM data.)
	//   Debug overlay  On by default while the core is being brought up.
	"-;",
	"R[0],Reset;",
	// hvysmsh.cpp:199-219: three buttons per player, then Start.  Coin on
	// Select, Pause on R.
	"J1,Attack,Jump,Spare,Start,Coin,Pause;",
	"jn,A,B,X,Start,Select,R;",
	"V,v",`BUILD_DATE
};

wire         forced_scandoubler;
wire [21:0]  gamma_bus;
wire [127:0] status;
wire  [1:0]  buttons;

wire         ioctl_download;
wire         ioctl_wr;
wire [26:0]  ioctl_addr;
wire  [7:0]  ioctl_dout;
wire [15:0]  ioctl_index;
wire         ioctl_wait;

wire [31:0]  joystick_0, joystick_1;
wire [10:0]  ps2_key;

hps_io #(.CONF_STR(CONF_STR), .WIDE(0)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),
	.buttons(buttons),
	.status(status),
	.status_menumask(16'd0),
	.status_in(128'd0),
	.status_set(1'b0),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_2(),
	.joystick_3(),

	.ps2_key(ps2_key),

	// hps_io declares these inputs with no default, so leaving them open
	// makes them FLOAT.  Tie every one off explicitly (NA-1/NA-2 lesson).
	.joystick_0_rumble(16'd0),
	.joystick_1_rumble(16'd0),
	.joystick_2_rumble(16'd0),
	.joystick_3_rumble(16'd0),
	.joystick_4_rumble(16'd0),
	.joystick_5_rumble(16'd0),
	.ps2_kbd_clk_in(1'b0),
	.ps2_kbd_data_in(1'b0),
	.ps2_kbd_led_status(3'd0),
	.ps2_kbd_led_use(3'd0),
	.ps2_mouse_clk_in(1'b0),
	.ps2_mouse_data_in(1'b0),
	.video_rotated(1'b0),
	.new_vmode(1'b0),
	.info_req(1'b0),
	.info(8'd0),
	.sd_lba('{default:32'd0}),
	.sd_blk_cnt('{default:6'd0}),
	.sd_rd(1'b0),
	.sd_wr(1'b0),
	.sd_buff_din('{default:8'd0}),
	.ioctl_upload(),
	.ioctl_upload_req(1'b0),
	.ioctl_upload_index(8'd0),
	.ioctl_din(8'd0)
);

///////////////////   OSD DEFAULTS   /////////////////////////////////////
//
// The probe ON default comes from the .mra <switches> block (base=11),
// applied by the loader.  An earlier attempt injected defaults here by
// latching an ioctl index-1 download into status_req via status_set --
// it never reached status on hardware (the main binary does not round-
// trip status_req at load), and with the tiles ALSO on index 1 the
// latch would have swallowed tile bytes as "status".  Removed; do not
// re-add without a hardware-proven mechanism.

///////////////////////   CLOCKS   ///////////////////////////////
//
// 100.000 MHz single domain: the ARM core came from the GBA MiSTer core
// where it runs at 100 MHz, and every board rate divides from it
// (rtl/hs_cen.sv).  outclk_1 is SDRAM_CLK at 180 degrees (-5000 ps).
wire clk_sys, clk_sdram, clk_aux, pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram),
	.outclk_2(clk_aux),
	.locked(pll_locked)
);

assign SDRAM_CLK = clk_sdram;

// The third PLL output keeps a real load so the solver cannot delete it and
// re-solve the VCO (stadium_hero measured that failure).  A slow blink on
// the user LED says it is running.
reg [26:0] aux_cnt = 27'd0;
always @(posedge clk_aux) aux_cnt <= aux_cnt + 27'd1;

reg [2:0] aux_sync = 3'd0;
always @(posedge clk_sys) aux_sync <= {aux_sync[1:0], aux_cnt[26]};
wire pll_alive = aux_sync[2];

wire rst_sys = RESET | status[0] | buttons[1] | ~pll_locked;
wire rst_mem = ~pll_locked;

///////////////////////   INPUT   ////////////////////////////////
//
// hvysmsh INPUTS (hvysmsh.cpp:199-219), active low.  Per player:
//   0 up 1 down 2 left 3 right 4 b1 5 b2 6 b3 7 start
// MiSTer joystick order: 0 right 1 left 2 down 3 up 4 A 5 B 6 X
// (J1 maps the names; the positions are what the game sees).
wire [31:0] j1 = joystick_0;
wire [31:0] j2 = joystick_1;
wire swap_js = status[6];

wire [31:0] ja = swap_js ? j2 : j1;
wire [31:0] jb = swap_js ? j1 : j2;

// EIGHT bits each, not sixteen.  These are one player's byte of the input
// word; declaring them 16 made the concatenation below 36 bits wide and
// Quartus truncated it to 20 -- Warning (10230) at this file's line 223,
// which was real and was sitting in 4164 others.  What the board did with
// the truncated word: P1 worked, ALL EIGHT P2 bits sat at 0 (pressed -- the
// port is active low), and coin moved off Select onto P2's d-pad, so there
// was no way to put a coin in.  Reported from the cabinet as "the keys do
// not work", 2026-09-21.
wire  [7:0] p1n = ~{ ja[7],              // 7 start (jn Start)
                     ja[6], ja[5], ja[4], // 6..4 buttons 3,2,1 (X, B, A)
                     ja[0], ja[1], ja[2], ja[3] };   // 3..0 right,left,down,up
wire  [7:0] p2n = ~{ jb[7],
                     jb[6], jb[5], jb[4],
                     jb[0], jb[1], jb[2], jb[3] };

// Service is a cabinet switch (one per cabinet, no player): OSD only
// (docs/OSD_POLICY.md section 3).  bits 19..16 of the input word:
// 19 test(1) 18 service 17 coin2 16 coin1 -- coin on Select (jn bit 8).
// The coin bits need the SAME inversion the player bytes get: the port is
// active low and a MiSTer joystick bit is 1 when pressed, so an unpressed
// Select left coin1 at 0 -- held down forever.  Invisible until the
// truncation above was fixed, because before that these two bits were
// sliced off entirely and P2's d-pad sat in their place.  What it looked
// like on the board: the game credited itself and started a match on its
// own (2026-09-22 screenshot).
wire [19:0] pads = { 1'b1, ~status[13], ~jb[8], ~ja[8], p2n, p1n };

// --- Pause: OSD-auto + pad toggle, always released by a download ----------
wire pause_btn = j1[9] | j2[9];
reg  pause_btn_d, pause_latch;
always @(posedge clk_sys) begin
	pause_btn_d <= pause_btn;
	if (ioctl_download)                pause_latch <= 1'b0;
	else if (~pause_btn_d & pause_btn) pause_latch <= ~pause_latch;
end
wire pause_core = pause_latch | (OSD_STATUS & ~status[12]);

///////////////////////   THE BOARD   ////////////////////////////

wire [24:0] mem_addr;
wire [15:0] mem_din, mem_dout;
wire        mem_req, mem_we, mem_ack;
wire [1:0]  mem_ds;

wire        dl_active, dl_req, dl_ack;
wire [24:0] dl_addr;
wire [15:0] dl_data;

wire [7:0]  vid_r, vid_g, vid_b;
wire        hs, vs, hblank, vblank, ce_pix;
wire signed [15:0] snd_l, snd_r;
wire [31:0] dbg_pc;
wire        dbg_eep_cs;
wire [7:0]  dbg_liveness;
wire [7:0]  dbg_liveness2;
wire [2:0] probe_st;
wire [2:0] probe_idx;
wire [15:0] dbg_sum_lo, dbg_sum_hi;
wire [7:0]  probe_ok;
wire        probe_done_w;
wire        dbg_arb_dl, dbg_arb_req, dbg_arb_ack;
wire [2:0]  dbg_arb_sel;
wire [31:0] dbg_q74, dbg_q78;
wire [11:0] dbg_stores;
wire [3:0]  dbg_st_ctl, dbg_st_io120;
assign probe_done_w = probe_st == 3'd5;   // S_IDLE
wire        probe_en = status[11];      // default Off -- see the O[11] comment
wire        ov_en    = status[14];   // "Off,On" -> status 0 is Off     // default On  -- see the O[14] comment
wire [7:0]  dbg_ev;
wire [19:0] dbg_romhw;
wire [1:0]  dbg_mode;

hs_top u_board
(
	.clk        (clk_sys),
	.rst        (rst_sys),
	.mem_rst    (rst_mem),
	.pause      (pause_core),

	.mem_addr   (mem_addr),
	.mem_din    (mem_din),
	.mem_dout   (mem_dout),
	.mem_req    (mem_req),
	.mem_we     (mem_we),
	.mem_ds     (mem_ds),
	.mem_ack    (mem_ack),

	.dl_active  (dl_active),
	.dl_addr    (dl_addr),
	.dl_data    (dl_data),
	.dl_req     (dl_req),
	.dl_ack     (dl_ack),

	.pads       (pads),

	.red        (vid_r),
	.green      (vid_g),
	.blue       (vid_b),
	.hsync      (hs),
	.vsync      (vs),
	.hblank     (hblank),
	.vblank     (vblank),
	.ce_pix     (ce_pix),

	.snd_l      (snd_l),
	.snd_r      (snd_r),

	.dbg_pc     (dbg_pc),
	.dbg_eep_cs (dbg_eep_cs),
	.dbg_liveness (dbg_liveness),
	.dbg_liveness2 (dbg_liveness2),
	.probe_en     (probe_en),
	.probe_ok     (probe_ok),
	.dbg_probe_st (probe_st),
	.dbg_probe_idx (probe_idx),
	.dbg_probe_sum_lo (dbg_sum_lo),
	.dbg_probe_sum_hi (dbg_sum_hi),
	.dbg_arb_dl (dbg_arb_dl),
	.dbg_arb_sel (dbg_arb_sel),
	.dbg_arb_req (dbg_arb_req),
	.dbg_arb_ack (dbg_arb_ack),
	.dbg_q74 (dbg_q74), .dbg_q78 (dbg_q78),
	.dbg_stores (dbg_stores), .dbg_st_ctl (dbg_st_ctl),
	.dbg_st_io120 (dbg_st_io120),
	.dbg_ev       (dbg_ev),
	.dbg_romhw    (dbg_romhw),
	.dbg_mode     (dbg_mode)
);

///////////////////////   DOWNLOAD   /////////////////////////////

hs_download u_download
(
	.clk            (clk_sys),
	.rst            (rst_mem),
	.ioctl_download (ioctl_download),
	.ioctl_wr       (ioctl_wr),
	.ioctl_addr     (ioctl_addr),
	.ioctl_dout     (ioctl_dout),
	.ioctl_index    (ioctl_index),
	.ioctl_wait     (ioctl_wait),
	.dl_addr        (dl_addr),
	.dl_data        (dl_data),
	.dl_req         (dl_req),
	.dl_ack         (dl_ack),
	.dl_active      (dl_active)
);

///////////////////////   SDRAM   ////////////////////////////////

reg  [3:0] sdram_init_cnt = 0;
wire       sdram_init = ~sdram_init_cnt[3];
always @(posedge clk_sys) begin
	if (!pll_locked)     sdram_init_cnt <= 0;
	else if (sdram_init) sdram_init_cnt <= sdram_init_cnt + 1'd1;
end

hs_sdram #(.CLK_HZ(100_000_000), .REFRESH_CLK(700)) u_sdram
(
	.clk        (clk_sys),
	.init       (sdram_init),
	.addr       (mem_addr),
	.din        (mem_din),
	.dout       (mem_dout),
	.req        (mem_req),
	.we         (mem_we),
	.ds         (mem_ds),
	.ack        (mem_ack),
	.SDRAM_A    (SDRAM_A),
	.SDRAM_BA   (SDRAM_BA),
	.SDRAM_DQ   (SDRAM_DQ),
	.SDRAM_DQML (SDRAM_DQML),
	.SDRAM_DQMH (SDRAM_DQMH),
	.SDRAM_nCS  (SDRAM_nCS),
	.SDRAM_nWE  (SDRAM_nWE),
	.SDRAM_nRAS (SDRAM_nRAS),
	.SDRAM_nCAS (SDRAM_nCAS),
	.SDRAM_CKE  (SDRAM_CKE)
);

///////////////////////   VIDEO   ////////////////////////////////

// ---- bring-up overlay: the liveness byte as eight 16x8 cells, row 0 ----
reg [8:0] dbg_x;
reg [8:0] dbg_y;
reg       dbg_ce_d;
always @(posedge clk_sys) begin
	dbg_ce_d <= ce_pix;
	if (ce_pix) begin
		dbg_x <= (dbg_x == 9'd395) ? 9'd0 : dbg_x + 9'd1;
		if (dbg_x == 9'd395)
			dbg_y <= (dbg_y == 9'd271) ? 9'd0 : dbg_y + 9'd1;
	end
end
wire dbg_on = ov_en && (dbg_y >= 8) && (dbg_y < 16);
// row 2, capture lines 8..15: extended liveness, 16 cells of 8px.
// Left half = the original byte (PC,vblank,tdone,sdone,pal,sprwe,romok,
// okibk).  Right half (D1's MAME-order boot strobes): ctl_we, vram_we,
// row_we, oki0_re, oki1_re, vol_we, eep_cs, unused.  With the ROM probe
// at 8/8 (probe21) the data path is exonerated; WHICH of these never
// fires says how far the ARM gets before dying.
wire dbg_on2 = ov_en && (dbg_y >= 16) && (dbg_y < 24);
wire [7:0] ov_r, ov_g, ov_b;
// probe mode, two distinguishable rows of content:
//   sweep finished -> probe_ok (bit i = dword i matched)
//   sweep running  -> {rst_sys, sel[2:0], req, ack, 0, 1}:
//     rst=1 the whole board reset is held (probe stuck in reset while the
//     arbiter, on the separate mem reset, keeps serving video -- matches
//     probe11's frozen S_REQ_LO with req/ack pulsing);  sel flickering 1/2
//     = video clients hogging;  sel=3 = our request latched but the FSM
//     never consuming;  req without ack = SDRAM port not answering.
//   (probe10 read {st=0, idx=0, marker}: stuck before the first cpu_ok)
wire [7:0] row_bits = probe_en ? {probe_done_w ? probe_ok
                                              : {rst_sys, dbg_arb_sel, dbg_arb_req, dbg_arb_ack, 1'b0, 1'b1}}
                               : dbg_liveness;
wire dbg_white = dbg_on && (dbg_x < 9'd128) && row_bits[7-(dbg_x/16)];
wire [15:0] lv16 = {dbg_liveness, dbg_liveness2};
wire dbg_white2 = dbg_on2 && (dbg_x < 9'd128) && lv16[15-(dbg_x/8)];
// D6 diagnostic rows -- one build to split the three PC=0 hypotheses:
//   row3 (y 24..32): {rst_sys, buttons[1], status[0], cpu_rst} live plus
//     a 12-bit count of cpu_rst ASSERTION EDGES since download end.  A
//     reset loop shows a nonzero count; live bits say WHICH term is high.
//     Cleared only by dl_active, deliberately NOT by rst_sys -- otherwise
//     the very loop under test would erase its own evidence.
//   row4: pc_first -- first nonzero dbg_pc after download (the first
//     real fetch address; compare with the ROM's entry chain).
//   row5: pc_last_nz -- most recent nonzero dbg_pc, i.e. the last
//     executing address BEFORE the CPU landed on 0 (or proof it never
//     left 0: stays 0 while pc_seen is set).
//   row6: {pc_last_nz[23:16], flags} with flags =
//     {pc_zero_sticky, pc_seen, dbg_pc==0 live, 3'b0, marker 1}.
//   PC hypothesis split: reset loop -> row3 count climbs and rows 4/5
//   re-latch; branch to 0 -> count 0, pc_zero set, row5 = the culprit
//   site; sampling artifact -> pc_zero clear / PC bits moving.
wire dbg_on3 = ov_en && (dbg_y >= 24) && (dbg_y < 32);
wire dbg_on4 = ov_en && (dbg_y >= 32) && (dbg_y < 40);
wire dbg_on5 = ov_en && (dbg_y >= 40) && (dbg_y < 48);
wire dbg_on6 = ov_en && (dbg_y >= 48) && (dbg_y < 56);
wire cpu_rst_w = rst_sys | dl_active;
reg  [11:0] rst_cnt = 12'd0;
reg         cpu_rst_d = 1'b0;
reg  [31:0] pc_first = 32'd0;
reg  [31:0] pc_last_nz = 32'd0;
reg         pc_seen = 1'b0;
reg         pc_zero = 1'b0;
always @(posedge clk_sys) begin
	cpu_rst_d <= cpu_rst_w;
	if (dl_active) begin
		rst_cnt <= 12'd0; pc_seen <= 1'b0; pc_zero <= 1'b0;
		pc_first <= 32'd0; pc_last_nz <= 32'd0;
	end else begin
		if (cpu_rst_w & ~cpu_rst_d) rst_cnt <= rst_cnt + 12'd1;
		if (~cpu_rst_w) begin
			if (dbg_pc != 32'd0) begin
				pc_last_nz <= dbg_pc;
				if (!pc_seen) begin pc_first <= dbg_pc; pc_seen <= 1'b1; end
			end else if (pc_seen) pc_zero <= 1'b1;
		end
	end
end
wire [15:0] row3_bits = {rst_sys, buttons[1], status[0], cpu_rst_w, dbg_stores};
// D6 third cut.  Cut2 proved: no resets, pc_seen=1, pc_zero=0, PC walking
// forever -- but the walk values carry unseen HIGH bits (pc_last_big
// latched 0x??000014, satisfying [31:5]!=0 with low word 0x14 < 0x20),
// i.e. the storm's garbage PC writes keep overwriting the latch.  To find
// where REAL execution died:
//   row4: pc_last_code -- last PC in the valid code range [0x40,0x100000)
//         (excludes both the vector area AND garbage high-bit PCs)
//   row5: pc_2nd/pc_3rd -- the 2nd and 3rd DISTINCT nonzero PC values
//         after release, one byte each: boot trajectory.  04,08.. = the
//         very first fetch already storms (fetch data broken);
//         04,40/48.. = clean vector fetch, died later.
//   row6: {pc_last_code[23:16], flags} (8-bit concat this time!)
reg  [31:0] pc_last_code = 32'd0;
reg  [7:0]  pc_2nd = 8'd0, pc_3rd = 8'd0;
reg  [1:0]  pc_n = 2'd0;
reg  [7:0]  pc_prev = 8'd0;
wire [7:0] dbg_pc_lo = dbg_pc[7:0];
wire pc_in_code = (dbg_pc < 32'h100000) && (dbg_pc >= 32'h40);
always @(posedge clk_sys) begin
	if (dl_active) begin
		pc_last_code <= 32'd0; pc_2nd <= 8'd0; pc_3rd <= 8'd0;
		pc_n <= 2'd0; pc_prev <= 8'd0;
	end else begin
		if (pc_in_code) pc_last_code <= dbg_pc;
		if (dbg_pc != 32'd0 && dbg_pc_lo != pc_prev) begin
			pc_prev <= dbg_pc_lo;
			if (pc_n == 2'd0)      pc_2nd <= dbg_pc_lo;
			else if (pc_n == 2'd1) pc_3rd <= dbg_pc_lo;
			if (pc_n != 2'd3) pc_n <= pc_n + 2'd1;
		end
	end
end
// D8: is the CPU receiving the right instructions at the death window?
//   row4 = decoded dword fetched at 0x74 (expect E3A00002)
//   row5 = decoded dword fetched at 0x78 (expect E3A0181D)
//   row6 = {q74[23:16], ctl-store count, io120-store count, pc_seen, 1}
//   row3 keeps the reset live bits; its low 12 = bus store count
wire [15:0] row4_bits = dbg_q74[15:0];
wire [15:0] row5_bits = dbg_q78[15:0];
wire [15:0] row6_bits = {dbg_q74[23:16], dbg_st_ctl[2:0], dbg_st_io120[2:0], pc_seen, 1'b1};
// D9 row7 (capture y48): 16 cells of 8px = {dbg_ev[7:0], 6'b0, 2'b11}
//   ev bits are documented at hs_bus.sv (dbg_ev).  bit15 = ev[7] ... bit8 = ev[0].
//   bits 1:0 are a fixed 11 marker so an all-dark row means "row not drawn".
wire dbg_on7 = ov_en && (dbg_y >= 56) && (dbg_y < 64);
wire [15:0] row7_bits = {dbg_ev[7:0], 6'b000000, 2'b11};
wire dbg_white7 = dbg_on7 && (dbg_x < 9'd128) && row7_bits[15-(dbg_x/8)];
// row8 (capture y56): ROM read high-water mark and the CPU mode.
wire dbg_on8 = ov_en && (dbg_y >= 64) && (dbg_y < 72);
// row8: {ROM read high-water [19:8], cpu mode[1:0], 2'b11 marker}
//   mode is the 26-bit PSR mode: 0 USR, 1 FIQ, 2 IRQ, 3 SVC.
wire [15:0] row8_bits = {dbg_romhw[19:8], dbg_mode, 2'b11};
wire dbg_white8 = dbg_on8 && (dbg_x < 9'd128) && row8_bits[15-(dbg_x/8)];
wire dbg_white5 = dbg_on5 && (dbg_x < 9'd128) && row5_bits[15-(dbg_x/8)];
wire dbg_white6 = dbg_on6 && (dbg_x < 9'd128) && row6_bits[15-(dbg_x/8)];
wire dbg_white3 = dbg_on3 && (dbg_x < 9'd128) && row3_bits[15-(dbg_x/8)];
wire dbg_white4 = dbg_on4 && (dbg_x < 9'd128) && row4_bits[15-(dbg_x/8)];
// probe rows are YELLOW so a screenshot says which source drew them
wire any_ov = dbg_white || dbg_white2 || dbg_white3 || dbg_white4 || dbg_white5 || dbg_white6 || dbg_white7 || dbg_white8;
wire probe_yellow = probe_en && any_ov;
assign ov_r = any_ov ? 8'hFF : 8'h00;
assign ov_g = any_ov ? 8'hFF : 8'h00;
assign ov_b = probe_yellow ? 8'h00 : (any_ov ? 8'hFF : 8'h00);

wire [2:0] fx = status[4:2];

arcade_video #(.WIDTH(320), .DW(24)) arcade_video
(
	.*,
	.clk_video(clk_sys),
	.ce_pix(ce_pix),
	.RGB_in({ov_r | vid_r, ov_g | vid_g, ov_b | vid_b}),
	.HBlank(hblank),
	.VBlank(vblank),
	.HSync(hs),
	.VSync(vs),
	.fx(fx)
);

endmodule
