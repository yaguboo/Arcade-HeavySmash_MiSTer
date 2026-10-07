//============================================================================
//  Heavy Smash -- clock enables from the single 100 MHz domain.
//
//  clk 100.000 MHz (GBA_MiSTer's gba_cpu was designed for this clock).
//    cen_arm  /4   = 25.000 MHz  DE156 (28 MHz target; see REUSE_PLAN for
//                                  why 89% is the right bring-up speed)
//    cen_pix /16   =  6.250 MHz  pixel clock; 396 x 272 -> 58.05 Hz
//    cen_oki0/100  =  1.000 MHz  MSM6295 #0 (28/28 on the PCB)
//    cen_oki1/50   =  2.000 MHz  MSM6295 #1 (28/14)
//============================================================================
`default_nettype none

module hs_cen (
    input  wire clk,
    input  wire rst,
    output reg  cen_arm = 1'b0,
    output reg  cen_pix = 1'b0,
    output reg  cen_oki0 = 1'b0,
    output reg  cen_oki1 = 1'b0
);

    // /4 : 3,2,1,0 with 0 as the tick
    reg [1:0] c4 = 2'd0;
    always @(posedge clk) begin
        if (rst) c4 <= 2'd0;
        else     c4 <= c4 + 2'd1;
        cen_arm <= (c4 == 2'd0);
    end

    // /16
    reg [3:0] c16 = 4'd0;
    always @(posedge clk) begin
        if (rst) c16 <= 4'd0;
        else     c16 <= c16 + 4'd1;
        cen_pix <= (c16 == 4'd0);
    end

    // /100 and /50
    reg [6:0] c100 = 7'd0;
    always @(posedge clk) begin
        if (rst) c100 <= 7'd0;
        else     c100 <= (c100 == 7'd99) ? 7'd0 : c100 + 7'd1;
        cen_oki0 <= (c100 == 7'd0);
        cen_oki1 <= (c100 < 7'd2);
    end

endmodule

`default_nettype wire
