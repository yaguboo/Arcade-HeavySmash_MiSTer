//============================================================================
//  Heavy Smash -- ROM integrity probe (bring-up diagnostic, board-only).
//
//  Phase 1 -- eight fixed addresses (probe_ok bit i, yellow cells), the
//      four 256 KB quarters and a 64 KB-in sample of each.
//  Phase 2 -- the WHOLE ROM: accumulate a 32-bit sum of every decoded
//      dword through the identical live-decode path the CPU uses.  A sum
//      is a deterministic fingerprint of all 262144 dwords: equal to
//      tools/check_rom.py's model sum means every dword is exactly right
//      (an 8-point sample cannot say that); a difference means dwords
//      outside the sample are corrupt.  sum goes on overlay rows 2/3.
//
//  When both phases finish the FSM idles and releases the CPU (cpu_hold
//  drops), so a plain .mra load self-tests then boots, headless.
//
//  History of the probe's own bugs, all fixed before its result was
//  trusted (DEBUG_LOG D2/D3): [17:0] address truncation; a wrapper that
//  never wired the response path; enable mechanisms that never reached
//  status on hardware; running before the download wrote a byte; a stale
//  romarb ok-latch from the pre-download run feeding phase 1's first
//  fetch.  Do not re-add any of these.
//============================================================================
`default_nettype none

module hs_romprobe (
    input  wire        clk,
    input  wire        rst,

    input  wire        probe_en,
    output reg         cpu_hold = 1'b0,

    output wire        rom_cs,
    output wire [18:0] rom_addr,
    input  wire [15:0] rom_data,
    input  wire        rom_ok,

    output reg  [7:0]  probe_ok = 8'd0,
    output wire        probe_done,
    output wire [2:0]  dbg_st,
    output wire [2:0]  dbg_idx,
    output reg  [15:0] dbg_sum_lo = 16'd0,
    output reg  [15:0] dbg_sum_hi = 16'd0
);
    localparam N = 8;

    localparam S_REQ_LO = 3'd0, S_LAT_LO = 3'd1,
               S_REQ_HI = 3'd2, S_LAT_HI = 3'd3,
               S_CHECK = 3'd4, S_IDLE = 3'd5,
               F_REQ = 3'd6, F_LAT = 3'd7;

    reg [2:0]  st = S_REQ_LO;
    reg [2:0]  idx = 3'd0;
    reg        p2 = 1'b0;            // phase 2 in flight
    reg        f_hi = 1'b0;          // which half of the dword is in flight
    reg [17:0] f_a = 18'd0;          // phase-2 dword index
    reg [31:0] f_sum = 32'd0;
    reg [15:0] lo_w = 16'd0;
    reg [15:0] hi_w = 16'd0;

    function automatic [19:0] probe_byte(input [2:0] i);
        probe_byte = (i == 0) ? 20'h00000 :
                      (i == 1) ? 20'h40000 :
                      (i == 2) ? 20'h80000 :
                      (i == 3) ? 20'hC0000 :
                      (i == 4) ? 20'h10000 :
                      (i == 5) ? 20'h50000 :
                      (i == 6) ? 20'h90000 :
                                 20'hD0000 ;
    endfunction

    function automatic [31:0] probe_exp(input [2:0] i);
        probe_exp = (i == 0) ? 32'hEA00000D :
                    (i == 1) ? 32'h26F8E575 :
                    (i == 2) ? 32'h00000000 :
                    (i == 3) ? 32'h83849413 :
                    (i == 4) ? 32'hE59F0624 :
                    (i == 5) ? 32'hFE20FFAC :
                    (i == 6) ? 32'hE05FE812 :
                               32'h00000400 ;
    endfunction

    // DE156 decode of the fetched pair; `a` is the dword index decoded this
    // cycle.  rom_dec is valid only when lo_w/hi_w both hold the CURRENT
    // dword -- the FSM guarantees that at every S_CHECK entry.
    // Phase 1 fetches AND checks the eight fixed addresses, so d_idx must
    // be the probe address in EVERY phase-1 state.  The first phase-2 cut
    // (1ee74d9) selected it only in S_CHECK: the REQ/LAT states then
    // addressed f_a (= 0) and idx 1..7 all fetched dword 0 -- the board's
    // row1 read 0x01 from probe23 on (only idx 0 "matches") while the
    // whole-ROM sum, which uses f_a properly, was exact.
    wire [17:0] d_idx = !p2 ? (probe_byte(idx) >> 2) : f_a;
    wire [17:0] phys;
    hs_de156_addr u_pa (.a(d_idx), .p(phys));
    wire [15:0] lo_le = {lo_w[7:0], lo_w[15:8]};
    wire [15:0] hi_le = {hi_w[7:0], hi_w[15:8]};
    wire [31:0] rom_dec;
    hs_de156_data u_pd (.a(d_idx), .raw({hi_le, lo_le}), .dec(rom_dec));

    wire [31:0] f_next = f_sum + rom_dec;

    assign rom_cs = probe_en & (st != S_IDLE);
    assign rom_addr = ((st == S_REQ_HI || st == S_LAT_HI) ||
                       (p2 && f_hi)) ? {phys, 1'b1} : {phys, 1'b0};
    assign probe_done = (st == S_IDLE);
    assign dbg_st  = st;
    assign dbg_idx = idx;

    always @(posedge clk) begin
        cpu_hold <= probe_en && (st != S_IDLE);
        if (rst) begin
            st <= S_REQ_LO; idx <= 3'd0; probe_ok <= 8'd0;
            p2 <= 1'b0; f_hi <= 1'b0; f_a <= 18'd0; f_sum <= 32'd0;
        end else if (probe_en) begin
            case (st)
            // ---------------- phase 1: eight fixed addresses ------------
            S_REQ_LO: if (rom_ok) st <= S_LAT_LO;
            S_LAT_LO: begin lo_w <= rom_data; st <= S_REQ_HI; end
            S_REQ_HI: if (rom_ok) st <= S_LAT_HI;
            S_LAT_HI: begin hi_w <= rom_data; st <= S_CHECK; end
            S_CHECK: if (!p2) begin
                if (rom_dec === probe_exp(idx)) probe_ok[idx] <= 1'b1;
                else                            probe_ok[idx] <= 1'b0;
                if (idx == N-1) begin
                    st <= F_REQ; p2 <= 1'b1;
                    f_a <= 18'd0; f_hi <= 1'b0; f_sum <= 32'd0;
                end else begin idx <= idx + 3'd1; st <= S_REQ_LO; end
            end else begin
                // phase 2: lo_w/hi_w hold dword f_a, rom_dec is valid
                f_sum <= f_next;
                if (f_a == 18'h3FFFF) begin
                    dbg_sum_lo <= f_next[15:0];
                    dbg_sum_hi <= f_next[31:16];
                    st <= S_IDLE;
                end else begin
                    f_a <= f_a + 18'd1; f_hi <= 1'b0; st <= F_REQ;
                end
            end

            // ---------------- phase 2: whole-ROM sum --------------------
            // The romarb response is registered at the ok edge (data valid
            // ok+1): wait ok, latch one clock later, same handshake the
            // CPU path uses.  After the hi half lands in hi_w, go round
            // through S_CHECK (p2) so rom_dec sees BOTH fresh halves.
            F_REQ: if (rom_ok) st <= F_LAT;
            F_LAT: begin
                if (!f_hi) begin lo_w <= rom_data; f_hi <= 1'b1; st <= F_REQ; end
                else       begin hi_w <= rom_data; st <= S_CHECK; end
            end

            S_IDLE: ;   // results stay until probe_en drops
            default: st <= S_REQ_LO;
            endcase
        end else begin
            st <= S_REQ_LO; idx <= 3'd0;
        end
    end

endmodule

`default_nettype wire
