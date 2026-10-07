//============================================================================
//  Heavy Smash -- DE156 program-ROM decryption, live.
//
//  This is the transform of references/upstream/mame/src/mame/dataeast/
//  deco156.cpp:43-124, factored so it can sit in the CPU fetch path.  The
//  tables were verified against the real dump (tools/check_rom.py): feeding
//  the interleaved ROM through this gives ARM boot code (EA00000D at 0).
//
//  Address side: the source dword index is 0x92c6 XORed with a mask per set
//  bit of the destination index's low 16 bits (bit 17+ of a never matter for
//  a 1 MB ROM -- a&0xff0000 is always 0 here, but the term is kept to match
//  upstream for larger DE156 ROMs).  Bits 17/16 of `a` DO select different
//  data XOR/bitswaps, so four destination dwords can share one source dword.
//
//  Data side: XOR by address-dependent mask, then one of four 32-bit bit
//  permutations selected by a[1:0].
//============================================================================
`default_nettype none

module hs_de156_addr (
    input  wire [17:0] a,       // destination dword index (1 MB ROM = 18 bits)
    output wire [17:0] p        // source dword index
);
    // deco156.cpp:47 -- addr = (a & 0xff0000) | 0x92c6; the index's bits 17:16
    // pass STRAIGHT THROUGH to the source address, only the low 16 bits are
    // XOR-chained.  Verified against the dump (bench caught the omission).
    assign p[17:16] = a[17:16];
    assign p[15:0]  = 16'h92c6
             ^ (a[ 0] ? 16'hce4a : 16'h0000)
             ^ (a[ 1] ? 16'h4db2 : 16'h0000)
             ^ (a[ 2] ? 16'hef60 : 16'h0000)
             ^ (a[ 3] ? 16'h5737 : 16'h0000)
             ^ (a[ 4] ? 16'h13dc : 16'h0000)
             ^ (a[ 5] ? 16'h4bd9 : 16'h0000)
             ^ (a[ 6] ? 16'ha209 : 16'h0000)
             ^ (a[ 7] ? 16'hd996 : 16'h0000)
             ^ (a[ 8] ? 16'ha700 : 16'h0000)
             ^ (a[ 9] ? 16'heca0 : 16'h0000)
             ^ (a[10] ? 16'h7529 : 16'h0000)
             ^ (a[11] ? 16'h3100 : 16'h0000)
             ^ (a[12] ? 16'h33b4 : 16'h0000)
             ^ (a[13] ? 16'h6161 : 16'h0000)
             ^ (a[14] ? 16'h1eef : 16'h0000)
             ^ (a[15] ? 16'hf5a5 : 16'h0000);
endmodule

module hs_de156_data (
    input  wire [17:0] a,       // full destination dword index (18 bits, 1 MB ROM)
    input  wire [31:0] raw,     // source dword as stored (little-endian image)
    output wire [31:0] dec
);
    wire [31:0] x = raw
                 ^ (a[ 2] ? 32'h04400000 : 32'h0)
                 ^ (a[ 3] ? 32'h40000004 : 32'h0)
                 ^ (a[ 4] ? 32'h00048000 : 32'h0)
                 ^ (a[ 5] ? 32'h00000280 : 32'h0)
                 ^ (a[ 6] ? 32'h00200040 : 32'h0)
                 ^ (a[ 7] ? 32'h09000000 : 32'h0)
                 ^ (a[ 8] ? 32'h00001100 : 32'h0)
                 ^ (a[ 9] ? 32'h20002000 : 32'h0)
                 ^ (a[10] ? 32'h00000022 : 32'h0)
                 ^ (a[11] ? 32'h000a0000 : 32'h0)
                 ^ (a[12] ? 32'h10004000 : 32'h0)
                 ^ (a[13] ? 32'h00010400 : 32'h0)
                 ^ (a[14] ? 32'h80000010 : 32'h0)
                 ^ (a[15] ? 32'h00000009 : 32'h0)
                 ^ (a[16] ? 32'h02100000 : 32'h0)
                 ^ (a[17] ? 32'h00800800 : 32'h0);

    // bitswap<32>(v ^ const, b31..b0) from deco156.cpp:90-119, result bit i =
    // v'[b_i].  XOR first, then permute -- the two do not commute.
    wire [31:0] x0 = x ^ 32'hec63197a;
    wire [31:0] x1 = x ^ 32'h58a5a55f;
    wire [31:0] x2 = x ^ 32'he3a65f16;
    wire [31:0] x3 = x ^ 32'h28d93783;

    wire [31:0] b0 = {x0[ 1],x0[ 4],x0[ 7],x0[28],x0[22],x0[18],x0[20],x0[ 9],
                      x0[16],x0[10],x0[30],x0[ 2],x0[31],x0[24],x0[19],x0[29],
                      x0[ 6],x0[21],x0[23],x0[11],x0[12],x0[13],x0[ 5],x0[ 0],
                      x0[ 8],x0[26],x0[27],x0[15],x0[14],x0[17],x0[25],x0[ 3]};
    wire [31:0] b1 = {x1[14],x1[23],x1[28],x1[29],x1[ 6],x1[24],x1[10],x1[ 1],
                      x1[ 5],x1[16],x1[ 7],x1[ 2],x1[30],x1[ 8],x1[18],x1[ 3],
                      x1[31],x1[22],x1[25],x1[20],x1[17],x1[ 0],x1[19],x1[27],
                      x1[ 9],x1[12],x1[21],x1[15],x1[26],x1[13],x1[ 4],x1[11]};
    wire [31:0] b2 = {x2[19],x2[30],x2[21],x2[ 4],x2[ 2],x2[18],x2[15],x2[ 1],
                      x2[12],x2[25],x2[ 8],x2[ 0],x2[24],x2[20],x2[17],x2[23],
                      x2[22],x2[26],x2[28],x2[16],x2[ 9],x2[27],x2[ 6],x2[11],
                      x2[31],x2[10],x2[ 3],x2[13],x2[14],x2[ 7],x2[29],x2[ 5]};
    wire [31:0] b3 = {x3[30],x3[ 6],x3[15],x3[ 0],x3[31],x3[18],x3[26],x3[22],
                      x3[14],x3[23],x3[19],x3[17],x3[10],x3[ 8],x3[11],x3[20],
                      x3[ 1],x3[28],x3[ 2],x3[ 4],x3[ 9],x3[24],x3[25],x3[27],
                      x3[ 7],x3[21],x3[13],x3[29],x3[ 5],x3[ 3],x3[16],x3[12]};

    assign dec = (a[1:0] == 2'd0) ? b0 :
                 (a[1:0] == 2'd1) ? b1 :
                 (a[1:0] == 2'd2) ? b2 : b3;
endmodule

`default_nettype wire
