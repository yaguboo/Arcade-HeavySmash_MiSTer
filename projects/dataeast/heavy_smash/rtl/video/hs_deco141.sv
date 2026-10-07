//============================================================================
//  Heavy Smash -- DECO141 dual playfield tile generator (deco16ic device).
//
//  hvysmsh config (hvysmsh.cpp:360-372): both layers 64x32, colour banks
//  0x00 (PF1 fg) / 0x10 (PF2 bg), colour mask 0xf, tile bank =
//  (bankval & 0x70) << 8, 8x8 and 16x16 gfx share the ROM.
//
//  Per line, per playfield, following deco16ic.cpp custom_tilemap_draw
//  (:321-432), which covers plain / row-scroll / simultaneous row+col:
//     src_y = (ly + scrolly) & hmask
//     xbase = scrollx + rowscroll[src_y / row_type]
//     per tile col: src_x = (xbase + col*tw) & wmask
//                  yy = (src_y + colscroll[0x200 + (src_x&0x1ff)/col_type]) & hmask
//
//  Tile word: code = w & 0xfff | bank; colour = w >> 12; bit 15 with ctl1[0]/[1]
//  gives x/y flip and cuts colour to 3 bits (deco16ic.cpp:279-308).
//
//  ROM word addresses within the tile region (SOURCE_AUDIT "Gfx byte format"):
//     16x16:  code*0x20 + stripe*0x10 + y_in + half*0x80000   (4 words/row)
//      8x8 :  code*0x08 + y_in + half*0x80000                 (2 words/row)
//  Each word goes through the DECO56 live decode; the logical word is then
//  quarter-swapped (byte addr bits 19/20) to the physical SDRAM address.
//
//  One line is prefetched into a double-buffered 320x10 index RAM while the
//  previous line scans out; hs_video owns the ping-pong selection.
//============================================================================
`default_nettype none

module hs_deco141 (
    input  wire        clk,
    input  wire        rst,

    // --- CPU side control file (hs_bus) ---------------------------------------
    input  wire        ctl_we,
    input  wire [2:0]  ctl_wa,
    input  wire [15:0] ctl_wd,
    input  wire [2:0]  ctl_ra,
    output wire [15:0] ctl_rd,

    // --- shared VRAM port B (render) -------------------------------------------
    output reg  [11:0] vram_a2 = 12'd0,
    output reg         vram_pf2 = 1'b0,
    input  wire [15:0] vram_q2,

    // --- shared rowscroll port B -------------------------------------------------
    output reg  [9:0]  row_a2 = 10'd0,
    output reg         row_pf2 = 1'b0,
    input  wire [15:0] row_q2,

    // --- tile ROM fetch (romarb client) -------------------------------------------
    output wire        rom_cs,
    output wire [20:0] rom_addr,
    input  wire [15:0] rom_data,
    input  wire        rom_ok,

    // --- line buffer (double buffered, per-PF, own RAM) ----------------------------
    output reg         buf_we  = 1'b0,
    output reg  [8:0]  buf_x   = 9'd0,
    output reg  [9:0]  buf_d   = 10'd0,
    input  wire        buf_sel,
    input  wire [8:0]  rd_x,
    input  wire        rd_sel,
    output wire [9:0]  q_pf1, q_pf2,

    // --- handshake -------------------------------------------------------------------
    input  wire        line_go,
    input  wire [8:0]  line_y,
    output reg         line_done = 1'b0
);

    // ------------------------------------------------------------ control file
    reg [15:0] ctrl [0:7] = '{default: 16'd0};
    always @(posedge clk) if (ctl_we) ctrl[ctl_wa] <= ctl_wd;
    assign ctl_rd = ctrl[ctl_ra];

    reg cur_pf = 1'b0;                       // 0 = PF1 (fg), 1 = PF2 (bg)

    // The per-layer control fields are LATCHED once, when the layer is
    // selected, and not muxed out of ctrl[] on the fly.  D16's fit missed
    // setup by 1.898 ns on 200 paths of one shape --
    //   hs_deco141|ctrl[*] -> hs_deco141|buf_d[*]
    // -- which is this control file feeding the pixel assembly
    // combinationally (ctrl -> ctl1/bankval -> colour_eff/pen -> buf_d) on a
    // path that is NOT cen-gated, because buf_d is written on every blit
    // clock.  A seed re-roll does not move a 1.9 ns miss on 200 paths of one
    // shape.  These cannot change inside a line anyway: MAME's control_w
    // calls update_partial, and a tap over the whole attract shows every
    // control write landing in the first 10% of a frame.
    reg [7:0]  ctl0 = 8'd0, ctl1 = 8'd0, bankval = 8'd0;
    reg [15:0] scx = 16'd0, scy = 16'd0;

    wire        mode8  = ctl1[7];
    wire        row_en = ctl1[6];
    wire        col_en = ctl1[5];
    wire [9:0]  wmask  = mode8 ? 10'd511 : 10'd1023;
    wire [8:0]  hmask  = mode8 ?  9'd255 :  9'd511;
    wire        pf_en  = ctl0[7];
    wire [3:0]  rowsel = ctl0[6:3];
    wire [2:0]  colsel = ctl0[2:0];
    wire [9:0]  row_type = 10'd1 << rowsel;
    wire [3:0]  col_shift = 3 + colsel;       // col_type = 8 << colsel

    // hvysmsh.cpp bank_callback: (bank & 0x70) << 8, i.e. bankval[6:4] << 12.
    // This was bankval[6:4] << 8 -- sixteen times too small, so every tile the
    // game banked came from the wrong 4096-tile page.  Invisible until the
    // attract reaches a screen that banks: frame 1800 (control 7 = 0x1101)
    // matched 8.74% of MAME's picture with it and 100% without.
    wire [14:0] bank_off = {bankval[6:4], 12'd0};
    wire [4:0]  colbank  = cur_pf ? 5'h10 : 5'h00;
    wire [5:0]  tw       = mode8 ? 6'd8 : 6'd16;         // tile width

    // ------------------------------------------------------------ FSM
    localparam S_IDLE=0, S_ROWIDX=1, S_ROWGET=2, S_COLIDX=3, S_COLGET=4,
               S_VRAM=5, S_TCALC=6,
               S_F0=7, S_D0=8, S_F1=9, S_D1=10, S_F2=11, S_D2=12,
               S_F3=13, S_D3=14, S_BLIT=15, S_NEXTPF=16, S_DONE=17,
               S_D0L=18, S_D1L=19, S_D2L=20, S_D3L=21,
               S_ROWW=22, S_COLW=23, S_VRAMW=24,
               S_D0B=25, S_D1B=26, S_D2B=27, S_D3B=28;

    // hs_deco56 is TWO registers deep, not one.  `run` latches xr/pat at the
    // clock after the fetch state, and `dec` is registered from
    // bswap(xor(raw, xr), pat) -- so the first dec written after run still
    // carries the PREVIOUS fetch's mask and pattern, and dec only becomes
    // correct one clock later.  S_D*B is that clock.  Latching without it
    // decoded each word with its predecessor's key: the right raw bits, the
    // wrong permutation, which draws a picture that is nearly right in the
    // flat areas (consecutive words often share a key) and hash everywhere
    // the detail is.

    // hs_dpram16's B port is a REGISTERED read (hs_dpram.sv:23) -- q is the
    // word for the address that was standing at the previous edge.  The FSM
    // set the address in one state and read the data in the next, which is
    // one clock too early: every tile word, rowscroll word and colscroll word
    // was the one fetched for the PREVIOUS lookup.  S_ROWW / S_COLW / S_VRAMW
    // are that missing clock.  (The DECO56 path already had its wait state --
    // S_D0..S_D3L -- so the contract was understood there and missed here.)

    // hs_deco56 registers xr/pat on the run clock and its dec output is only
    // valid the clock AFTER that -- so every fetch needs one wait state
    // before its result can be latched (tb_deco56 pins the module timing;
    // this is the caller-side half of the same contract).

    reg [4:0]  st = S_IDLE;
    reg [8:0]  ly;
    reg [8:0]  src_y;
    reg [17:0] xbase;
    reg [5:0]  tcol;
    reg [9:0]  src_x, yy;
    reg [15:0] tile;
    reg [3:0]  y_in;
    reg        f_half, f_stripe;
    reg [15:0] w_h0s0, w_h0s1, w_h1s0, w_h1s1;
    reg        d56_run;
    reg [15:0] raw_r;
    reg [4:0]  blit_i;
    reg [17:0] row_off;
    reg        got_col;                       // colscroll value valid this column

    // ---- logical ROM word for the fetch in flight -----------------------------
    // MAME's gfx_element does `code %= elements()`: the 16x16 decode has
    // RGN_FRAC(1,2)/64 = 16384 elements and the 8x8 one 65536, so the 16x16
    // path keeps 14 bits of code and the 8x8 path all 15.  Either way the
    // word address stays inside its own 0x80000-word plane half.
    wire [14:0] code = {3'd0, tile[11:0]} | bank_off;
    wire [20:0] log_word = (mode8
        ? ({3'd0, code, 3'd0} + {17'd0, y_in})
        : ({2'd0, code[13:0], 5'd0} + {16'd0, f_stripe, 4'd0} + {17'd0, y_in}))
        + (f_half ? 21'h080000 : 21'd0);

    // ---- DECO56 permutation within the 2 KB block ------------------------------
    wire [10:0] phys_l;
    hs_deco56_addr u_perm (.clk(clk), .i(log_word[10:0]), .p(phys_l));
    reg [10:0] i_r, phys_r;
    wire [15:0] d56_dec;
    hs_deco56 u_d56 (.clk(clk), .i(i_r), .phys_l(phys_r),
                     .run(d56_run), .raw(raw_r), .dec(d56_dec));

    wire [20:0] qw      = {log_word[20:11], phys_l};
    wire [20:0] qw_swap = (qw & 21'h03FFFF)
                        | ((qw & 21'h040000) ? 21'h080000 : 21'h0)
                        | ((qw & 21'h080000) ? 21'h040000 : 21'h0);
    localparam [20:0] TILE_BASE = 21'h080000;

    // phys_l is a REGISTERED table lookup, so for one clock after log_word
    // changes rom_addr still carries the previous fetch's permuted low bits.
    // Between stripe 0 and stripe 1 only those low bits change (code*0x20+y
    // vs +0x10: bits [20:11] are identical), so for that one clock the
    // address is bit-for-bit the address the arbiter has JUST completed --
    // and tile_ok, which is a LEVEL qualified by "address still matches",
    // is still high.  The renderer accepted it and latched the stripe-0 word
    // as the stripe-1 word.  Measured, not inferred: sim/.v/render_fetch.txt
    //   stripe=0 addr=0886d5 raw=6a1c
    //   stripe=1 addr=0880ab raw=6a1c   <- different address, same word
    // The half-0/half-1 pair did not have it (half is bit 19 of log_word,
    // which is combinational), which is why only half the pixels were wrong.
    reg [20:0] lw_r = 21'd0;
    always @(posedge clk) lw_r <= log_word;
    wire addr_ready = (lw_r == log_word);

    assign rom_cs   = ((st == S_F0) | (st == S_F1) | (st == S_F2) | (st == S_F3))
                      & addr_ready;
    assign rom_addr = TILE_BASE + qw_swap;

    always @(posedge clk) if (rom_cs) begin
        i_r    <= log_word[10:0];
        phys_r <= phys_l;
    end

    // ---- pixel nibble -------------------------------------------------------------
    // Derived from MAME's gfx_layout, not from prose (hvysmsh.cpp:285-304):
    //
    //   tilelayout  planeoffset { RGN_FRAC(1,2)+8, RGN_FRAC(1,2), 8, 0 }
    //               xoffset     { STEP8(8*2*16,1), STEP8(0,1) }
    //               yoffset     { STEP16(0,8*2) }   charincrement 64*8
    //
    // decodegfx builds the pen with planeoffset[0] as the MSB and reads bit
    // n as `byte[n/8] >> (7 - n%8)`.  In our word (loader packs {even,odd} as
    // {[15:8],[7:0]}) that makes, for xin8 = x within the byte:
    //
    //   pen[0] = ws0[15-xin8]   pen[1] = ws0[7-xin8]
    //   pen[2] = ws1[15-xin8]   pen[3] = ws1[7-xin8]
    //
    // Three things were wrong here and each one alone scrambles the picture:
    //   * the bit index ran x, not 7-x -- every tile mirrored inside itself;
    //   * the two planes of a pair were taken from the wrong halves of the
    //     word, so pen bits 0/1 and 2/3 were swapped;
    //   * xoffset puts x=8..15 in the FIRST 32 bytes and x=0..7 in the
    //     second, so the stripe select is inverted from what it was.
    // And in 8x8 mode there is only one stripe: xeff[3] is always 0 there,
    // which selected w_*s1 -- words the 8x8 fetch path never writes, left
    // over from the previous 16x16 tile.  That is the speckle the 8x8 layer
    // drew at the title screen out of an all-zero VRAM.
    reg tflx_now, tfly_now;
    wire [5:0] xin_raw = tw - 6'd1 - {1'b0, blit_i};
    wire [3:0] xeff = tflx_now ? xin_raw[3:0] : blit_i[3:0];
    wire [2:0] bx   = ~xeff[2:0];                  // 7 - x within the byte
    wire [15:0] ws0 = (mode8 | xeff[3]) ? w_h0s0 : w_h0s1;
    wire [15:0] ws1 = (mode8 | xeff[3]) ? w_h1s0 : w_h1s1;
    wire [3:0] pen = {ws1[{1'b0, bx}], ws1[{1'b1, bx}],
                      ws0[{1'b0, bx}], ws0[{1'b1, bx}]};

    wire [4:0] colour_eff = (tile[15] & (ctl1[0] | ctl1[1])) ? {1'b0, tile[14:12]} : tile[15:12];

    // ---- line buffers: {pf, half, x} -> 10-bit index -------------------------------
    // 2048, not 1280.  The address is {pf, sel, x} with a NINE-bit x, so the
    // strides are 512 and 1024 -- sized for 2*2*320 it stopped at 1279 and
    // everything from 1280 up (PF2's half-1 buffer entirely, PF2's half-0
    // partly) fell outside the array: writes vanished, reads came back blank.
    // On screen: every other visible line black in the tilemap (sim and
    // board, D13-D15).
    reg [9:0] lbuf [0:2047];
    wire [10:0] bwa = {cur_pf, buf_sel, buf_x};
    always @(posedge clk) if (buf_we) lbuf[bwa] <= buf_d;
    reg [9:0] q1r, q2r;
    always @(posedge clk) begin
        q1r <= lbuf[{1'b0, rd_sel, rd_x}];
        q2r <= lbuf[{1'b1, rd_sel, rd_x}];
    end
    assign q_pf1 = q1r;
    assign q_pf2 = q2r;

    // The tile the column fetched is the one CONTAINING src_x, so the pixel
    // lands at tcol*tw minus however far into that tile xbase started.  In
    // 8x8 mode that is xbase[2:0], not xbase[3:0]: with the wider mask a
    // scrolled 8x8 layer slid by up to 8 pixels.
    wire [3:0] xalign = mode8 ? {1'b0, xbase[2:0]} : xbase[3:0];

    // col_x is tcol*tw kept incrementally, and px_r walks it a pixel at a
    // time, because that multiply was the fit's critical path.  The
    // standalone STA named it exactly:
    //     hs_deco141|ctl1[7]  ->  hs_deco141|buf_x[*]     slack -0.449
    // ctl1[7] is mode8, mode8 picks tw, tw was an operand of `tcol * tw`,
    // and buf_x is written on a blit clock that is not cen-gated.
    // Registering the control file (which closed D16's -1.898 ns family)
    // left this one standing because the multiply is DOWNSTREAM of that
    // register, not upstream of it.
    reg [9:0]  col_x = 10'd0;
    reg signed [10:0] px_r = 11'sd0;
    wire px_on = (px_r >= 11'sd0) && (px_r < 11'sd320);
    wire [8:0] pxs = px_r[8:0];

    // yy is only written by S_COLGET, so with column scroll off it still held
    // the PREVIOUS line's value while vidx was being formed -- the first tile
    // column of every line indexed the wrong row.  Take src_y directly in that
    // case instead of writing yy a state too late.
    wire [9:0] yy_eff = got_col ? yy : {1'b0, src_y};

    // ---- VRAM index ----------------------------------------------------------
    // The two tilemaps of a playfield are created with DIFFERENT mappers
    // (deco16ic.cpp:229-233): the 16x16 one with deco16ic_device::scan_rows
    // (:273-277) and the 8x8 one with plain TILEMAP_SCAN_ROWS.  Using the
    // 16x16 mapper for both scrambled the 8x8 layer's rows; it only showed up
    // once the attract put text on it.
    wire [10:0] t_c = mode8 ? (src_x  >> 3) : (src_x  >> 4);
    wire [10:0] t_r = mode8 ? (yy_eff >> 3) : (yy_eff >> 4);
    wire [11:0] vidx = mode8
                     ? {1'b0, t_r[4:0], t_c[5:0]}
                     : (t_c[4:0]
                        + {t_r[4:0], 5'b0}
                        + {t_c[5], 10'b0}
                        + {t_r[5], 11'b0});

    // ------------------------------------------------------------ FSM proper
    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; line_done <= 1'b0; buf_we <= 1'b0;
            d56_run <= 1'b0;
        end else begin
            line_done <= 1'b0;
            buf_we    <= 1'b0;
            d56_run   <= 1'b0;

            case (st)
            S_IDLE: if (line_go) begin
                ly      <= line_y;
                cur_pf  <= 1'b0;
                tcol    <= 6'd0;
                ctl0    <= ctrl[5][7:0];
                ctl1    <= ctrl[6][7:0];
                scx     <= ctrl[1];
                scy     <= ctrl[2];
                bankval <= ctrl[7][7:0];
                st      <= S_ROWIDX;
            end

            S_ROWIDX: begin
                src_y <= (ly + scy[8:0]) & hmask;
                col_x <= 10'd0;
                // row_pf2 selects which rowscroll RAM the read mux returns.
                // It used to be set in S_VRAM -- AFTER both rowscroll reads --
                // so the first read of every line still carried the previous
                // playfield's selection.
                row_pf2 <= cur_pf;
                if (row_en && pf_en) begin
                    row_a2 <= ((ly + scy[8:0]) & hmask) >> rowsel;
                    st <= S_ROWW;
                end else begin
                    row_off <= 18'd0;
                    st <= S_COLIDX;
                end
            end
            S_ROWW: st <= S_ROWGET;
            S_ROWGET: begin
                row_off <= {2'd0, row_q2};
                st <= S_COLIDX;
            end

            S_COLIDX: begin
                if (tcol == 5'd0) xbase <= {2'd0, scx} + row_off;
                src_x <= ({2'd0, scx} + row_off + {8'd0, col_x}) & {6'd0, wmask};
                if (col_en && pf_en) begin
                    row_a2 <= 10'h200
                            + ((({2'd0, scx} + row_off + {8'd0, col_x}) & 10'h1FF)
                               >> col_shift);
                    got_col <= 1'b1;
                    st <= S_COLW;
                end else begin
                    got_col <= 1'b0;
                    st <= S_VRAM;
                end
            end
            S_COLW: st <= S_COLGET;
            S_COLGET: begin
                yy <= (src_y + row_q2) & hmask;
                st <= S_VRAM;
            end

            S_VRAM: begin
                vram_a2  <= vidx;
                vram_pf2 <= cur_pf;
                st <= S_VRAMW;
            end
            S_VRAMW: st <= S_TCALC;
            S_TCALC: begin
                tile   <= vram_q2;
                f_half <= 1'b0; f_stripe <= 1'b0;
                st <= S_F0;
            end

            // ---- fetch/decode: 16x16 takes 4 words, 8x8 takes 2
            S_F0: if (rom_ok && addr_ready) begin raw_r <= rom_data; d56_run <= 1'b1; st <= S_D0; end
            S_D0: st <= S_D0B;
            S_D0B: st <= S_D0L;
            S_D0L: begin
                w_h0s0 <= d56_dec;
                if (mode8) begin f_half <= 1'b1; st <= S_F2; end
                else begin f_stripe <= 1'b1; st <= S_F1; end
            end
            S_F1: if (rom_ok && addr_ready) begin raw_r <= rom_data; d56_run <= 1'b1; st <= S_D1; end
            S_D1: st <= S_D1B;
            S_D1B: st <= S_D1L;
            S_D1L: begin w_h0s1 <= d56_dec; f_stripe <= 1'b0; f_half <= 1'b1; st <= S_F2; end
            S_F2: if (rom_ok && addr_ready) begin raw_r <= rom_data; d56_run <= 1'b1; st <= S_D2; end
            S_D2: st <= S_D2B;
            S_D2B: st <= S_D2L;
            S_D2L: begin
                w_h1s0 <= d56_dec;
                if (mode8) st <= S_D3;
                else begin f_stripe <= 1'b1; st <= S_F3; end
            end
            S_F3: if (rom_ok && addr_ready) begin raw_r <= rom_data; d56_run <= 1'b1; st <= S_D3; end
            S_D3: st <= S_D3B;
            S_D3B: st <= S_D3L;
            S_D3L: begin
                w_h1s1 <= d56_dec;
                tflx_now <= tile_next[15] & ctl1[0];
                tfly_now <= tile_next[15] & ctl1[1];
                blit_i   <= 5'd0;
                px_r     <= $signed({1'b0, col_x}) - $signed({7'd0, xalign});
                st       <= S_BLIT;
            end

            S_BLIT: begin
                if (px_on) begin
                    buf_we <= 1'b1;
                    buf_x  <= pxs;
                    // PF2 is drawn with TILEMAP_DRAW_OPAQUE and PF1 without
                    // (hvysmsh.cpp:111-116), so PF2's pen 0 is a REAL colour --
                    // colour*16 + 0 of its bank -- and not a hole.  Writing it
                    // as 0 put palette entry 0 (black) under the whole screen:
                    // 51658 of 76800 pixels at the title screen, 67% of the
                    // picture, where MAME has 0x100/0x110/0x120.
                    // A disabled layer (control0 bit 7, deco16ic.cpp:585-600)
                    // draws nothing at all, and under PF2 that leaves
                    // bitmap.fill(0) showing: index 0 either way.
                    buf_d  <= !pf_en                 ? 10'd0 :
                              (cur_pf || (pen != 0)) ? {colour_eff + colbank, pen}
                                                     : 10'd0;
                end
                if (blit_i == tw - 5'd1) begin
                    if (tcol == (mode8 ? 6'd40 : 6'd20)) st <= S_NEXTPF;
                    else begin
                        tcol  <= tcol + 6'd1;
                        col_x <= col_x + {4'd0, tw};
                        st    <= S_COLIDX;
                    end
                end
                blit_i <= blit_i + 5'd1;
                px_r   <= px_r + 11'sd1;
            end

            S_NEXTPF: begin
                tcol <= 6'd0;
                if (cur_pf) st <= S_DONE;
                else begin
                    cur_pf  <= 1'b1;
                    ctl0    <= ctrl[5][15:8];
                    ctl1    <= ctrl[6][15:8];
                    scx     <= ctrl[3];
                    scy     <= ctrl[4];
                    bankval <= ctrl[7][15:8];
                    st      <= S_ROWIDX;
                end
            end
            S_DONE: begin
                line_done <= 1'b1;
                st <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase
        end
    end

    // y_in flip (per-tile) must apply before the fetches; recomputed here
    // because tfly_now is only known once the tile word arrives.
    wire [15:0] tile_next = vram_q2;   // tile word during S_TCALC..S_D3
    always @(posedge clk) begin
        if (st == S_TCALC) begin
            if (mode8)
                y_in <= (tile_next[15] & ctl1[1]) ? (yy_eff[2:0] ^ 4'd7) : yy_eff[2:0];
            else
                y_in <= (tile_next[15] & ctl1[1]) ? (yy_eff[3:0] ^ 4'd15) : yy_eff[3:0];
        end
    end

endmodule

`default_nettype wire
