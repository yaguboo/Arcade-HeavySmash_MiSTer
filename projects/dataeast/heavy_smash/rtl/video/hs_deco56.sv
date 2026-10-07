//============================================================================
//  Heavy Smash -- DECO141 gfx (DECO56 tables) live decryption.
//
//  decocrpt.cpp deco_decrypt, on the fly per 16-bit ROM word:
//    phys_word = (i & ~0x7ff) | address_table[i & 0x7ff]
//    word      = bitswap16(sdram[phys] ^ xor_masks[xor_table[phys & 0x7ff]],
//                          swap_patterns[swap_table[i & 0x7ff]])
//  Table lookup takes a clk (they are BRAMs); the fetch pipeline hides it.
//  swap_patterns listed MSB-first, from tools/extract_deco56.py output.
//============================================================================
`default_nettype none

module hs_deco56_addr (
    input  wire        clk,
    input  wire [10:0] i,          // logical word index, low 11 bits
    output reg  [10:0] p = 11'd0   // same-2KB-block permuted index
);
    (* rom_style = "M9K" *) reg [10:0] tbl [0:2047];
    initial $readmemh("deco56_addr.hex", tbl);
    always @(posedge clk) p <= tbl[i];
endmodule

module hs_deco56 (
    input  wire        clk,
    input  wire [10:0] i,          // logical destination word (low bits)
    input  wire [10:0] phys_l,     // physical word low bits (for xor index)
    input  wire        run,        // qualifies i/phys_l on this clk
    input  wire [15:0] raw,        // word read from SDRAM
    output reg  [15:0] dec = 16'd0
);
    (* rom_style = "M9K" *) reg [3:0] xor_t [0:2047];
    (* rom_style = "M9K" *) reg [2:0] swp_t [0:2047];
    initial $readmemh("deco56_xor.hex",  xor_t);
    initial $readmemh("deco56_swap.hex", swp_t);

    function automatic [15:0] xor16(input [15:0] v, input [3:0] sel);
        xor16 = v ^ (sel == 4'd0  ? 16'hd556 :
                     sel == 4'd1  ? 16'h73cb :
                     sel == 4'd2  ? 16'h2963 :
                     sel == 4'd3  ? 16'h4b9a :
                     sel == 4'd4  ? 16'hb3bc :
                     sel == 4'd5  ? 16'hbc73 :
                     sel == 4'd6  ? 16'hcbc9 :
                     sel == 4'd7  ? 16'haeb5 :
                     sel == 4'd8  ? 16'h1e6d :
                     sel == 4'd9  ? 16'hd5b5 :
                     sel == 4'd10 ? 16'he676 :
                     sel == 4'd11 ? 16'h5cc5 :
                     sel == 4'd12 ? 16'h395a :
                     sel == 4'd13 ? 16'hdaae :
                     sel == 4'd14 ? 16'h2629 : 16'he59e);
    endfunction

    function automatic [15:0] bswap16(input [15:0] v, input [2:0] pat);
        bswap16 = (pat == 3'd0) ? {v[15],v[ 8],v[ 9],v[12],v[10],v[13],v[11],v[14],
                                   v[ 2],v[ 7],v[ 4],v[ 3],v[ 1],v[ 5],v[ 6],v[ 0]} :
                   (pat == 3'd1) ? {v[12],v[10],v[11],v[ 9],v[ 8],v[15],v[14],v[13],
                                   v[ 6],v[ 0],v[ 3],v[ 5],v[ 7],v[ 4],v[ 2],v[ 1]} :
                   (pat == 3'd2) ? {v[ 8],v[12],v[11],v[ 9],v[13],v[14],v[15],v[10],
                                   v[ 4],v[ 6],v[ 5],v[ 0],v[ 3],v[ 1],v[ 7],v[ 2]} :
                   (pat == 3'd3) ? {v[ 8],v[ 9],v[10],v[13],v[11],v[15],v[14],v[12],
                                   v[ 5],v[ 4],v[ 0],v[ 7],v[ 2],v[ 6],v[ 1],v[ 3]} :
                   (pat == 3'd4) ? {v[12],v[13],v[14],v[15],v[ 8],v[ 9],v[10],v[11],
                                   v[ 1],v[ 5],v[ 0],v[ 3],v[ 2],v[ 7],v[ 6],v[ 4]} :
                   (pat == 3'd5) ? {v[14],v[15],v[13],v[ 8],v[12],v[10],v[11],v[ 9],
                                   v[ 1],v[ 2],v[ 7],v[ 6],v[ 4],v[ 3],v[ 0],v[ 5]} :
                   (pat == 3'd6) ? {v[13],v[14],v[10],v[11],v[ 9],v[ 8],v[12],v[15],
                                   v[ 3],v[ 1],v[ 7],v[ 4],v[ 5],v[ 0],v[ 2],v[ 6]} :
                                   {v[ 9],v[ 8],v[14],v[10],v[15],v[11],v[13],v[12],
                                   v[ 6],v[ 0],v[ 5],v[ 2],v[ 4],v[ 1],v[ 3],v[ 7]};
    endfunction

    reg [3:0] xr = 4'd0;
    reg [2:0] pat = 3'd0;
    always @(posedge clk) begin
        if (run) begin
            xr  <= xor_t[phys_l];
            pat <= swp_t[i];
        end
        dec <= bswap16(xor16(raw, xr), pat);
    end
endmodule

`default_nettype wire
