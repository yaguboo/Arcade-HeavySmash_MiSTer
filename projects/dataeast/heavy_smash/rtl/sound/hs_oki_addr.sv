//============================================================================
//  Heavy Smash -- where an MSM6295 sample byte lives in SDRAM.
//
//  Its own module so sim/tb_okiaddr.sv can check it against MAME's own loaded
//  regions.  It is three lines of concatenation, and all three were wrong
//  (DEBUG_LOG D18) in a way nothing on the board could have told apart from
//  "the sound chip model is off".
//
//  bank:   okim6295 is a device_rom_interface<18> (okim6295.h:28) -- an
//          0x40000-byte window, and set_rom_bank(n) maps region bytes
//          n*0x40000 upward into it (dirom.ipp:70-77).
//  scram:  init_hvysmsh calls descramble_sound("oki2"), which builds
//          region[ror21(x)] = file[x] (hvysmsh.cpp:671-691).  We hold the
//          FILE in SDRAM, so the byte the chip wants at region address a is
//          file[rol21(a)].  SCRAMBLE=0 leaves the address alone, which is
//          what the unscrambled oki1 region needs.
//  store:  the loader packs byte pairs big-endian, {even, odd}, so the even
//          byte of a word is [15:8].
//============================================================================
`default_nettype none

module hs_oki_addr #(
    parameter bit        SCRAMBLE = 1'b0,
    parameter [22:0]     BASE     = 23'd0     // word address of the region
) (
    input  wire [2:0]  bank,                  // set_rom_bank value
    input  wire [17:0] chip_a,                // the chip's own 18-bit address
    output wire [22:0] sdram_a,               // word address to fetch
    output wire        odd_byte               // 1 -> [7:0], 0 -> [15:8]
);
    wire [20:0] region_a = {bank, chip_a};                 // bank * 0x40000 + a
    wire [20:0] file_a   = SCRAMBLE ? {region_a[19:0], region_a[20]}
                                    : region_a;
    // 23 bits, not 22: oki2 sits at word 0x3C0000 and is 0x100000 words
    // long, so its top is 0x4C0000 and a 22-bit bus wraps it to 0x0C0000.
    // sim/tb_okiaddr.sv caught it at 2992 of 4000 samples -- three quarters
    // of the region, which is every address above the wrap.
    assign sdram_a  = BASE + {2'b0, file_a[20:1]};
    assign odd_byte = file_a[0];
endmodule

`default_nettype wire
