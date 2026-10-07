//============================================================================
//  Heavy Smash -- ROM arbiter (pattern from stadium_hero sh_romarb.sv, which
//  is simulated and running on hardware).
//
//  Five readers + download, one 16-bit memory port, every fetch one word.
//  Priority is by DEADLINE: the tile and sprite fetchers have a hard
//  per-line budget (~6300 clocks at 100 MHz), the ARM stalls on
//  gb_bus_done and only loses cycles, and the two M6295s are the most
//  patient readers on the board (one byte per 132 chip clocks).
//
//  The address each reader asked for is latched when its fetch starts and
//  `ok` is the AND of "fetch completed" and "address still matches" --
//  sh_romarb.sv:27-40 documents why that qualification exists.
//
//  ONE always block owns sel, the latches, the done flags, the captured
//  data and the memory port (the multiple-driver race that split blocks
//  caused in stadium_hero is documented at sh_romarb.sv:167-176).
//============================================================================
`default_nettype none

module hs_romarb (
    input  wire        clk,
    input  wire        rst,

    // --- neutral memory port --------------------------------------------------
    output reg  [24:0] mem_addr,
    output wire [15:0] mem_din,
    input  wire [15:0] mem_dout,
    output reg         mem_req,
    output wire        mem_we,
    output wire [1:0]  mem_ds,
    input  wire        mem_ack,

    // --- download -----------------------------------------------------------------
    input  wire        dl_active,
    input  wire [24:0] dl_addr,       // word address
    input  wire [15:0] dl_data,
    input  wire        dl_req,
    output wire        dl_ack,

    // --- CPU program ROM (hs_bus) ---------------------------------------------------
    input  wire        cpu_cs,
    input  wire [18:0] cpu_addr,
    output reg  [15:0] cpu_data,
    output wire        cpu_ok,

    // --- tile ROM (hs_deco141) --------------------------------------------------------
    input  wire        tile_cs,
    input  wire [21:0] tile_addr,
    output reg  [15:0] tile_data,
    output wire        tile_ok,

    // --- sprite ROM (hs_decospr) --------------------------------------------------------
    input  wire        spr_cs,
    input  wire [22:0] spr_addr,
    output reg  [15:0] spr_data,
    output wire        spr_ok,

    // --- OKI sample ROMs -------------------------------------------------------------------
    input  wire        oki0_cs,
    input  wire [22:0] oki0_addr,
    output reg  [15:0] oki0_data,
    output wire        oki0_ok,

    input  wire        oki1_cs,
    input  wire [22:0] oki1_addr,
    output reg  [15:0] oki1_data,
    output wire        oki1_ok,

    // bring-up: probe10 froze at S_REQ_LO/idx0 -- the probe never saw cpu_ok.
    // These let one screenshot say WHICH handshake stalled: dl_active held,
    // arbitration never leaving a video client (sel), or mem_ack missing.
    output wire        dbg_dl_active,
    output wire [2:0]  dbg_sel,
    output wire        dbg_mem_req,
    output wire        dbg_mem_ack
);

    assign mem_we  = dl_active & dl_req;
    assign mem_din = dl_data;
    assign mem_ds  = 2'b11;
    assign dl_ack  = dl_active & mem_ack;

    localparam [2:0] SEL_NONE = 3'd0, SEL_TILE = 3'd1, SEL_SPR = 3'd2,
                     SEL_CPU  = 3'd3, SEL_O0   = 3'd4, SEL_O1  = 3'd5;

    reg [2:0] sel;
    reg       vid_turn;      // tile/spr round-robin pointer

    reg [18:0] cpu_lat;  reg cpu_done;
    reg [21:0] tile_lat; reg tile_done;
    reg [22:0] spr_lat;  reg spr_done;
    reg [22:0] o0_lat;   reg o0_done;
    reg [22:0] o1_lat;   reg o1_done;

    assign cpu_ok  = cpu_done  & (cpu_lat  == cpu_addr);
    assign tile_ok = tile_done & (tile_lat == tile_addr);
    assign spr_ok  = spr_done  & (spr_lat  == spr_addr);
    assign oki0_ok = o0_done   & (o0_lat   == oki0_addr);
    assign oki1_ok = o1_done   & (o1_lat   == oki1_addr);

    wire tile_pend = tile_cs & ~tile_ok;
    wire spr_pend  = spr_cs  & ~spr_ok;
    wire cpu_pend  = cpu_cs  & ~cpu_ok;
    wire o0_pend   = oki0_cs & ~oki0_ok;
    wire o1_pend   = oki1_cs & ~oki1_ok;

    always @(posedge clk) begin
        if (rst) begin
            sel <= SEL_NONE; vid_turn <= 1'b0;
            mem_req <= 1'b0; mem_addr <= 25'd0;
            cpu_done <= 1'b0; tile_done <= 1'b0; spr_done <= 1'b0;
            o0_done  <= 1'b0; o1_done  <= 1'b0;
        end else if (dl_active) begin
            sel      <= SEL_NONE;
            mem_req  <= dl_req;
            mem_addr <= dl_addr;
            // a download invalidates every client result: the *_done latches
            // still hold pre-download reads, and *_ok = done & (lat == addr)
            // would hand a stale word to the first request afterwards.  The
            // ROM probe's FIRST fetch caught exactly this -- idx0 read the
            // pre-download 0x0000 while idx1-7, whose addresses differ from
            // the stale latch, fetched real data (probe19/20, 7/8).
            cpu_done  <= 1'b0; tile_done <= 1'b0; spr_done <= 1'b0;
            o0_done   <= 1'b0; o1_done   <= 1'b0;
        end else if (sel == SEL_NONE) begin
            // video first, round-robin so neither starves
            if (tile_pend && (!spr_pend || vid_turn == 1'b0)) begin
                sel <= SEL_TILE; tile_lat <= tile_addr; tile_done <= 1'b0;
                mem_req <= 1'b1; mem_addr <= {3'd0, tile_addr};
                vid_turn <= 1'b1;
            end else if (spr_pend) begin
                sel <= SEL_SPR; spr_lat <= spr_addr; spr_done <= 1'b0;
                mem_req <= 1'b1; mem_addr <= {2'd0, spr_addr};
                vid_turn <= 1'b0;
            end else if (cpu_pend) begin
                sel <= SEL_CPU; cpu_lat <= cpu_addr; cpu_done <= 1'b0;
                mem_req <= 1'b1; mem_addr <= {6'd0, cpu_addr};
            end else if (o0_pend) begin
                sel <= SEL_O0; o0_lat <= oki0_addr; o0_done <= 1'b0;
                mem_req <= 1'b1; mem_addr <= {2'd0, oki0_addr};
            end else if (o1_pend) begin
                sel <= SEL_O1; o1_lat <= oki1_addr; o1_done <= 1'b0;
                mem_req <= 1'b1; mem_addr <= {2'd0, oki1_addr};
            end else begin
                mem_req <= 1'b0;
            end
        end else if (mem_req && mem_ack) begin
            // deliver
            case (sel)
            SEL_TILE: begin tile_data <= mem_dout; tile_done <= 1'b1; end
            SEL_SPR:  begin spr_data  <= mem_dout; spr_done  <= 1'b1; end
            SEL_CPU:  begin cpu_data <= mem_dout; cpu_done  <= 1'b1; end
            SEL_O0:   begin oki0_data <= mem_dout; o0_done  <= 1'b1; end
            SEL_O1:   begin oki1_data <= mem_dout; o1_done  <= 1'b1; end
            default: ;
            endcase
            sel      <= SEL_NONE;
            mem_req  <= 1'b0;
        end
    end

    assign dbg_dl_active = dl_active;
    assign dbg_sel       = sel;
    assign dbg_mem_req   = mem_req;
    assign dbg_mem_ack   = mem_ack;

endmodule

`default_nettype wire
