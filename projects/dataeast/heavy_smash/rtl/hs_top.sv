//============================================================================
//  Heavy Smash -- board top (DE-0385-2).
//
//  This is the arcade board and nothing else: no hps_io/ioctl/MRA (those
//  live in targets/), only a neutral memory port, download port, neutral
//  inputs, and video/audio out -- the same boundary every factory core
//  uses (pattern: stadium_hero sh_top.sv).
//
//  ---- clocking ------------------------------------------------------------
//  clk = 100.000 MHz, one domain; hs_cen makes every board rate.
//
//  ---- implemented ---------------------------------------------------------
//      DE156 ARM7 + full address decode + work RAM
//      DECO141 tilemaps with row/col scroll, DECO56 live decrypt
//      DECO52 sprites
//      palette 32-bit x 1024
//      dual MSM6295 with shared volume port
//      93C46 x16 EEPROM (jt9346)
//============================================================================
`default_nettype none

module hs_top (
    input  wire        clk,            // 100.000 MHz
    input  wire        rst,
    input  wire        mem_rst,
    input  wire        pause,

    // --- neutral memory port ---------------------------------------------------
    output wire [24:0] mem_addr,
    output wire [15:0] mem_din,
    input  wire [15:0] mem_dout,
    output wire        mem_req,
    output wire        mem_we,
    output wire [1:0]  mem_ds,
    input  wire        mem_ack,

    // --- download ------------------------------------------------------------------
    input  wire        dl_active,
    input  wire [24:0] dl_addr,
    input  wire [15:0] dl_data,
    input  wire        dl_req,
    output wire        dl_ack,

    // --- inputs -----------------------------------------------------------------------
    input  wire [19:0] pads,           // {p2[7:0], p1[7:0], coin2, coin1, service, test}, active low

    // --- video -------------------------------------------------------------------------
    output wire [7:0]  red, green, blue,
    output wire        hsync, vsync, hblank, vblank, ce_pix,

    // --- audio ---------------------------------------------------------------------------
    output wire signed [15:0] snd_l, snd_r,

    // --- observability ---------------------------------------------------------------------
    output wire [31:0] dbg_pc,
    output wire        dbg_eep_cs,
    output wire [7:0]  dbg_liveness,
    output wire [7:0]  dbg_liveness2,
    input  wire        probe_en,
    output wire [7:0]  probe_ok,
    output wire [2:0]  dbg_probe_st,
    output wire [2:0]  dbg_probe_idx,
    output wire [15:0] dbg_probe_sum_lo,
    output wire [15:0] dbg_probe_sum_hi,
    output wire        dbg_arb_dl,
    output wire [2:0]  dbg_arb_sel,
    output wire        dbg_arb_req,
    output wire        dbg_arb_ack,
    output wire [31:0] dbg_q74, dbg_q78,
    output wire [11:0] dbg_stores,
    output wire [3:0]  dbg_st_ctl, dbg_st_io120,
    output wire [7:0]  dbg_ev,
    output wire [19:0] dbg_romhw,
    output wire [1:0]  dbg_mode
);

    // ------------------------------------------------------------------ clock enables
    wire cen_arm, cen_pix, cen_oki0, cen_oki1;
    hs_cen u_cen (
        .clk(clk), .rst(rst),
        .cen_arm(cen_arm), .cen_pix(cen_pix),
        .cen_oki0(cen_oki0), .cen_oki1(cen_oki1)
    );

    // ROM integrity probe: owns the CPU's romarb client only WHILE IT RUNS.
    wire        pr_cs;
    wire [18:0] pr_addr;
    wire        pr_done;
    wire        pr_hold;
    wire [2:0]  pr_st, pr_idx;
    wire [15:0] pr_sum_lo, pr_sum_hi;
    wire        rom_cs;
    wire [18:0] rom_addr;
    wire [15:0] rom_data;
    wire        rom_ok;
    wire        bus_rom_cs;
    wire [18:0] bus_rom_addr;

    // probe_run = the probe is enabled and has not reached S_IDLE yet.
    //
    // D9 ROOT CAUSE (2026-09-21).  This mux and the CPU reset used to key on
    // probe_en alone.  Every board run since D3 had probe_en=1 (the OSD
    // default), so after the probe finished -- cpu_hold dropped, the ARM was
    // "released" -- the mux still routed the probe's (idle) request to
    // romarb and the ARM's own fetches (hs_bus rom_cs) went nowhere.  Worse,
    // rom_ok is a LEVEL (cpu_done & cpu_lat==cpu_addr) and the probe's last
    // address stayed on rom_addr: rom_ok stuck at 1 with rom_data the last
    // word the probe read, so hs_bus answered EVERY ROM read with
    // DE156(index, {W,W}) -- a fixed pseudo-random instruction stream.  That
    // is the "exception storm"; it never depended on gba_cpu.  While the
    // probe was RUNNING, hs_bus also consumed the probe's responses as its
    // own (cpu_hold gates only do_step; the fetch engine and hs_bus are
    // free-running), so the pipeline was pre-loaded with garbage.
    // sim/tb_top_mux.sv reproduces it (CPU fetch @0 = 5DD5903B, not
    // EA00000D) and, with probe_en=0, passes.
    //
    // So: the probe owns the client only while running, and the whole CPU
    // domain (hs_bus, ARM, tilegen, sprites, sound, EEPROM) is held in reset
    // for exactly that time, so nothing of the ARM side sees a probe response.
    wire probe_run = probe_en & ~pr_done;

    // REGISTERED, and that is not tidiness.  Both of these fan out to every
    // register in the CPU, and both are built from signals that arrive late
    // and from far away: dl_active comes off a 16-bit compare on ioctl_index
    // in the download block, pause comes off OSD_STATUS in the framework.
    // Left combinational, STA timed "16-bit compare + OR + cross-chip fan-out
    // to a thousand register resets" in one 10 ns period and missed by 3.1 ns
    // -- 200 of 200 reported failing paths were this one shape (D13).
    // A reset or a run-enable arriving one clock later changes nothing: both
    // are held for thousands of clocks.
    reg cpu_rst = 1'b1;
    reg arm_run = 1'b0;
    always @(posedge clk) begin
        cpu_rst <= rst | dl_active | probe_run;
        arm_run <= ~pause & ~dl_active;
    end

    // rom_data/rom_ok are the romarb CPU-client RESPONSE wires, shared by
    // hs_bus and the probe: the mux below picks whose cs/addr goes OUT; the
    // response comes back to whoever is listening, and only one ever is
    // (the CPU domain is in reset while the probe runs).  The first cut
    // declared pr_data/pr_ok here and never drove them -- the probe read
    // undriven wires and waited forever (probe9-12: arbiter serving
    // sel=CPU, FSM frozen).
    // held in reset while ANY region downloads: the probe starts the moment
    // pll locks, which is before the loader has written a byte -- its first
    // fetch then reads empty SDRAM (probe19: idx0 alone failed out of 8,
    // because idx1 stalled behind dl_active and read real data)
    hs_romprobe u_probe (
        .clk(clk), .rst(rst | dl_active), .probe_en(probe_en), .cpu_hold(pr_hold),
        .rom_cs(pr_cs), .rom_addr(pr_addr), .rom_data(rom_data), .rom_ok(rom_ok),
        .probe_ok(probe_ok), .probe_done(pr_done),
        .dbg_st(pr_st), .dbg_idx(pr_idx),
        .dbg_sum_lo(pr_sum_lo), .dbg_sum_hi(pr_sum_hi)
    );
    assign dbg_probe_st = pr_st;
    assign dbg_probe_idx = pr_idx;
    assign dbg_probe_sum_lo = pr_sum_lo;
    assign dbg_probe_sum_hi = pr_sum_hi;
    wire arm_hold = pr_hold;
    assign rom_cs   = probe_run ? pr_cs   : bus_rom_cs;
    assign rom_addr = probe_run ? pr_addr : bus_rom_addr;

    // ------------------------------------------------------------------ video timing
    wire [8:0]  rd_x;
    wire        rd_sel;
    wire [9:0]  q_pf1, q_pf2, q_spr;
    wire        line_go;
    wire [8:0]  line_y;
    wire        buf_sel;
    wire        tile_done, spr_done;
    wire        frame_odd;
    wire [9:0]  pal_ra;
    wire [31:0] pal_rq;

    // ------------------------------------------------------------------ ARM + bus
    wire [31:0] arm_adr, arm_dout, arm_din;
    wire        arm_rnw, arm_ena, arm_done;
    wire [1:0]  arm_acc;

    wire        ctl_we;
    wire [2:0]  ctl_wa, ctl_ra;
    wire [15:0] ctl_wd, ctl_rd;

    wire [11:0] vram_a;
    wire [15:0] vram_wd;
    wire        vram_we0, vram_we1;
    wire [15:0] vram_q0, vram_q1;

    wire [9:0]  row_a;
    wire [15:0] row_wd;
    wire        row_we0, row_we1;
    wire [15:0] row_q0, row_q1;

    wire [10:0] spr_a;
    wire [15:0] spr_wd;
    wire        spr_we;
    wire [15:0] spr_q;

    wire [9:0]  pal_a;
    wire [31:0] pal_wd;
    wire        pal_we;
    wire [31:0] pal_q;

    wire        vol_we;
    wire [7:0]  vol_d;
    wire        eep_di, eep_clk, eep_cs;
    wire        oki0_bk_we, oki0_bk;
    wire        oki1_bk_we;
    wire [2:0]  oki1_bk;
    wire        oki0_we, oki0_re, oki1_we, oki1_re;
    wire [7:0]  oki0_do, oki1_do;

    // the 0x120000 read word: pads + vblank (bit 20) + EEPROM DO (bit 24)
    // bits 31..25 unused (1), 24 = eeprom DO, 23..21 unused (1), 20 = vblank,
    // 19 test, 18 service, 17 coin2, 16 coin1, 15..8 P2, 7..0 P1.
    wire        vid_vblank;
    wire        eep_do;

    hs_bus u_bus (
        .clk(clk), .rst(cpu_rst),
        .arm_adr(arm_adr), .arm_rnw(arm_rnw), .arm_ena(arm_ena),
        .arm_acc(arm_acc), .arm_dout(arm_dout),
        .arm_din(arm_din), .arm_done(arm_done),
        .rom_cs(bus_rom_cs), .rom_addr(bus_rom_addr), .rom_data(rom_data), .rom_ok(rom_ok),
        .ctl_we(ctl_we), .ctl_wa(ctl_wa), .ctl_wd(ctl_wd), .ctl_ra(ctl_ra), .ctl_rd(ctl_rd),
        .vram_a(vram_a), .vram_wd(vram_wd),
        .vram_we0(vram_we0), .vram_we1(vram_we1),
        .vram_q0(vram_q0), .vram_q1(vram_q1),
        .row_a(row_a), .row_wd(row_wd),
        .row_we0(row_we0), .row_we1(row_we1),
        .row_q0(row_q0), .row_q1(row_q1),
        .spr_a(spr_a), .spr_wd(spr_wd), .spr_we(spr_we), .spr_q(spr_q),
        .spr_dma_we(spr_dma_we),
        .pal_a(pal_a), .pal_wd(pal_wd), .pal_we(pal_we), .pal_q(pal_q),
        .inputs(inputs_word),
        .vol_we(vol_we), .vol_d(vol_d),
        .eep_di(eep_di), .eep_clk(eep_clk), .eep_cs(eep_cs),
        .oki0_bk_we(oki0_bk_we), .oki0_bk(oki0_bk),
        .oki1_bk_we(oki1_bk_we), .oki1_bk(oki1_bk),
        .oki0_we(oki0_we), .oki0_re(oki0_re),
        .oki1_we(oki1_we), .oki1_re(oki1_re),
        .oki0_do(oki0_do), .oki1_do(oki1_do),
        .dbg_q74(dbg_q74), .dbg_q78(dbg_q78),
        .dbg_stores(dbg_stores), .dbg_st_ctl(dbg_st_ctl),
        .dbg_st_io120(dbg_st_io120),
        .dbg_ev(dbg_ev), .dbg_romhw(dbg_romhw)
    );

    wire [31:0] inputs_word = {7'h7F, eep_do, 3'h7, vid_vblank, pads};

    // DE156 = 26-bit ARM2 (docs/DEBUG_LOG.md D11).  Amber a23 + our memory
    // front end; 40000 boot stores match MAME exactly (sim/tb_amber_boot.sv).
    wire [1:0] arm_mode;
    hs_arm2 u_arm (
        .clk(clk), .rst(cpu_rst),
        .cen(arm_run & cen_arm & ~arm_hold),
        .irq(vid_vblank & arm_run),
        .bus_adr(arm_adr), .bus_rnw(arm_rnw), .bus_ena(arm_ena),
        .bus_acc(arm_acc), .bus_dout(arm_dout),
        .bus_din(arm_din), .bus_done(arm_done),
        .dbg_pc(dbg_pc), .dbg_mode(arm_mode)
    );
    assign dbg_mode = arm_mode;

    // ------------------------------------------------------------------ shared BRAMs
    wire [11:0] vram_a2;
    wire        vram_pf2, row_pf2;
    wire [9:0]  row_a2;
    // spr_a2/spr_q2 is now the DMA's read side of the live spriteram;
    // the renderer reads spr_sa/spr_sq, the shadow the DMA fills.
    wire        spr_dma_we;
    wire [10:0] spr_sa;
    wire [15:0] spr_sq;
    wire [10:0] spr_a2;
    wire [15:0] spr_q2;
    wire [15:0] vram_qb0, vram_qb1, row_qb0, row_qb1;
    wire [15:0] vram_q2 = vram_pf2 ? vram_qb1 : vram_qb0;
    wire [15:0] row_q2  = row_pf2  ? row_qb1 : row_qb0;

    hs_dpram16 #(.AW(12)) u_vram0 (
        .clk(clk),
        .a_addr(vram_a), .a_we(vram_we0), .a_wdata(vram_wd), .a_q(vram_q0),
        .b_addr(vram_a2), .b_q(vram_qb0)
    );
    hs_dpram16 #(.AW(12)) u_vram1 (
        .clk(clk),
        .a_addr(vram_a), .a_we(vram_we1), .a_wdata(vram_wd), .a_q(vram_q1),
        .b_addr(vram_a2), .b_q(vram_qb1)
    );
    hs_dpram16 #(.AW(10)) u_row0 (
        .clk(clk),
        .a_addr(row_a), .a_we(row_we0), .a_wdata(row_wd), .a_q(row_q0),
        .b_addr(row_a2), .b_q(row_qb0)
    );
    hs_dpram16 #(.AW(10)) u_row1 (
        .clk(clk),
        .a_addr(row_a), .a_we(row_we1), .a_wdata(row_wd), .a_q(row_q1),
        .b_addr(row_a2), .b_q(row_qb1)
    );
    hs_dpram16 #(.AW(11)) u_spram (
        .clk(clk),
        .a_addr(spr_a), .a_we(spr_we), .a_wdata(spr_wd), .a_q(spr_q),
        .b_addr(spr_a2), .b_q(spr_q2)
    );

    // ---------------------------------------------------------------- sprite DMA
    // The real DE-0385-2 latches the sprite list: the game writes spriteram
    // throughout the first quarter of the frame, pokes 0x1D0000, then polls
    // 0x1D0010 for completion (hvysmsh.cpp:178 calls that poll "Check for DMA
    // complete?" and implements none of it, drawing from a frame-end snapshot
    // instead).  Measured with tools/sprwhen.lua over 300 frames of a played
    // match: 570603 spriteram writes, EVERY ONE during active display, all
    // inside the first 25 % of the frame, 281 DMA pokes among them.
    //
    // Reading that list live -- which is what this board did until now --
    // draws the top of the screen from a list the CPU is still rewriting.
    // That is the sprite breakage reported during fast motion, and it is why
    // it survived a cache that fixed everything else: it was never a
    // bandwidth problem.  The whole-board bench never saw it either, because
    // it misses nothing after frame 0 in 820 frames of a simulated match.
    //
    // Copying at the poke rather than at vblank is what the hardware does,
    // and it costs 2048 clocks (20 us, a fifth of a line) once a frame.
    // MAME's frame-end snapshot sees the same bytes: writes after the first
    // 25 % of the frame measured ZERO.
    reg  [10:0] dma_a  = 11'd0;
    reg  [10:0] dma_aq = 11'd0;      // b_q is REGISTERED (docs/HANDOFF.md)
    reg         dma_run = 1'b0, dma_wr = 1'b0;
    reg         dma_pend = 1'b0, vbl_d = 1'b0;
    always @(posedge clk) begin
        dma_wr <= 1'b0;
        dma_aq <= dma_a;
        vbl_d <= vid_vblank;
        if (rst) begin
            dma_run <= 1'b0; dma_a <= 11'd0; dma_pend <= 1'b0;
        end else begin
            // The poke is REMEMBERED and the copy happens at the start of
            // vblank, not at the poke itself.  Copying at the poke leaves
            // 2048 clocks in the middle of active display during which the
            // renderer's source changes under it -- measured at 54 lines of
            // 383,180 over a match, against 201 for reading live.  In
            // vblank nothing is being drawn, so that window is zero.
            //
            // It also matches MAME more closely, not less: MAME draws from
            // a frame-END snapshot (screen_update), which is exactly what a
            // vblank copy captures.
            //
            // EMULATION_DERIVED
            // Matches MAME hvysmsh.cpp screen_update -- required for bring-up.
            // The PCB copies ON the poke; the game polls 0x1D0010 for it, so
            // the transfer is long enough to be worth waiting for, and MAME
            // implements neither.  Deferring to vblank is therefore NOT what
            // the hardware does, and tools/sprwhen.lua bounds the difference:
            // over 300 match frames the pokes land in bins 2-3 of 20 and
            // 2035 further spriteram writes land in bins 4-5, about 7 words
            // per frame of 2048.  A PCB would not show those; this and MAME
            // both do.
            // TODO(HARDWAREIZE): does the DE-0385-2 double-buffer the sprite
            // list, or does its DMA tear like a copy at the poke would?  The
            // poll at 0x1D0010 is the thread to pull -- what it returns while
            // the transfer runs would say how long it takes and whether the
            // renderer reads the old bank meanwhile.
            if (spr_dma_we) dma_pend <= 1'b1;
            if (vid_vblank && !vbl_d && dma_pend) begin
                dma_run  <= 1'b1;  dma_a <= 11'd0;  dma_pend <= 1'b0;
            end else if (dma_run) begin
            dma_wr <= 1'b1;
            dma_a  <= dma_a + 11'd1;
            if (&dma_a) dma_run <= 1'b0;
            end
        end
    end
    assign spr_a2 = dma_a;

    hs_dpram16 #(.AW(11)) u_sprshadow (
        .clk(clk),
        .a_addr(dma_aq), .a_we(dma_wr), .a_wdata(spr_q2), .a_q(),
        .b_addr(spr_sa), .b_q(spr_sq)
    );
    hs_palram u_pal (
        .clk(clk),
        .a_addr(pal_a), .a_we(pal_we), .a_wdata(pal_wd), .a_q(pal_q),
        .b_addr(pal_ra), .b_q(pal_rq)
    );

    // ------------------------------------------------------------------ renderers
    wire        t_rom_cs;
    wire [20:0] t_rom_addr;
    wire [15:0] t_rom_data;
    wire        t_rom_ok;
    wire        t_we;
    wire [8:0]  t_x;
    wire [9:0]  t_d;

    hs_deco141 u_tgen (
        .clk(clk), .rst(cpu_rst),
        .ctl_we(ctl_we), .ctl_wa(ctl_wa), .ctl_wd(ctl_wd),
        .ctl_ra(ctl_ra), .ctl_rd(ctl_rd),
        .vram_a2(vram_a2), .vram_pf2(vram_pf2), .vram_q2(vram_q2),
        .row_a2(row_a2), .row_pf2(row_pf2), .row_q2(row_q2),
        .rom_cs(t_rom_cs), .rom_addr(t_rom_addr), .rom_data(t_rom_data), .rom_ok(t_rom_ok),
        .buf_we(t_we), .buf_x(t_x), .buf_d(t_d), .buf_sel(buf_sel),
        .rd_x(rd_x), .rd_sel(rd_sel), .q_pf1(q_pf1), .q_pf2(q_pf2),
        .line_go(line_go), .line_y(line_y), .line_done(tile_done)
    );

    wire        s_rom_cs;
    wire [21:0] s_rom_addr;
    wire [15:0] s_rom_data;
    wire        s_rom_ok;
    wire        s_we;
    wire [8:0]  s_x;
    wire [9:0]  s_d;

    hs_decospr u_spr (
        .clk(clk), .rst(cpu_rst),
        .spr_a2(spr_sa), .spr_q2(spr_sq),
        .rom_cs(s_rom_cs), .rom_addr(s_rom_addr), .rom_data(s_rom_data), .rom_ok(s_rom_ok),
        .buf_we(s_we), .buf_x(s_x), .buf_d(s_d), .buf_sel(buf_sel),
        .rd_x(rd_x), .rd_sel(rd_sel), .q_spr(q_spr),
        .frame_odd(frame_odd),
        .line_go(line_go), .line_y(line_y), .line_done(spr_done)
    );

    hs_video u_video (
        .clk(clk), .rst(rst), .cen_pix(cen_pix),
        .rd_x(rd_x), .rd_sel(rd_sel),
        .q_pf1(q_pf1), .q_pf2(q_pf2), .q_spr(q_spr),
        .line_go(line_go), .line_y(line_y), .buf_sel(buf_sel),
        .tile_done(tile_done), .spr_done(spr_done),
        .pal_a(pal_ra), .pal_q(pal_rq),
        .red(red), .green(green), .blue(blue),
        .hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank),
        .ce_pix(ce_pix), .frame_odd(frame_odd),
        .irq(vid_vblank)
    );

    // ------------------------------------------------------------------ sound
    wire        o0_cs;
    wire [22:0] o0_addr;
    wire [15:0] o0_data;
    wire        o0_ok;
    wire        o1_cs;
    wire [22:0] o1_addr;
    wire [15:0] o1_data;
    wire        o1_ok;

    hs_snd u_snd (
        .clk(clk), .rst(cpu_rst),
        .cen_oki0(cen_oki0), .cen_oki1(cen_oki1),
        .oki0_we(oki0_we), .oki0_re(oki0_re),
        .oki1_we(oki1_we), .oki1_re(oki1_re),
        .cpu_dout(arm_dout[7:0]),
        .oki0_do(oki0_do), .oki1_do(oki1_do),
        .oki0_bk_we(oki0_bk_we), .oki0_bk(oki0_bk),
        .oki1_bk_we(oki1_bk_we), .oki1_bk(oki1_bk),
        .vol_we(vol_we), .vol_d(vol_d),
        .rom0_cs(o0_cs), .rom0_addr(o0_addr), .rom0_data(o0_data), .rom0_ok(o0_ok),
        .rom1_cs(o1_cs), .rom1_addr(o1_addr), .rom1_data(o1_data), .rom1_ok(o1_ok),
        .snd_l(snd_l), .snd_r(snd_r)
    );

    // ------------------------------------------------------------------ EEPROM
    // 93C46 DO is HIGH-IMPEDANCE while CS is inactive; the board pulls it
    // up, so the CPU reads 1 when the chip is deselected.  jt9346 drives 0
    // out of reset, and the game polls DO before every EEPROM transaction
    // -- with 0 it never proceeds (board symptom: IRQ handler runs, no
    // video writes ever, last trace is 0x120004 toggling CS/CLK).
    // MAME shows the game reading 0xFFFFFFFF here (all inputs released,
    // DO=1) -- tools/eepdump.lua.
    // A BLANK 93C46 reads all ones, and that is the state the game expects to
    // find on a fresh board: MAME fills an absent dump with ~0 (eeprom.cpp:216)
    // and hvysmsh's dump is commented out.  jt9346 only pre-fills its cells
    // under `SIMULATION`, so on the FPGA they come up ZERO -- the golden
    // comparison in sim/tb_amber_boot.sv diverged on exactly this until the
    // reference was regenerated from a blank chip.  Write the 64 words through
    // the dump port once after reset rather than patching the shared module.
    reg  [6:0] eep_init_a = 7'd0;
    wire       eep_init   = ~eep_init_a[6];
    always @(posedge clk) if (eep_init) eep_init_a <= eep_init_a + 7'd1;

    wire eep_sdo_raw;
    jt9346 u_eep (
        .rst(cpu_rst), .clk(clk),
        .sclk(eep_clk), .sdi(eep_di), .sdo(eep_sdo_raw), .scs(eep_cs),
        .dump_clk(clk), .dump_addr(eep_init_a[5:0]), .dump_we(eep_init),
        .dump_din(16'hFFFF), .dump_dout(), .dump_clr(1'b1), .dump_flag()
    );
    assign eep_do = eep_cs ? eep_sdo_raw : 1'b1;
    assign dbg_eep_cs = eep_cs;

    // ---- bring-up liveness: eight cells on the top row of the screen ------
    // 0 ARM PC moving   1 vblank pulses   2 tile line_done   3 spr line_done
    // 4 palette writes  5 spriteram wr    6 ROM fetch ok     7 oki bank wr
    reg [7:0] lv = 8'd0;
    reg [31:0] pc_d = 32'd0;
    reg vb_d = 0, tdone_d = 0, sdone_d = 0;
    always @(posedge clk) begin
        if (cpu_rst) lv <= 8'd0;
        else begin
            pc_d <= dbg_pc;
            if (dbg_pc != pc_d)              lv[0] <= 1'b1;
            vb_d <= vid_vblank;
            if (vid_vblank & ~vb_d)          lv[1] <= 1'b1;
            tdone_d <= tile_done;
            if (tile_done & ~tdone_d)        lv[2] <= 1'b1;
            sdone_d <= spr_done;
            if (spr_done & ~sdone_d)         lv[3] <= 1'b1;
            if (pal_we)                      lv[4] <= 1'b1;
            if (spr_we)                      lv[5] <= 1'b1;
            if (rom_ok)                      lv[6] <= 1'b1;
            if (oki0_bk_we | oki1_bk_we)     lv[7] <= 1'b1;
        end
    end
    assign dbg_liveness = lv;

    // ---- bring-up liveness, second byte: the write/read strobes MAME's
    // healthy boot produces in order (D1: ctl_w=18 by f3, vram_w=3840 by
    // f3, oki0_r=1/frame).  Seeing WHICH of these never fires localises
    // how far the ARM got before dying -- now meaningful, since the ROM
    // probe proved the data path (8/8, probe21).
    // 0 ctl_we  1 vram_we  2 row_we  3 oki0_re  4 oki1_re  5 vol_we
    // 6 eep_cs  7 unused
    reg [7:0] lv2 = 8'd0;
    reg o0re_d = 0, o1re_d = 0;
    always @(posedge clk) begin
        if (cpu_rst) lv2 <= 8'd0;
        else begin
            if (ctl_we)                      lv2[0] <= 1'b1;
            if (vram_we0 | vram_we1)         lv2[1] <= 1'b1;
            if (row_we0 | row_we1)           lv2[2] <= 1'b1;
            o0re_d <= oki0_re;
            if (oki0_re & ~o0re_d)           lv2[3] <= 1'b1;
            o1re_d <= oki1_re;
            if (oki1_re & ~o1re_d)           lv2[4] <= 1'b1;
            if (vol_we)                      lv2[5] <= 1'b1;
            if (eep_cs)                      lv2[6] <= 1'b1;
        end
    end
    assign dbg_liveness2 = lv2;

    // ------------------------------------------------------------------ memory
    hs_romarb u_romarb (
        .clk(clk), .rst(mem_rst),
        .mem_addr(mem_addr), .mem_din(mem_din), .mem_dout(mem_dout),
        .mem_req(mem_req), .mem_we(mem_we), .mem_ds(mem_ds), .mem_ack(mem_ack),
        .dl_active(dl_active), .dl_addr(dl_addr), .dl_data(dl_data),
        .dl_req(dl_req), .dl_ack(dl_ack),
        .cpu_cs(rom_cs),  .cpu_addr(rom_addr),  .cpu_data(rom_data),  .cpu_ok(rom_ok),
        .tile_cs(t_rom_cs), .tile_addr(t_rom_addr), .tile_data(t_rom_data), .tile_ok(t_rom_ok),
        .spr_cs(s_rom_cs),  .spr_addr(s_rom_addr),  .spr_data(s_rom_data),  .spr_ok(s_rom_ok),
        .oki0_cs(o0_cs),    .oki0_addr(o0_addr),    .oki0_data(o0_data),    .oki0_ok(o0_ok),
        .oki1_cs(o1_cs),    .oki1_addr(o1_addr),    .oki1_data(o1_data),    .oki1_ok(o1_ok),
        .dbg_dl_active(dbg_arb_dl), .dbg_sel(dbg_arb_sel),
        .dbg_mem_req(dbg_arb_req), .dbg_mem_ack(dbg_arb_ack)
    );

endmodule

`default_nettype wire
