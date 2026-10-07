//============================================================================
//  Heavy Smash -- reconstruction for one MSM6295: pre-emphasis + linear hold.
//
//  jt6295 is instantiated INTERPOL(0), so its `sound` bus is a zero-order
//  hold: one value held for a whole sample period.  A ZOH puts its first
//  image only 13 dB down, and on THIS board that matters very unequally,
//  because the two chips do not run at the same rate:
//
//      OKI0  28 MHz/28 = 1.000 MHz  ->  7575.8 Hz   Nyquist 3787.9 Hz
//      OKI1  28 MHz/14 = 2.000 MHz  -> 15151.5 Hz   Nyquist 7575.8 Hz
//
//  Unfiltered, OKI0 carries 5.9 % of its energy as images and OKI1 only
//  0.19 % -- a 30x asymmetry between two chips that are supposed to mix at a
//  fixed ratio.  THAT is what a listener reports as the channels having
//  different volumes from MAME, and it is why this is per chip.
//
//  TWO PARTS, EACH ANSWERING A MEASUREMENT.
//
//  1. Interpolating linearly across the hold makes it a TRIANGULAR hold:
//     sinc^2 instead of sinc, so the first image drops from -13 dB to -26 dB.
//  2. sinc^2 also droops IN band -- -7.8 dB at Nyquist -- and that ate the
//     2-4 kHz band this game's music sits in.  The droop is known, so it is
//     cancelled before the hold by a 3-tap pre-emphasis at the native rate,
//     H(f) = (1+2a) - 2a cos(2 pi f/fs): exactly 1 at DC, 1+4a at Nyquist.
//
//  Measured against MAME's own chip model over 14 s of the game's own
//  command stream (tools/oki_bands.py; error is taken after delay and gain
//  are aligned out, so group delay is not scored as distortion):
//
//                          OKI0                        OKI1
//                    image   keep    err         image   keep    err
//      ZOH           5.942   0.941  27.12 %      0.190   0.998   5.30 %
//      2-pole IIR    1.864   0.909  14.57 %      0.012   0.994   3.44 %
//      lerp          0.620   0.896  14.65 %      0.012   0.996   2.14 %
//      lerp + 1/8    1.274   0.993  12.22 %      0.022   1.001   1.62 %
//
//  The sweep is flat from a=0.094 to a=0.125 (12.25/12.21/12.22 %), so 1/8
//  is chosen for being a shift rather than for being the peak.
//
//  WHY THIS MATTERS BEYOND THE ERROR COLUMN: with the droop cancelled, the
//  scalar each chip needs to sit on MAME's level goes to 0.988 and 0.999.
//  Both chips arrive at the mixer at MAME's own scale, so hs_snd_mix can use
//  hvysmsh.cpp's 0.35 directly instead of a corrected ratio.
//
//  WHY THE STEP IS COUNTED IN cen AND NOT IN clk.  The MSM6295 divides its
//  own clock by 132 with pin 7 high (jt6295_timing.v: base 0..3 x cnt 0..32),
//  so BOTH chips take exactly 132 cen pulses per sample however fast that cen
//  runs.  Stepping on cen uses one constant for both; stepping on clk would
//  need 13200 for one and 6600 for the other.
//
//  A 2-pole IIR stood here for one build on 2026-09-23 and did help, but the
//  images start at 3788 Hz and OKI0's signal also ends at 3788 Hz -- no guard
//  band, so every dB an IIR takes off the images it takes off the music too.
//  This REPLACES it; the sweep also showed lerp followed by an IIR is worse
//  than lerp alone.
//
//  ACCURACY: EMULATION_DERIVED.  This reproduces the reconstruction MAME's
//  resampler performs.  The real DE-0385-2 has an analogue low-pass after
//  each 6295 doing the same job with an unknown corner.
//  TODO(HARDWAREIZE): the RC network on the PCB's 6295 outputs.
//============================================================================
`default_nettype none

module hs_snd_lerp #(
    parameter       F     = 20,        // fractional bits in the accumulator
    parameter [12:0] STEPK = 13'd7943, // round(2^F / 132); 132 cen per sample
    parameter       PRE   = 1          // 0 disables the pre-emphasis
) (
    input  wire               clk,
    input  wire               rst,
    input  wire               cen,     // this chip's cen (1 or 2 MHz)
    input  wire               samp,    // jt6295 `sample` with SAMPLE(1)
    input  wire signed [13:0] din,     // jt6295 `sound`
    output wire signed [15:0] dout
);
    // jt6295_acc registers `sum <= acc` ON cen_sr, so `sound` carries the new
    // value the clock AFTER samp.  Latching on samp itself would ramp towards
    // the previous sample for ever.
    reg samp_d = 1'b0;
    always @(posedge clk) samp_d <= samp;

    // native samples: x0 is the newest held, din is the one arriving
    reg signed [13:0] x0 = 14'sd0, x1 = 14'sd0;

    // pre-emphasis of x0, which needs the sample on EACH side of it -- so it
    // is computed when the next one arrives, and the output is two native
    // samples behind.  264 us on OKI0, and a constant delay is not audible.
    // CONCATENATION IS UNSIGNED AND SELF-SIZED, AND A BIT-SELECT IS UNSIGNED.
    // {x0,3'b0} is 17 bits, so x0*8 wraps at x0 = -8192, and praw[17:3]
    // throws the sign away.  Written that way this module came out 6.7x too
    // loud and clipped flat -- caught by sim/snd.sh, not by the compiler.
    // The same trap is the first note in hs_snd_mix.sv.
    wire signed [17:0] x0m10 = $signed(x0) * 18'sd10;
    wire signed [17:0] praw  = x0m10 - $signed(x1) - $signed(din);
    wire signed [15:0] pnew  = PRE ? (praw >>> 3) : $signed(x0);

    reg signed [15:0]   pcur = 16'sd0;
    reg signed [16:0]   dlt  = 17'sd0;
    reg signed [F+15:0] acc  = {(F+16){1'b0}};
    reg signed [F+15:0] step = {(F+16){1'b0}};

    always @(posedge clk) begin
        if (rst) begin
            x0 <= 14'sd0; x1 <= 14'sd0; pcur <= 16'sd0; dlt <= 17'sd0;
            acc <= {(F+16){1'b0}};
        end else if (samp_d) begin
            x1   <= x0;
            x0   <= din;
            pcur <= pnew;
            dlt  <= pnew - pcur;              // a subtract, and nothing more
            acc  <= {pcur, {F{1'b0}}};        // restart exactly on the last
        end else if (cen) begin
            acc  <= acc + step;
        end
    end

    // THE MULTIPLY GETS A CLOCK TO ITSELF, AND THIS IS NOT TIDINESS.
    // Written as `step <= (pnew - pcur) * STEPK` inside the block above it
    // put x0*10, two subtracts, a shift, another subtract AND a 13-bit
    // constant multiply between two registers -- and `step` is 36 bits in two
    // instances, so 72 registers hang off that one chain.  Quartus reported
    // setup on the 100 MHz clock at slack -7.949 with TNS -428.5, which is
    // ~54 paths missing by nearly the whole period.  The build before it made
    // +1.113 on the same seed.  Not placement: structure.
    //
    // Splitting it is free here.  dlt only changes on samp_d, and the first
    // cen that consumes step is at least 48 clocks later (cen is /50 for OKI1
    // and /100 for OKI0), so step is always settled long before it is used.
    always @(posedge clk) begin
        if (rst) step <= {(F+16){1'b0}};
        else     step <= dlt * $signed({1'b0, STEPK});
    end

    // 132 * 7943 = 1048476 against 2^20 = 1048576: the ramp arrives 0.0095 %
    // short and is then reloaded exactly, so nothing accumulates.
    assign dout = acc[F+15:F];

endmodule

`default_nettype wire
