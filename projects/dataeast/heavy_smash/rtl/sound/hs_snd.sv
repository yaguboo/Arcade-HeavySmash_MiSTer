//============================================================================
//  Heavy Smash -- dual MSM6295 + shared volume + mix.
//
//  hvysmsh.cpp:377-383: OKI0 at 28/28 = 1.000 MHz pin7 high -> mono 1.0,
//  OKI1 at 28/14 = 2.000 MHz pin7 high -> mono 0.35.  The port write at
//  0x120000 scales BOTH chips linearly, 0x00 max .. 0xff min (:123-132) --
//  MAME's own "TODO: assumes linear", kept as EMULATION_DERIVED.
//
//  OKI1's sample ROM is address-descrambled on the fly: the logical byte
//  address's low 21 bits rotate RIGHT by one (bitswap<24> in hvysmsh.cpp:
//  671-691, same math as FBNeo's descramble_sound).
//============================================================================
`default_nettype none

module hs_snd (
    input  wire        clk,
    input  wire        rst,

    input  wire        cen_oki0,        // 1.00 MHz
    input  wire        cen_oki1,        // 2.00 MHz

    // --- CPU side (hs_bus) -------------------------------------------------------
    input  wire        oki0_we, oki0_re,
    input  wire        oki1_we, oki1_re,
    input  wire [7:0]  cpu_dout,
    output wire [7:0]  oki0_do, oki1_do,
    input  wire        oki0_bk_we,
    input  wire        oki0_bk,
    input  wire        oki1_bk_we,
    input  wire [2:0]  oki1_bk,
    input  wire        vol_we,
    input  wire [7:0]  vol_d,

    // --- sample ROM fetches (romarb clients) ---------------------------------------
    output wire        rom0_cs,
    output wire [22:0] rom0_addr,       // word address in the oki0 region
    input  wire [15:0] rom0_data,
    input  wire        rom0_ok,
    output wire        rom1_cs,
    output wire [22:0] rom1_addr,
    input  wire [15:0] rom1_data,
    input  wire        rom1_ok,

    output wire signed [15:0] snd_l, snd_r
);

    // ---------------------------------------------------------------- chips
    wire [17:0] oki0_ra, oki1_ra;
    wire [7:0]  oki0_rd, oki1_rd;
    wire signed [13:0] oki0_snd, oki1_snd;

    wire samp0, samp1;

    jt6295 #(.INTERPOL(0), .SAMPLE(1)) u_oki0 (
        .rst      ( rst            ),
        .clk      ( clk            ),
        .cen      ( cen_oki0       ),
        .ss       ( 1'b1           ),   // pin 7 high
        .wrn      ( ~oki0_we       ),
        .din      ( cpu_dout       ),
        .dout     ( oki0_do        ),
        .rom_addr ( oki0_ra        ),
        .rom_data ( oki0_rd        ),
        .rom_ok   ( rom0_ok        ),
        .sound    ( oki0_snd       ),
        .sample   ( samp0          )
    );

    jt6295 #(.INTERPOL(0), .SAMPLE(1)) u_oki1 (
        .rst      ( rst            ),
        .clk      ( clk            ),
        .cen      ( cen_oki1       ),
        .ss       ( 1'b1           ),
        .wrn      ( ~oki1_we       ),
        .din      ( cpu_dout       ),
        .dout     ( oki1_do        ),
        .rom_addr ( oki1_ra        ),
        .rom_data ( oki1_rd        ),
        .rom_ok   ( rom1_ok        ),
        .sound    ( oki1_snd       ),
        .sample   ( samp1          )
    );

    // ---------------------------------------------------------------- banks
    reg        bk0 = 1'b0;
    reg  [2:0] bk1 = 3'd0;
    always @(posedge clk) begin
        if (oki0_bk_we) bk0 <= oki0_bk;
        if (oki1_bk_we) bk1 <= oki1_bk;
    end

    // ---------------------------------------------------------------- ROM addressing
    // All of it is in hs_oki_addr so sim/tb_okiaddr.sv can check it against
    // MAME's own loaded regions.  Three lines, all three wrong before
    // DEBUG_LOG D18, and nothing on the board could have told the result
    // apart from "the sound chip model is off".
    localparam [22:0] OKI0_BASE = 23'h380000;
    localparam [22:0] OKI1_BASE = 23'h3C0000;

    wire odd0, odd1;
    hs_oki_addr #(.SCRAMBLE(1'b0), .BASE(OKI0_BASE)) u_a0 (
        .bank({2'b00, bk0}), .chip_a(oki0_ra),
        .sdram_a(rom0_addr), .odd_byte(odd0));
    hs_oki_addr #(.SCRAMBLE(1'b1), .BASE(OKI1_BASE)) u_a1 (
        .bank(bk1), .chip_a(oki1_ra),
        .sdram_a(rom1_addr), .odd_byte(odd1));

    assign rom0_cs = 1'b1;                       // chips fetch continuously
    assign rom1_cs = 1'b1;

    // byte lanes (file-order storage: SDRAM word = {byte even, byte odd})
    assign oki0_rd = odd0 ? rom0_data[7:0] : rom0_data[15:8];
    assign oki1_rd = odd1 ? rom1_data[7:0] : rom1_data[15:8];

    // ---------------------------------------------------------------- gain + mix
    reg [7:0] vol = 8'd0;                          // 0x00 = max
    always @(posedge clk) if (vol_we) vol <= vol_d;

    // ------------------------------------------------- reconstruction
    // Each chip's `sound` bus is a zero-order hold at its own rate, and the
    // two rates differ by 2x, so the same filter does NOT treat them alike:
    // unfiltered, OKI0 carries 5.9 % of its energy as images and OKI1 only
    // 0.19 %.  That asymmetry is what a listener hears as the two chips
    // having different volumes, and it is why this is per chip rather than
    // on the mix.
    //
    // A two-pole IIR stood here from 2026-09-23 and did help (OKI0 27.1 %
    // error down to 14.6 %), but the images start at 3788 Hz and OKI0's
    // signal also ends at 3788 Hz -- there is no guard band, so every dB an
    // IIR takes off the images it takes off the music too.  Linear
    // interpolation separates them instead of trading them: see the table in
    // hs_snd_lerp.sv.  Measured, not assumed; the sweep is tools/oki_bands.py.
    wire signed [15:0] f0, f1;

    hs_snd_lerp u_lerp0 (.clk(clk), .rst(rst), .cen(cen_oki0),
                         .samp(samp0), .din(oki0_snd), .dout(f0));
    hs_snd_lerp u_lerp1 (.clk(clk), .rst(rst), .cen(cen_oki1),
                         .samp(samp1), .din(oki1_snd), .dout(f1));

    hs_snd_mix u_mix (.s0(f0), .s1(f1), .vol(vol),
                      .snd(snd_l));
    assign snd_r = snd_l;

endmodule

`default_nettype wire
