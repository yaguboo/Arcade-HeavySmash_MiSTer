//============================================================================
//  Heavy Smash -- video timing and line composition.
//
//  320x240 visible inside a 396x272 frame at 6.25 MHz pixel clock
//  (100 MHz / 16) = 58.05 Hz refresh (MAME: 58 Hz, PCB note :467).
//  MAME visarea is (0..319, 8..247); visible line = vcount - 8.
//
//  While line L scans out, L+1 is being prefetched into the other half of
//  every line buffer.  line_go fires at the start of the line BEFORE each
//  visible line (vcount 7..246), handing the renderers y = vcount+1-8 and
//  the write-select = y parity.
//
//  Composition order (hvysmsh.cpp:104-118): PF2 opaque, sprites, PF1
//  transparent.  Index 0 in a buffer means transparent (pen 0 writes as 0).
//============================================================================
`default_nettype none

module hs_video (
    input  wire        clk,
    input  wire        rst,
    input  wire        cen_pix,

    // --- renderer read ports ---------------------------------------------------
    output wire [8:0]  rd_x,
    output wire        rd_sel,           // read half (opposite of write half)
    input  wire [9:0]  q_pf1, q_pf2, q_spr,

    // --- renderer handshake -----------------------------------------------------
    output reg         line_go = 1'b0,
    output reg  [8:0]  line_y  = 9'd0,
    output wire        buf_sel,
    input  wire        tile_done, spr_done,

    // --- palette read -------------------------------------------------------------
    output reg  [9:0]  pal_a = 10'd0,
    input  wire [31:0] pal_q,

    // --- out --------------------------------------------------------------------
    output reg  [7:0]  red = 8'd0, green = 8'd0, blue = 8'd0,
    output wire        hsync, vsync, hblank, vblank,
    output wire        ce_pix,
    output reg         frame_odd = 1'b0,
    output wire        irq
);

    localparam HTOTAL = 396, VTOTAL = 272;

    reg [8:0] hcount = 9'd0;
    reg [8:0] vcount = 9'd0;

    always @(posedge clk) begin
        if (cen_pix) begin
            if (hcount == HTOTAL-1) begin
                hcount <= 9'd0;
                if (vcount == VTOTAL-1) begin
                    vcount    <= 9'd0;
                    frame_odd <= ~frame_odd;
                end else vcount <= vcount + 9'd1;
            end else hcount <= hcount + 9'd1;
        end
    end

    wire visible   = (hcount < 9'd320) && (vcount >= 9'd8) && (vcount < 9'd248);
    wire [8:0] vis_line = vcount - 9'd8;           // 0..239 when visible
    wire hb_raw    = (hcount >= 9'd320);
    wire vb_raw    = (vcount >= 9'd248) || (vcount < 9'd8);
    wire hs_raw    = (hcount >= 9'd328) && (hcount < 9'd376);
    wire vs_raw    = (vcount >= 9'd252) && (vcount < 9'd260);
    assign ce_pix  = cen_pix;

    // ---- the blanking leaves this module in phase with the pixels ----------
    // Composition costs two pixel periods: the line buffer is a registered
    // read, pal_a is sampled from it at cen_pix, the palette is another
    // registered read and the output stage is one cen behind that.  The
    // blanking used to be combinational from hcount, so the consumer framed
    // the picture two pixels before the pixels arrived -- the whole image sat
    // one to two pixels inside its own window, and the first columns of every
    // line carried whatever the buffer held outside 0..319.  Delaying the
    // blanking by exactly the composition's own latency puts them back
    // together and lets rd_x be the plain hcount, so the read never has to
    // reach across a line boundary into the other buffer half.
    reg [1:0] hb_p = 2'b11, vb_p = 2'b11, hs_p = 2'd0, vs_p = 2'd0, vis_p = 2'd0;
    always @(posedge clk) if (cen_pix) begin
        hb_p  <= {hb_p[0],  hb_raw};
        vb_p  <= {vb_p[0],  vb_raw};
        hs_p  <= {hs_p[0],  hs_raw};
        vs_p  <= {vs_p[0],  vs_raw};
        vis_p <= {vis_p[0], visible};
    end
    assign hblank = hb_p[1];
    assign vblank = vb_p[1];
    assign hsync  = hs_p[1];
    assign vsync  = vs_p[1];

    // IRQ: HOLD for the first 8 lines of blanking (~2 x MAME's 529 us, safe
    // side), CLEAR at vcount 256 (hvysmsh.cpp:318-321 vblank_interrupt).
    assign irq = (vcount >= 9'd248) && (vcount < 9'd256);

    // ---- prefetch trigger: start of the line preceding visible line L -------
    // vcount 7 -> render y=8 ... vcount 246 -> render y=247
    //
    // line_y is the BITMAP row, not the visible row.  MAME's screen is
    // 320x256 with set_visarea(0, 319, 8, 247) (hvysmsh.cpp:350-353): the
    // tilemap and the sprites are drawn into that 256-line bitmap and only
    // rows 8..247 are shown, so the first visible line reads tilemap row
    // 8 + scrolly, not scrolly.  Handing the renderers 0..239 put the whole
    // picture 8 lines down; a (dx,dy) alignment search against MAME's own
    // frame picked dy=-8 at every dx (77.2% at dx=-16 vs 69.1% at 0,0).
    // 8 is even, so the buffer parity below is unchanged.
    wire do_go = cen_pix && (hcount == 9'd0)
              && (vcount >= 9'd7) && (vcount <= 9'd246);
    wire [8:0] go_y = vcount + 9'd1;

    always @(posedge clk) begin
        line_go <= do_go;
        if (do_go) line_y <= go_y;
    end

    assign buf_sel = line_y[0];       // renderers write the half of their y
    // Scanout reads the half that was FILLED during the previous line, which
    // is the parity of this line's own y: line L is prefetched at vcount L+7
    // with line_y = L into half L[0], and while L scans out the renderers are
    // filling half (L+1)[0] for the next one.  This read `~vis_line[0]` --
    // the half being written right now -- so every visible line showed a
    // partially rendered buffer (sim/tb_frame.sv: alternating broken lines).
    assign rd_sel  = vis_line[0];

    // ---- line-buffer read address --------------------------------------------
    // THIS WAS MISSING.  rd_x was declared as an output of this module and
    // never assigned, so every line buffer was read at x=0 for a whole line
    // and each scanline came out one flat colour -- the horizontal stripes on
    // the board (D13/D14) and in sim/tb_frame.sv.  Nothing caught it: the
    // wrapper port check only sees instantiation, and root tools/verilate.sh
    // does not lint UNDRIVEN (shadow_force's copy does -- root CLAUDE.md 13).
    //
    // No lookahead: the two pixel periods the composition costs are paid by
    // the blanking pipeline above instead.  A lookahead here would have to
    // reach past hcount 319 into the next line, whose buffer half is the
    // other one, and the first columns would come from the wrong line.
    assign rd_x = hcount;

    // ---- composition ----------------------------------------------------------
    // PF2 is opaque, so it is the floor and never a hole; PF1 and the sprites
    // use index 0 in their buffers to mean transparent.
    always @(posedge clk) begin
        if (cen_pix) begin
            pal_a <= (q_pf1 != 0) ? q_pf1 :
                     (q_spr != 0) ? q_spr : q_pf2;
        end
    end
    // palette read is one clk behind the index; pixel follows by one cen.
    reg cen_d;
    always @(posedge clk) begin
        cen_d <= cen_pix;
        if (cen_d) begin
            red   <= vis_p[1] ? pal_q[7:0]   : 8'd0;
            green <= vis_p[1] ? pal_q[15:8]  : 8'd0;
            blue  <= vis_p[1] ? pal_q[23:16] : 8'd0;
        end
    end

endmodule

`default_nettype wire
