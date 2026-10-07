//============================================================================
//  Heavy Smash -- memory front end for the Amber a23 core.
//
//  Drop-in replacement for the vendored `a23_fetch` (which is a cache + a
//  Wishbone master).  Same job, same core-facing signals; the board side is
//  hs_bus's request/done protocol instead of Wishbone.
//
//  WHY REPLACE IT, and not adapt Wishbone (measured, not assumed).
//  a23_wishbone re-registers its address whenever `start_access` is true, and
//  that is true ON THE ACK CLOCK (`wb_wait = stb && !ack` is 0 there).  The
//  core advances on that same clock, so the address it latches is the one the
//  core is LEAVING: after the ack, stb stays high with the previous address
//  and the FSM cannot move on (start_access is blocked by wb_wait) until that
//  stale request is acked too.  Acking it performs the access twice -- the
//  bench caught it on the second store of the boot: MAME writes 0x180000 then
//  0x120000, Amber-over-Wishbone wrote 0x180000 twice
//  (sim/tb_amber_boot.sv, DEBUG_LOG D12).
//
//  Here the core's own address is the request, so there is nothing to go
//  stale: exactly one hs_bus transaction per address the core presents, and
//  the core cannot present the next one until we drop o_fetch_stall.
//
//  The DE156 is an ARM2 -- no cache on the real chip -- so nothing is lost by
//  dropping Amber's.  When fetch bandwidth becomes the limit (every fetch is
//  two 16-bit SDRAM reads), the prefetch buffer belongs HERE, where we can
//  keep it out of the IO windows.
//============================================================================
`default_nettype none

module hs_a23_mem (
    input  wire        i_clk,
    input  wire        i_reset,

    // ---- core side (a23_fetch's port list, minus the cache/wishbone bits)
    input  wire [31:0] i_address,
    input  wire        i_address_valid,
    input  wire [31:0] i_write_data,
    input  wire        i_write_enable,
    output wire [31:0] o_read_data,
    input  wire [3:0]  i_byte_enable,
    input  wire        i_data_access,      // 1 = data, 0 = instruction fetch
    input  wire        i_system_rdy,       // our cen: the ARM's own rate
    output wire        o_fetch_abort,
    output wire        o_fetch_stall,

    // ---- board side (hs_bus)
    output wire [31:0] bus_adr,
    output wire        bus_rnw,
    output reg         bus_ena = 1'b0,
    output wire [1:0]  bus_acc,            // 00 byte, 01 half, 10 word
    output wire [31:0] bus_dout,
    input  wire [31:0] bus_din,
    input  wire        bus_done
);

    assign o_fetch_abort = 1'b0;

    // Amber replicates a byte write over all four lanes (a23_execute.v:395)
    // and always reads whole words (it extracts the byte itself), so the
    // access size comes from the byte enables on writes only.
    wire [1:0] acc_w = (i_byte_enable == 4'b1111)                           ? 2'b10 :
                       (i_byte_enable == 4'b0011 || i_byte_enable == 4'b1100) ? 2'b01 :
                                                                                2'b00;

    // ---------------------------------------------------------------- icache
    // An instruction cache the DE156 does not have, and the measurement that
    // says to build one anyway.
    //
    // D22: the CPU owns 71 % of this board's memory words, 99.8 % of them are
    // instruction fetches, and it sits with an unfinished request on 64.6 % of
    // all clocks -- 3.0 MIPS where 25 MHz should give far more.  Amber shipped
    // with a cache and this file's header says dropping it lost nothing,
    // because the real ARM2 has none.  That was true about the chip and wrong
    // about this board, where the ROM is behind a shared 16-bit SDRAM instead
    // of the PCB's own 32-bit mask ROMs.
    //
    // tools/icache.lua ran the game's real fetch stream (25.1 M fetches over
    // 120 frames of a played match) through cache models.  It touches only
    // 2267 distinct 16-byte lines -- 36 KB of a 1 MB program -- so:
    //
    //     line  size    hit %      miss cost
    //      4 B  8 KB   99.906     2 words  (what a fetch costs today)
    //     16 B  4 KB   99.934     8 words
    //
    // A one-dword line wins on the product: 0.094 x 2 against 0.066 x 8, and
    // it leaves the bus protocol untouched because a miss fetches exactly the
    // two 16-bit words the CPU was going to ask for anyway.
    //
    // ACCURACY: this is NOT on the PCB.  It changes timing only -- the program
    // ROM is read-only, so no invalidation exists to get wrong, and the data
    // returned is the same in every case.  Purity is unaffected (PURE_RTL, the
    // work happens in the FPGA).  This board's ARM already runs at 25 MHz
    // against the PCB's 28, so its timing was never the hardware's.
    localparam IDX_W = 11;                       // 2048 dwords = 8 KB
    localparam TAG_W = 20 - 2 - IDX_W;           // program ROM is 1 MB

    wire        c_able = ~i_data_access && (i_address[31:20] == 12'd0);
    wire [IDX_W-1:0] c_idx = i_address[IDX_W+1:2];
    wire [TAG_W-1:0] c_tag = i_address[19:IDX_W+2];

    // Synchronous reads so these infer M10K.  A combinational read here would
    // become 2048 registers without a warning -- the fault that cost Power
    // Spikes 7,673 ALMs (root CLAUDE.md 7).
    (* ramstyle = "M10K" *) reg [31:0]     c_data [0:(1<<IDX_W)-1];
    (* ramstyle = "M10K" *) reg [TAG_W:0]  c_tagv [0:(1<<IDX_W)-1];   // {valid, tag}
    reg [31:0]    c_dq;
    reg [TAG_W:0] c_tq;
    reg [IDX_W-1:0] c_wipe = {IDX_W{1'b0}};
    reg           c_clearing = 1'b1;

    // Clear on reset rather than trusting power-up contents or a generation
    // tag: a finite counter always comes back around, and the ROM can be
    // downloaded again under a running core.  2048 clocks, while the CPU is
    // held in reset anyway.
    always @(posedge i_clk) begin
        if (i_reset) begin
            c_clearing <= 1'b1;
            c_wipe     <= {IDX_W{1'b0}};
        end else if (c_clearing) begin
            c_tagv[c_wipe] <= {(TAG_W+1){1'b0}};
            c_wipe         <= c_wipe + 1'b1;
            if (&c_wipe) c_clearing <= 1'b0;
        end else if (fill_now) begin
            c_data[adr_idx] <= bus_din;
            c_tagv[adr_idx] <= {1'b1, adr_tag};
        end
    end

    always @(posedge i_clk) begin
        c_dq <= c_data[c_idx];
        c_tq <= c_tagv[c_idx];
    end

    reg [IDX_W-1:0] adr_idx;
    reg [TAG_W-1:0] adr_tag;
    reg             adr_able;
    wire            c_hit = adr_able && c_tq[TAG_W] && (c_tq[TAG_W-1:0] == adr_tag);
    wire            fill_now = (st == S_WAIT) && bus_done && adr_able;

    localparam S_REQ = 2'd0, S_WAIT = 2'd1, S_READY = 2'd2,
               S_LOOK = 2'd3;
    reg [1:0]  st = S_REQ;
    reg [31:0] adr_r = 32'd0, dat_r = 32'd0, rdata_r = 32'd0;
    reg [1:0]  acc_r = 2'b10;
    reg        we_r  = 1'b0;

    assign bus_adr  = adr_r;
    assign bus_dout = dat_r;
    assign bus_acc  = acc_r;
    assign bus_rnw  = ~we_r;

    // The core samples read data on the clock it advances, which is the one
    // clock we hold o_fetch_stall low -- rdata_r is stable across it.
    assign o_read_data = rdata_r;

    // Stall unless we are handing over a completed access this clock.  With
    // no access pending the core still only advances on cen, which is what
    // keeps the ARM at its own rate rather than the system clock's.
    assign o_fetch_stall = !(( st == S_READY || !i_address_valid) && i_system_rdy);

    always @(posedge i_clk) begin
        bus_ena <= 1'b0;
        if (i_reset) begin
            st <= S_REQ; bus_ena <= 1'b0; adr_able <= 1'b0;
            adr_r <= 32'd0; dat_r <= 32'd0; acc_r <= 2'b10; we_r <= 1'b0;
            rdata_r <= 32'd0;
        end else begin
            case (st)
            S_REQ:
                if (i_address_valid) begin
                    adr_r    <= i_address;
                    dat_r    <= i_write_data;
                    we_r     <= i_write_enable;
                    acc_r    <= i_write_enable ? acc_w : 2'b10;
                    // c_dq/c_tq are being read this clock for c_idx;
                    // hold what they will have to be compared against.
                    adr_idx  <= c_idx;
                    adr_tag  <= c_tag;
                    adr_able <= c_able && !i_write_enable && !c_clearing;
                    st       <= S_LOOK;
                end
            S_LOOK:
                // One clock later the tag is out of the RAM.  A hit
                // never touches the bus; a miss costs exactly what
                // every fetch cost before the cache existed.
                if (c_hit) begin
                    rdata_r <= c_dq;
                    st      <= S_READY;
                end else begin
                    bus_ena <= 1'b1;
                    st      <= S_WAIT;
                end
            S_WAIT:
                if (bus_done) begin
                    rdata_r <= bus_din;
                    st      <= S_READY;
                end
            S_READY:
                // o_fetch_stall is low this clock only while i_system_rdy is
                // high; that is the clock the core takes the data and moves
                // to the next address, so leave only then.
                if (i_system_rdy) st <= S_REQ;
            default: st <= S_REQ;
            endcase
        end
    end

endmodule

`default_nettype wire
