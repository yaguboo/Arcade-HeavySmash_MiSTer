//============================================================================
//  Heavy Smash -- the two MSM6295s mixed into AUDIO_L.
//
//  Its own module for the same reason hs_oki_addr is: so a bench can decide
//  it.  sim/tb_mix.sv walks it against the same arithmetic in python
//  (tools/mix_model.py) over every interesting (s0, s1, vol) -- and the two
//  faults below are exactly the kind that a listening test reports as "the
//  sound chip is wrong".
//
//  1. THE SHIFTS ARE ARITHMETIC.  `>>` on a signed expression fills with
//     zeros (IEEE 1800 11.4.10).  Measured, not recited, in tb_shift:
//     -1000 * 358 came back through `>> 10` as +16034 where -350 was due.
//     Both shifts here were `>>` until 2026-09-21, so every negative sample
//     of OKI1, and then of the whole mix, became a large positive one and
//     clamped at +32767.  Half of every waveform.  (DEBUG_LOG D20.)
//
//  2. THE x16 IS THE OUTPUT LEVEL.  jt6295's `sound` bus is 14 bits in which
//     one voice at attenuation 0 reaches 2048.  MAME's chip stream is a
//     float in which that same voice reaches 1.0 -- full scale, 32768 in a
//     16-bit output.  Feeding the bus straight to AUDIO_L left the board
//     24 dB quieter than the emulator it is judged against with no fault
//     anywhere in the chip.  Measured over the game's own command stream
//     (tools/oki_mix.py vs MAME's -wavwrite): rms 196 against MAME's 3078.
//     The volume multiply and the level are ONE shift, `>>> 4`, so the four
//     bits the level needs are never thrown away first.
//
//  Routing is hvysmsh.cpp:380,383 -- OKI0 at 1.0 and OKI1 at 0.35 into one
//  mono speaker; 358/1024 = 0.3496.
//
//  MAME's ratio is used DIRECTLY, and that is a result rather than an
//  assumption.  The two chips run at different sample rates, so they do not
//  reach this mixer equally: reconstruction costs each of them a different
//  amount of in-band level, and with the plain two-pole filter that stood
//  here for one build the scalar each needed to sit on MAME's own level was
//  1.051 and 1.002 -- OKI0 arriving 5 % quiet against OKI1, which is exactly
//  what was reported from the cabinet as the channels having different
//  volumes.  Correcting it HERE would have been fitting the mixer to a fault
//  in the reconstruction.  hs_snd_lerp's pre-emphasis removes the cause
//  (the scalars become 0.988 and 0.999), so this line carries hvysmsh.cpp's
//  number and nothing else.
//  The volume port scales BOTH chips,
//  0x00 max to 0xff min (:123-132), MAME's own "TODO: assumes linear", which
//  makes this line EMULATION_DERIVED.  MAME divides by 255 and this divides
//  by 256: 0.4 % at full volume, none at silence, and 256 is a shift.
//  TODO(HARDWAREIZE): the real DE-0385-2 attenuator -- a resistor ladder on
//  the port, or something in the amp?
//============================================================================
`default_nettype none

module hs_snd_mix (
    input  wire signed [15:0] s0,      // OKI0, after hs_snd_lerp
    input  wire signed [15:0] s1,      // OKI1, after hs_snd_lerp
    input  wire        [ 7:0] vol,     // the 0x120000 port, 0 = loudest
    output wire signed [15:0] snd
);
    wire signed [23:0] s0w = s0;       // sign-extended by the assignment
    wire signed [23:0] s1w = s1;
    wire signed [23:0] s1g = (s1w * 24'sd358) >>> 10;
    wire signed [23:0] mix = s0w + s1g;
    wire signed [ 8:0] vg  = $signed({1'b0, 8'hFF - vol});
    wire signed [31:0] scaled = mix * vg;          // 32-bit context: both
    // x19/256, not x16.  The reconstruction filter in hs_snd.sv removes the
    // image energy that used to pad the level, so the old gain came out 16 %
    // quiet.  19 is where the rms lands back on MAME's.  Measured over
    // 16-24 s of a played match against MAME's own -wavwrite, filter in:
    //
    //     gain   rms    MAME/ours   peak    clipped
    //       16   2979     1.186    21231       0
    //       19   3538     0.999    25211       0   <- MAME rms 3533, peak 26118
    //       20   3724     0.949    26538       0
    wire signed [31:0] gained = (scaled * 32'sd19) >>> 8;  // operands sign-extend

    assign snd = (gained >  32'sd32767) ?  16'sd32767 :
                 (gained < -32'sd32768) ? -16'sd32768 : gained[15:0];
endmodule

`default_nettype wire
