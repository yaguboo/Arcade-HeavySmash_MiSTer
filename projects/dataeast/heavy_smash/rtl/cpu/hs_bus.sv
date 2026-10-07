//============================================================================
//  Heavy Smash -- ARM bus decode (hvysmsh_map, hvysmsh.cpp:164-179)
//
//  One 32-bit master (the DE156).  Shared video RAMs are dual-port BRAMs
//  instanced in hs_top; this module drives their CPU side (port A): the
//  address is combinational from the captured request, *_we pulses in the
//  second state, read data is sampled in the third.  Little-endian ARM lanes.
//
//  Alignment rules follow MAME's mem_mask behaviour exactly:
//   - 16-bit device areas (vram/rowscroll/spriteram/control) take the LOW
//     halfword of a word or halfword write at offset +0 only; anything at
//     +2 is dropped (mask &= 0x0000ffff makes it a no-op there).
//   - palette takes 32-bit writes only.
//   - byte writes to those areas are dropped (the game writes them as
//     words; revisit if a dump ever shows otherwise).
//============================================================================
`default_nettype none

module hs_bus (
    input  wire        clk,
    input  wire        rst,

    input  wire [31:0] arm_adr,
    input  wire        arm_rnw,
    input  wire        arm_ena,
    input  wire [1:0]  arm_acc,       // 00 byte, 01 half, 10 word
    input  wire [31:0] arm_dout,
    output reg  [31:0] arm_din = 32'h0,
    output reg         arm_done = 1'b0,

    // --- main ROM via SDRAM arbiter -----------------------------------------
    output wire        rom_cs,
    output wire [18:0] rom_addr,      // word address in ROM region
    input  wire [15:0] rom_data,
    input  wire        rom_ok,

    // --- DECO141 control (register file inside hs_deco141) -------------------
    output reg         ctl_we  = 1'b0,
    output wire [2:0]  ctl_wa,
    output wire [15:0] ctl_wd,
    output wire [2:0]  ctl_ra,
    input  wire [15:0] ctl_rd,

    // --- tile VRAM (2 x 4096 x 16), CPU port ---------------------------------
    output wire [11:0] vram_a,
    output wire [15:0] vram_wd,
    output reg         vram_we0 = 1'b0, vram_we1 = 1'b0,
    input  wire [15:0] vram_q0, vram_q1,

    // --- rowscroll (2 x 1024 x 16), CPU port ---------------------------------
    output wire [9:0]  row_a,
    output wire [15:0] row_wd,
    output reg         row_we0 = 1'b0, row_we1 = 1'b0,
    input  wire [15:0] row_q0, row_q1,

    // --- sprite RAM (2048 x 16), CPU port ------------------------------------
    output wire [10:0] spr_a,
    output wire [15:0] spr_wd,
    output reg         spr_we  = 1'b0,
    input  wire [15:0] spr_q,

    // --- palette (1024 x 32), CPU port ---------------------------------------
    output wire [9:0]  pal_a,
    output reg         pal_we  = 1'b0,
    output wire [31:0] pal_wd,        // = req_dat, latched in hs_top's BRAM? no: combinational
    input  wire [31:0] pal_q,

    // --- IO --------------------------------------------------------------------
    input  wire [31:0] inputs,        // active-low pads + vblank(bit20) + eeprom DO(bit24)
    output reg         vol_we  = 1'b0,
    output reg  [7:0]  vol_d   = 8'd0,
    output reg         eep_di  = 1'b0,   // 0x120004 bit 4
    output reg         eep_clk = 1'b0,   // bit 5
    output reg         eep_cs  = 1'b0,   // bit 6
    // Sprite DMA trigger.  The game writes 0x1D0000 once a frame and then
    // polls 0x1D0010 for completion -- hvysmsh.cpp maps the poll as nopr
    // and calls it "Check for DMA complete?", and MAME implements no DMA
    // at all, drawing instead from a frame-end snapshot of spriteram.
    // Measured (tools/sprwhen.lua, 300 frames of a played match): 570603
    // spriteram writes, ALL during active display and all inside the first
    // 25 % of the frame, with the 0x1D0000 write landing in the middle of
    // them.  The real board latches the list; reading it live, as we did,
    // draws the top of the screen from a list still being rewritten.
    output reg         spr_dma_we = 1'b0,
    output reg         oki0_bk_we = 1'b0,
    output reg         oki0_bk    = 1'b0,
    output reg         oki1_bk_we = 1'b0,
    output reg  [2:0]  oki1_bk    = 3'd0,
    // D8 diagnostics: what the CPU actually receives at the death window
    output reg  [31:0] dbg_q74 = 32'd0,
    output reg  [31:0] dbg_q78 = 32'd0,
    output reg  [11:0] dbg_stores = 12'd0,
    output reg  [3:0]  dbg_st_ctl = 4'd0,
    output reg  [3:0]  dbg_st_io120 = 4'd0,
    // D9: sticky "how far did the real CPU get" milestones, one bit each,
    // set from the request the CPU actually issued (S_IDLE, arm_ena): they
    // observe the bus and depend on no gba_cpu internal.  Cleared by rst.
    // ROM READ addresses are NOT used to tell fetch from data (literal
    // loads, restarts, the prefetch after a branch all read ROM).  A first
    // cut with "2nd read @0x00 / @0x04" bits read 1 on the golden replay,
    // which re-enters the reset vector 626 times (see DEBUG_LOG D9).
    // Stores and I/O reads are decisive instead:
    //   0 store @0x1D0000 window     boot stub passed 0x7C
    //   1 store @0x120008            NOT an IRQ-handler marker: the boot stub
    //                                writes it too (0x5C/0x60).  Board D10 set
    //                                this bit while never leaving the stub.
    //   2 ROM read >= 0x1000         the CPU is past the boot stub
    //   3 read  @0x120000            inputs read
    //   4 read  @0x1D0010 window     the "DMA complete?" poll (SOURCE_AUDIT)
    //   5 store to palette window    (any width; pal_we needs a word)
    //   6 store to work RAM
    //   7 read  from work RAM
    output reg  [7:0]  dbg_ev = 8'd0,
    // highest ROM byte address the CPU has read since reset: the checksum
    // sweep is linear, so this is its progress bar (0xFFFFC = sweep done)
    output reg  [19:0] dbg_romhw = 20'd0,
    output reg         oki0_we = 1'b0, oki0_re = 1'b0,
    output reg         oki1_we = 1'b0, oki1_re = 1'b0,
    input  wire [7:0]  oki0_do, oki1_do
);

    localparam S_IDLE = 4'd0, S_ROM_LO = 4'd1, S_ROM_HI = 4'd2,
               S_MEM1 = 4'd3, S_MEM2 = 4'd4, S_IO = 4'd5,
               S_LO_LATCH = 4'd6, S_HI_LATCH = 4'd7, S_DEC = 4'd8;

    reg [3:0]  st      = S_IDLE;
    reg        req_rnw = 1'b0;
    reg [1:0]  req_acc = 2'd0;
    reg [21:0] req_adr = 22'd0;
    reg [31:0] req_dat = 32'd0;
    reg [15:0] rom_lo  = 16'd0;
    reg [31:0] rom_dec_r = 32'd0;   // pipelined DE156 result (timing)

    // ------------------------------------------------------------------ decode
    wire sel_rom  = (req_adr < 22'h100000);
    wire sel_ram  = (req_adr >= 22'h100000) & (req_adr < 22'h108000);
    wire sel_inp  = (req_adr & 22'h1FFFFC) == 22'h120000;
    wire sel_ee   = (req_adr & 22'h1FFFFC) == 22'h120004;
    wire sel_obk  = (req_adr & 22'h1FFFFC) == 22'h12000C;
    wire sel_oki0 = (req_adr & 22'h1FFF00) == 22'h140000;
    wire sel_oki1 = (req_adr & 22'h1FFF00) == 22'h160000;
    wire sel_ctl  = (req_adr & 22'h1FFFE0) == 22'h180000;
    wire sel_vr0  = (req_adr & 22'h1FC000) == 22'h190000;
    wire sel_vr1  = (req_adr & 22'h1FC000) == 22'h194000;
    wire sel_rw0  = (req_adr & 22'h1FC000) == 22'h1A0000;
    wire sel_rw1  = (req_adr & 22'h1FC000) == 22'h1A4000;
    wire sel_pal  = (req_adr & 22'h1FF000) == 22'h1C0000;
    wire sel_dma  = (req_adr & 22'h1FFF00) == 22'h1D0000;
    wire sel_spr  = (req_adr & 22'h1FE000) == 22'h1E0000;
    wire sel_mem  = sel_ram | sel_vr0 | sel_vr1 | sel_rw0 | sel_rw1
                  | sel_pal | sel_spr | sel_ctl | sel_dma;

    // same decode against the raw incoming address, for the S_IDLE decision
    wire [21:0] aa = arm_adr[21:0];
    wire arm_sel_ram = (aa >= 22'h100000) & (aa < 22'h108000);
    wire arm_sel_mem = ((aa >= 22'h100000) & (aa < 22'h108000)) |
                       ((aa & 22'h1FC000) == 22'h190000) |
                       ((aa & 22'h1FC000) == 22'h194000) |
                       ((aa & 22'h1FC000) == 22'h1A0000) |
                       ((aa & 22'h1FC000) == 22'h1A4000) |
                       ((aa & 22'h1FF000) == 22'h1C0000) |
                       ((aa & 22'h1FE000) == 22'h1E0000) |
                       ((aa & 22'h1FFFE0) == 22'h180000) |
                       ((aa & 22'h1FFF00) == 22'h1D0000);

    // ---- DE156 live decode ----------------------------------------------------
    wire [17:0] d_idx = req_adr[19:2];
    wire [17:0] phys;
    hs_de156_addr u_d156a (.a(d_idx), .p(phys));
    wire [31:0] rom_dec;
    // SDRAM words are stored {even byte, odd byte} big-endian (the download
    // convention), but the ARM dword is little-endian: [15:8]=b1, [7:0]=b0.
    // Swap both words so the DE156 module sees the dword in memory order.
    wire [15:0] rom_hi_le = {rom_data[7:0], rom_data[15:8]};
    wire [15:0] rom_lo_le = {rom_lo[7:0], rom_lo[15:8]};
    wire [31:0] rom_raw = {rom_hi_le, rom_lo_le};
    hs_de156_data u_d156d (.a(d_idx), .raw(rom_raw), .dec(rom_dec));

    assign rom_cs   = (st == S_ROM_LO) | (st == S_ROM_HI);
    assign rom_addr = (st == S_ROM_HI) ? {phys, 1'b1} : {phys, 1'b0};

    // ---- little-endian sub-word lane ------------------------------------------
    function automatic [31:0] lane32(input [31:0] w, input [1:0] adr, input [1:0] acc);
        lane32 = (acc == 2'b00) ? {24'd0, w[8*adr +: 8]}  :
                 (acc == 2'b01) ? {16'd0, w[16*adr[1] +: 16]} : w;
    endfunction

    // ---- work RAM (8192 x 32), CPU private ------------------------------------
    // Whole-word writes with a read-merge for the byte lanes: the manual
    // per-field byte-enable assignments did not infer M10K (262k registers,
    // first-fit blocker) and neither did a combinational read.  The address
    // is stable from S_IDLE, so wram_q already holds the word being written
    // when S_MEM1 fires -- the merge is exact.
    reg  [31:0] wram [0:8191] /* synthesis ramstyle = "no_rw_check" */;
    reg         wram_we = 1'b0;
    reg  [31:0] wram_wd = 32'd0;
    wire [12:0] wram_aa = req_adr[14:2];
    reg  [31:0] wram_q = 32'd0;
    wire [3:0]  be_now  = (req_acc == 2'b00) ? (4'b0001 << req_adr[1:0]) :
                          (req_acc == 2'b01) ? (req_adr[1] ? 4'b1100 : 4'b0011) :
                                               4'b1111;
    wire [31:0] wram_wm = {
        be_now[3] ? wram_wd[31:24] : wram_q[31:24],
        be_now[2] ? wram_wd[23:16] : wram_q[23:16],
        be_now[1] ? wram_wd[15: 8] : wram_q[15: 8],
        be_now[0] ? wram_wd[ 7: 0] : wram_q[ 7: 0] };
    always @(posedge clk) begin
        wram_q <= wram[wram_aa];
        if (wram_we) wram[wram_aa] <= wram_wm;
    end

    // ---- shared-BRAM write data (combinational) --------------------------------
    assign vram_wd = req_dat[15:0];
    assign row_wd  = req_dat[15:0];
    assign spr_wd  = req_dat[15:0];
    assign ctl_wd  = req_dat[15:0];

    // ---- CPU-side addresses for the shared BRAMs (combinational) ---------------
    // Sizes are MAME's map, each window holding ONE 16-bit value per 32-bit
    // slot (hvysmsh.cpp:155-162, :178):
    //   PF vram    +0x10000-0x11FFF  = 0x2000 bytes -> 0x800 words -> [12:2]
    //   rowscroll  +0x20000-0x20FFF  = 0x1000 bytes -> 0x400 words -> [11:2]
    //   spriteram  0x1E0000-0x1E1FFF = 0x2000 bytes -> 0x800 words -> [12:2]
    //     (m_spriteram is 0x1000 BYTES of u16 and draw_sprites is told 0x800)
    // All three were two bits short here, so the CPU could only reach a
    // quarter (vram, rowscroll) or a quarter (spriteram) of each RAM and the
    // rest aliased.  The renderers always used the full width -- decospr
    // starts its walk at 0x7FC, the tilegen's index reaches 2047 -- so this
    // was the CPU side alone.  Verilator's width warnings pointed at it; no
    // build had ever exercised these RAMs because the CPU never got this far
    // (DEBUG_LOG D12).
    assign vram_a = {1'b0, req_adr[12:2]};
    assign row_a  = req_adr[11:2];
    assign spr_a  = req_adr[12:2];
    assign pal_a  = req_adr[11:2];
    assign pal_wd = req_dat;
    // ctl_wa was declared `output reg` and NEVER ASSIGNED: every tilegen
    // control write landed in slot 0, so the scroll registers, the layer
    // modes and the bank word were all one value in the wrong place.  MAME at
    // the title screen has {_,_,_,_,_,8080,0080,0001}; we had {0080,0,...}.
    // Same fault as hs_video's rd_x, found the same way -- by diffing our
    // tilegen state against MAME's (sim/tb_frame.sv write_vram vs
    // tools/vramdump.lua).  The VRAM and palette contents matched exactly.
    assign ctl_wa = req_adr[4:2];
    assign ctl_ra = req_adr[4:2];

    // ---- read muxes -------------------------------------------------------------
    wire [31:0] vid_q = sel_vr0 ? {16'hffff, vram_q0} :
                        sel_vr1 ? {16'hffff, vram_q1} :
                        sel_rw0 ? {16'hffff, row_q0}  :
                        sel_rw1 ? {16'hffff, row_q1}  :
                        sel_spr ? {16'hffff, spr_q}   :
                        sel_pal ? pal_q               :
                        sel_ctl ? {16'hffff, ctl_rd}  : 32'h0;

    wire [31:0] io_q = sel_inp ? inputs          :
                       sel_oki0 ? {24'd0, oki0_do} :
                       sel_oki1 ? {24'd0, oki1_do} : 32'h0;

    // 16-bit areas: a write only lands when it covers the low halfword
    wire lo_half_ok = (req_acc == 2'b10) ||
                      ((req_acc == 2'b01) && !req_adr[1]) ||
                      ((req_acc == 2'b00) && (req_adr[1:0] == 2'b00));

    // ---------------------------------------------------------------- FSM
    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; arm_done <= 1'b0;
            ctl_we <= 1'b0; vram_we0 <= 1'b0; vram_we1 <= 1'b0;
            row_we0 <= 1'b0; row_we1 <= 1'b0; spr_we <= 1'b0; pal_we <= 1'b0;
            vol_we <= 1'b0; oki0_bk_we <= 1'b0; oki1_bk_we <= 1'b0;
            spr_dma_we <= 1'b0;
            oki0_we <= 1'b0; oki0_re <= 1'b0; oki1_we <= 1'b0; oki1_re <= 1'b0;
            wram_we <= 1'b0;
            eep_di <= 1'b0; eep_clk <= 1'b0; eep_cs <= 1'b0;
            dbg_ev <= 8'd0; dbg_romhw <= 20'd0;
        end else begin
            arm_done  <= 1'b0;
            ctl_we    <= 1'b0; vram_we0 <= 1'b0; vram_we1 <= 1'b0;
            row_we0   <= 1'b0; row_we1 <= 1'b0; spr_we <= 1'b0; pal_we <= 1'b0;
            vol_we    <= 1'b0; oki0_bk_we <= 1'b0; oki1_bk_we <= 1'b0;
            spr_dma_we <= 1'b0;
            oki0_we   <= 1'b0; oki0_re <= 1'b0; oki1_we <= 1'b0; oki1_re <= 1'b0;
            wram_we   <= 1'b0;

            case (st)
            S_IDLE: if (arm_ena) begin
                if (!arm_rnw) begin
                    if (!dbg_stores[11]) dbg_stores <= dbg_stores + 12'd1;
                    if (arm_adr[21:0] >= 22'h180000 && arm_adr[21:0] < 22'h190000
                        && !dbg_st_ctl[3])  dbg_st_ctl  <= dbg_st_ctl + 4'd1;
                    if (arm_adr[21:0] == 22'h120000 && !dbg_st_io120[3])
                        dbg_st_io120 <= dbg_st_io120 + 4'd1;
                end
                if (arm_rnw) begin
                    if (aa < 22'h100000 && aa[19:0] > dbg_romhw) dbg_romhw <= aa[19:0];
                    if (aa >= 22'h001000 && aa < 22'h100000)  dbg_ev[2] <= 1'b1;
                    if ((aa & 22'h1FFFFC) == 22'h120000)      dbg_ev[3] <= 1'b1;
                    if ((aa & 22'h1FFF00) == 22'h1D0000)      dbg_ev[4] <= 1'b1;
                    if (arm_sel_ram)                          dbg_ev[7] <= 1'b1;
                end else begin
                    if ((aa & 22'h1FFF00) == 22'h1D0000)      dbg_ev[0] <= 1'b1;
                    if ((aa & 22'h1FFFFC) == 22'h120008)      dbg_ev[1] <= 1'b1;
                    if ((aa & 22'h1FF000) == 22'h1C0000)      dbg_ev[5] <= 1'b1;
                    if (arm_sel_ram)                          dbg_ev[6] <= 1'b1;
                end
                req_rnw <= arm_rnw;
                req_acc <= arm_acc;
                req_adr <= arm_adr[21:0];
                req_dat <= arm_dout;
                // The sprite DMA poke is caught HERE and not in S_IO,
                // because 0x1D0000 is listed in arm_sel_mem above and so
                // routes to S_MEM1 -- a strobe in S_IO never fires.
                // Measured: 0 triggers in 124 frames before this moved.
                if (!arm_rnw && (arm_adr[21:0] & 22'h1FFF00) == 22'h1D0000)
                    spr_dma_we <= 1'b1;
                if (arm_adr[21:0] < 22'h100000) st <= S_ROM_LO;
                else if (arm_sel_mem)            st <= S_MEM1;
                else                             st <= S_IO;
            end

            // romarb registers its data with the ok pulse (NBA), so the word
            // is only visible ONE CLK AFTER ok -- latch states catch it.
            S_ROM_LO: if (rom_ok) st <= S_LO_LATCH;
            S_LO_LATCH: begin
                rom_lo <= rom_data;
                st     <= S_ROM_HI;
            end
            S_ROM_HI: if (rom_ok) st <= S_HI_LATCH;
            // the xor-chain + 32-bit permutation + lane mux was the deep
            // cone in the 100 MHz domain; register the decoded dword and
            // pick the lane in the next clock
            S_HI_LATCH: begin
                rom_dec_r <= rom_dec;
                st        <= S_DEC;
            end
            S_DEC: begin
                arm_din  <= lane32(rom_dec_r, req_adr[1:0], req_acc);
                arm_done <= 1'b1;
                if (req_rnw && req_adr[21:0] == 22'h000074) dbg_q74 <= rom_dec_r;
                if (req_rnw && req_adr[21:0] == 22'h000078) dbg_q78 <= rom_dec_r;
                st       <= S_IDLE;
            end

            S_MEM1: begin
                if (!req_rnw) begin
                    if (sel_ram) begin
                        wram_we <= 1'b1; wram_wd <= req_dat;
                    end else if (lo_half_ok) begin
                        if (sel_vr0)      vram_we0 <= 1'b1;
                        else if (sel_vr1) vram_we1 <= 1'b1;
                        else if (sel_rw0) row_we0  <= 1'b1;
                        else if (sel_rw1) row_we1  <= 1'b1;
                        else if (sel_spr) spr_we   <= 1'b1;
                        else if (sel_ctl) ctl_we   <= 1'b1;
                        // pal was chained as the ELSE of lo_half_ok, where
                        // the word-access requirement (acc==2'b10) makes
                        // lo_half_ok always true -- pal_we could never
                        // fire.  Found by replaying the golden boot into
                        // the real bus (sim/tb_replay.sv, D6).
                        else if (sel_pal && req_acc == 2'b10) pal_we <= 1'b1;
                    end
                end
                st <= S_MEM2;
            end
            S_MEM2: begin
                arm_din  <= sel_ram ? lane32(wram_q, req_adr[1:0], req_acc)
                                    : vid_q;
                arm_done <= 1'b1;
                st       <= S_IDLE;
            end

            S_IO: begin
                arm_din  <= io_q;
                arm_done <= 1'b1;
                if (req_rnw) begin
                    if (sel_oki0) oki0_re <= 1'b1;
                    if (sel_oki1) oki1_re <= 1'b1;
                end else begin
                    if (sel_inp) begin
                        vol_we <= 1'b1; vol_d <= req_dat[7:0];
                    end else if (sel_ee) begin
                        eep_di  <= req_dat[4];
                        eep_clk <= req_dat[5];
                        eep_cs  <= req_dat[6];
                        oki1_bk_we <= 1'b1; oki1_bk <= req_dat[2:0];
                    end else if (sel_obk) begin
                        oki0_bk_we <= 1'b1; oki0_bk <= req_dat[0];
                    end else begin
                        if (sel_oki0) oki0_we <= 1'b1;
                        if (sel_oki1) oki1_we <= 1'b1;
                    end
                end
                st <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase
        end
    end

    // 16-bit area write data is the low halfword of the request

endmodule

`default_nettype wire
