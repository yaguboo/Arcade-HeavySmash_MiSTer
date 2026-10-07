//============================================================================
//  Heavy Smash -- shared dual-port RAM wrappers.
//
//  Plain inferred M10K blocks; port A is the CPU side (read+write), port B
//  the render side (read only).  Both ports are on the same clock.
//============================================================================
`default_nettype none

module hs_dpram16 #(parameter int AW = 12) (
    input  wire        clk,
    input  wire [AW-1:0] a_addr,
    input  wire        a_we,
    input  wire [15:0] a_wdata,
    output reg  [15:0] a_q,
    input  wire [AW-1:0] b_addr,
    output reg  [15:0] b_q
);
    reg [15:0] ram [0:(1<<AW)-1] /* synthesis ramstyle = "no_rw_check" */;
    always @(posedge clk) begin
        if (a_we) ram[a_addr] <= a_wdata;
        a_q <= ram[a_addr];
    end
    always @(posedge clk) b_q <= ram[b_addr];
endmodule

module hs_palram (
    input  wire        clk,
    input  wire [9:0]  a_addr,
    input  wire        a_we,
    input  wire [31:0] a_wdata,
    output reg  [31:0] a_q,
    input  wire [9:0]  b_addr,
    output reg  [31:0] b_q
);
    reg [31:0] ram [0:1023] /* synthesis ramstyle = "no_rw_check" */;
    always @(posedge clk) begin
        if (a_we) ram[a_addr] <= a_wdata;
        a_q <= ram[a_addr];
    end
    always @(posedge clk) b_q <= ram[b_addr];
endmodule

`default_nettype wire
