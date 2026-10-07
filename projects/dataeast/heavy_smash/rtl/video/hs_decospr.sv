//============================================================================
//  Heavy Smash -- DECO52 sprite generator.
//
//  Reference: MAME src/mame/shared/decospr.cpp, draw_sprites_common, the
//  !m_alt_format path.  That file is NOT in this factory's sparse MAME
//  checkout by default -- src/mame/shared was missing, which is why the first
//  version of this module was written without it.  Add it with
//      git -C references/upstream/mame sparse-checkout add src/mame/shared
//
//  hvysmsh specifics (hvysmsh.cpp:104-118, 328-339):
//   - pri_cb IS set, so MAME walks the list 0x7FC DOWN to 0 and draws through
//     prio_transpen.
//   - set_flip_screen(true): "sprites are flipped relative to tilemaps".
//     The generic flip is applied twice on this geometry (cliprect.right()
//     > 256), so the net effect is yscr = y, xscr = x, fx/fy inverted, and
//     the sub-tiles step DOWNWARD (mult = +16).
//   - sprite pri (w2[15:14]) is INERT here: the priority bitmap is 0
//     everywhere the sprites draw, and 1 & pmask == 0 for all three pmasks
//     hvysmsh's pri_callback returns.  Verified in source, not assumed.
//   - flash bit w0[12] skips odd frames; height = 1 << w0[10:9] tiles.
//   - colour = w2[13:9] (decospr's default_col_cb), palette = 0x200 +
//     colour*16 + pen.
//   - w0[11] is the "double wing" wide flag: a second tile at x+16 (x-16
//     without flipscreen) with code (sprite - m*inc) - (multi+1).
//
//  SPRITE OVER SPRITE IS FIRST-WRITE-WINS.  prio_transpen sets
//  `pmask |= 1 << 31` (drawgfx.cpp:933, "high bit of the mask is implicitly
//  on") and its pixel op writes `priority = 31` for every non-transparent
//  pixel (drawgfxt.ipp:216-226), so the next sprite over that pixel is
//  dropped.  The first entry of MAME's descending walk -- the HIGHEST
//  spriteram offset -- keeps the pixel.  This module therefore walks
//  ASCENDING and lets later writes win, which is the same picture with one
//  write port and no priority RAM.  The comment that used to sit here said
//  the opposite; root CLAUDE.md 5.1 records the factory getting this exact
//  drawgfx rule backwards once before, on Power Spikes.
//
//  ROM word per row (the sprite gfx uses the same tilelayout as the tiles):
//     word(half, stripe) = code*0x20 + stripe*0x10 + y_in + half*0x100000
//  with stripe 0 holding x=8..15 and stripe 1 holding x=0..7.
//============================================================================
`default_nettype none

module hs_decospr (
    input  wire        clk,
    input  wire        rst,

    // --- sprite RAM render port ------------------------------------------------
    output reg  [10:0] spr_a2 = 11'd0,
    input  wire [15:0] spr_q2,

    // --- sprite ROM fetch (romarb client) ----------------------------------------
    output wire        rom_cs,
    output wire [21:0] rom_addr,
    input  wire [15:0] rom_data,
    input  wire        rom_ok,

    // --- line buffer (double buffered, own RAM) ------------------------------------
    output reg         buf_we  = 1'b0,
    output reg  [8:0]  buf_x   = 9'd0,
    output reg  [9:0]  buf_d   = 10'd0,
    input  wire        buf_sel,
    input  wire [8:0]  rd_x,
    input  wire        rd_sel,
    output wire [9:0]  q_spr,

    // --- control ---------------------------------------------------------------------
    input  wire        frame_odd,
    input  wire        line_go,
    input  wire [8:0]  line_y,
    output reg         line_done = 1'b0
);

    localparam [21:0] SPR_BASE = 22'h180000;

    localparam S_IDLE=0, S_A=1, S_B=2, S_C=3, S_D=4,
               S_F0=5, S_F1=6, S_F2=7, S_F3=8, S_BLIT=9, S_NEXT=10, S_DONE=11;

    reg [3:0]  st = S_IDLE;
    reg [8:0]  ly;
    reg [11:0] offs;          // word offset of the entry, 0x000 .. 0x7FC
                              // 12 bits: 0x7FC + 4 is 0x800 and must not wrap
    reg [15:0] w0, w1;
    reg signed [9:0] yscr_s, xscr_s;
    reg [3:0]  y_in;
    reg        fx_eff, fy_eff;
    reg [15:0] code_k;
    reg [4:0]  colour;
    reg [15:0] ws0_s0, ws0_s1, ws1_s0, ws1_s1;
    reg        f_half, f_stripe;
    reg [4:0]  blit_i;
    reg        wide, wpass;

    // ---------------------------------------------------------------- geometry
    // w0/w1 are registered; w2 is taken straight off spr_q2 in S_D so that a
    // non-hit entry costs four clocks and not five.  The sprite walk is the
    // tightest budget on the board (512 entries in 6336 clocks) and a fifth
    // clock per entry does not fit.
    wire [15:0] w2_now = spr_q2;

    wire [1:0]  nsub   = {w0[10], w0[9]};
    wire [3:0]  multi  = (4'd1 << nsub) - 4'd1;    // height-1 in tiles

    wire signed [9:0] ly_s = {1'b0, ly};
    wire [8:0] stack_h = {1'b0, multi, 4'd0} + 9'd16;   // (multi+1)*16 rows
    wire signed [9:0] yscr_now = (w0[8:0] >= 9'd256)
                               ? $signed({1'b0, w0[8:0]}) - 10'd512
                               : $signed({1'b0, w0[8:0]});
    wire signed [9:0] xscr_now = (w2_now[8:0] >= 9'd320)
                               ? $signed({1'b0, w2_now[8:0]}) - 10'd512
                               : $signed({1'b0, w2_now[8:0]});

    // Does this line fall inside the sprite's stack of sub-tiles?  MAME's own
    // gate (ypos <= cliprect.bottom() && ypos >= cliprect.top()-16) is implied
    // once the line is inside the stack AND visible, so it is not repeated.
    // The old code also demanded 0 <= yscr <= 240, which is not in decospr and
    // threw away every sprite hanging off the top or bottom edge.
    wire hit_y = (ly_s >= yscr_now)
              && (ly_s < yscr_now + $signed({1'b0, stack_h}))
              && !(w0[12] && frame_odd);
    wire hit_x = (xscr_now > -10'sd16 && xscr_now < 10'sd320)
              || (w0[11] && xscr_now > -10'sd32 && xscr_now < 10'sd304);
    wire hit_now = hit_y && hit_x;

    // which sub-tile of the stack covers this line, and the row inside it
    wire [9:0] ydiff = $unsigned(ly_s - yscr_now);   // 0 .. (multi+1)*16-1 on a hit
    wire [3:0] k_sub = ydiff[7:4];

    // decospr.cpp:296-304.  `inc` is decided from the RAW fy bit, BEFORE the
    // flipscreen inversion -- taking it from the flipped one reversed the
    // order of every multi-tile sprite's artwork.
    //    fy_raw : sprite = w1 & ~multi          code = sprite + k
    //   !fy_raw : sprite = (w1 & ~multi) + multi, code = sprite - k
    // fy_raw must be a WIRE off w0, not a register written in S_D: code_main
    // is consumed in that same clock, and a registered copy would still hold
    // the previous entry's flip -- every sprite whose predecessor flipped the
    // other way picked the wrong sub-tile.  (Frames 900 and 1200: one sprite
    // each, 504 and 480 pixels, and in both cases it was the entry at offs 0.)
    wire        fy_raw = w0[14];
    wire [15:0] sprite_w = w1 & ~{12'd0, multi};
    wire [15:0] sprite_adj = fy_raw ? sprite_w : (sprite_w + {12'd0, multi});
    wire [15:0] code_main = fy_raw ? (sprite_adj + {12'd0, k_sub})
                                   : (sprite_adj - {12'd0, k_sub});
    // decospr.cpp:345: the double-wing partner is (sprite - m*inc) - mult2
    wire [15:0] code_wide = code_main - {12'd0, multi} - 16'd1;

    // ---- ROM word ------------------------------------------------------------
    // code is 15 bits here: a half of the sprite region is 0x200000 bytes =
    // 32768 tiles of 64.  MAME's gfx has 65536 elements because RGN_FRAC(1,2)
    // of the 8 MB region is 0x400000 bytes, but the upper half of each plane
    // is the ROM_REGION gap and reads as zero -- a blank tile.  code_k[15]
    // therefore means "blank", and is forced transparent below rather than
    // folded into an address that would land in the other chip.
    wire [21:0] log_word = {6'd0, code_k[14:0], 5'd0}
                         + {17'd0, f_stripe, 4'd0} + {18'd0, y_in}
                         + (f_half ? 22'h100000 : 22'd0);
    assign rom_cs   = (st == S_F0) | (st == S_F1) | (st == S_F2) | (st == S_F3);
    assign rom_addr = SPR_BASE + log_word;

    // ---- pixel nibble --------------------------------------------------------
    // Same gfx_layout as the tiles (hvysmsh.cpp:285-304, gfx_hvysmsh_spr uses
    // tilelayout): planeoffset { half+8, half, 8, 0 } with planeoffset[0] as
    // the MSB, xoffset { STEP8(8*2*16,1), STEP8(0,1) } so x=8..15 live in the
    // FIRST 32 bytes, and decodegfx reads bit (7 - x%8).  The old code had the
    // bit index running x instead of 7-x and the stripe select inverted.
    reg blank;
    wire [3:0] xeff = fx_eff ? (4'd15 - blit_i[3:0]) : blit_i[3:0];
    wire [2:0] bx   = ~xeff[2:0];
    wire [15:0] ws0 = xeff[3] ? ws0_s0 : ws0_s1;
    wire [15:0] ws1 = xeff[3] ? ws1_s0 : ws1_s1;
    wire [3:0] pen  = blank ? 4'd0
                            : {ws1[{1'b0, bx}], ws1[{1'b1, bx}],
                               ws0[{1'b0, bx}], ws0[{1'b1, bx}]};

    // ---- line buffer ---------------------------------------------------------
    // 1024 entries: the address is {sel, x} with a nine-bit x, so half 1
    // starts at 512.
    //
    // The blitter writes only non-transparent pixels, so the half it fills
    // still holds the line from two lines ago wherever no sprite lands.  The
    // erase runs on the same write port in the clocks the blitter does not
    // use it, over the half being SCANNED OUT and two pixels behind the beam,
    // which is the pattern shadow_force's sf_sprite.sv arrived at
    // (rtl/video/sf_sprite.sv:393).  Erasing the entry being read in the clock
    // it is read is what one port cannot do -- root CLAUDE.md 7 and Power
    // Spikes' LESSONS_LEARNED L24 are 11,264 flip-flops of that mistake.
    reg [9:0] lbuf [0:1023];
    reg [9:0] erase_ptr = 10'd0;
    wire       erase_do = ~buf_we && (erase_ptr < 10'd320)
                        && ((erase_ptr + 10'd2) < {1'b0, rd_x});
    wire [9:0] wa = buf_we ? {buf_sel, buf_x} : {rd_sel, erase_ptr[8:0]};
    always @(posedge clk) begin
        if (buf_we)        lbuf[wa] <= buf_d;
        else if (erase_do) lbuf[wa] <= 10'd0;
    end
    always @(posedge clk) begin
        if (rst)           erase_ptr <= 10'd0;
        else if (line_go)  erase_ptr <= 10'd0;
        else if (erase_do) erase_ptr <= erase_ptr + 10'd1;
    end
    reg [9:0] qr;
    always @(posedge clk) qr <= lbuf[{rd_sel, rd_x}];
    assign q_spr = qr;

    wire signed [9:0] px = xscr_s + {5'd0, blit_i} + (wpass ? 10'sd16 : 10'sd0)
                         + 10'sd16;
    wire        px_on  = (px >= 10'd16) && (px < 10'd336);
    wire [8:0]  pxs    = px[8:0] - 9'd16;

    // ---------------------------------------------------------------- FSM
    // Four clocks an entry: spr_a2 is one ahead of the word being latched
    // because hs_dpram16's B port is a registered read.
    //   S_A  addr <= offs+1
    //   S_B  w0 <= ram[offs]      addr <= offs+2
    //   S_C  w1 <= ram[offs+1]    addr <= offs+4   (the next entry)
    //   S_D  w2 = ram[offs+2] read combinationally, decide, offs += 4
    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; line_done <= 1'b0; buf_we <= 1'b0;
        end else begin
            line_done <= 1'b0;
            buf_we    <= 1'b0;

            case (st)
            S_IDLE: if (line_go) begin
                ly     <= line_y;
                offs   <= 12'd0;
                spr_a2 <= 11'd0;
                st     <= S_A;
            end

            S_A: begin spr_a2 <= offs[10:0] + 11'd1; st <= S_B; end
            S_B: begin
                w0     <= spr_q2;
                spr_a2 <= offs[10:0] + 11'd2;
                st     <= S_C;
            end
            S_C: begin
                w1     <= spr_q2;
                spr_a2 <= offs[10:0] + 11'd4;
                st     <= S_D;
            end
            S_D: begin
                // w2 is on spr_q2 right now; everything derived from it is
                // taken combinationally in this clock.
                colour <= w2_now[13:9];
                xscr_s <= xscr_now;
                yscr_s <= yscr_now;
                fy_eff <= ~w0[14];
                fx_eff <= ~w0[13];
                wide   <= w0[11];
                wpass  <= 1'b0;
                offs   <= offs + 12'd4;
                if (hit_now) begin
                    y_in   <= (~w0[14]) ? (ydiff[3:0] ^ 4'd15) : ydiff[3:0];
                    code_k <= code_main;
                    blank  <= code_main[15];
                    f_half <= 1'b0; f_stripe <= 1'b0;
                    blit_i <= 5'd0;
                    st <= S_F0;
                end else begin
                    st <= (offs == 12'h7FC) ? S_DONE : S_A;
                end
            end

            // ---- four fetches (stripe/half), no DECO56 on the sprite ROM
            S_F0: if (rom_ok) begin ws0_s0 <= rom_data; f_stripe <= 1'b1; st <= S_F1; end
            S_F1: if (rom_ok) begin ws0_s1 <= rom_data; f_stripe <= 1'b0; f_half <= 1'b1; st <= S_F2; end
            S_F2: if (rom_ok) begin ws1_s0 <= rom_data; f_stripe <= 1'b1; st <= S_F3; end
            S_F3: if (rom_ok) begin ws1_s1 <= rom_data; st <= S_BLIT; end

            S_BLIT: begin
                // transparent pixels are not written at all: the erase above
                // needs the port, and a 0 write would only re-clear what the
                // erase already cleared.
                if (px_on && (pen != 4'd0)) begin
                    buf_we <= 1'b1;
                    buf_x  <= pxs;
                    buf_d  <= {1'b1, colour, pen};
                end
                if (blit_i == 5'd15) st <= S_NEXT;
                blit_i <= blit_i + 5'd1;
            end

            S_NEXT: begin
                if (wide && !wpass) begin
                    wpass    <= 1'b1;
                    code_k   <= code_wide;
                    blank    <= code_wide[15];
                    f_half   <= 1'b0; f_stripe <= 1'b0;
                    blit_i   <= 5'd0;
                    st       <= S_F0;
                end else if (offs == 12'h800) begin
                    st <= S_DONE;
                end else begin
                    st <= S_A;
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

endmodule

`default_nettype wire
