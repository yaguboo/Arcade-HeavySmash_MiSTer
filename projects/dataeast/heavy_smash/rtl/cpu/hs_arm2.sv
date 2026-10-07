//============================================================================
//  Heavy Smash -- DE156 CPU: Amber a23 (ARMv2a, 26-bit) + bus adapter.
//
//  WHY THIS CORE.  The DE156 is not an ARM7TDMI.  MAME instantiates it as
//  `de156_cpu_device : arm2_cpu_device` with ARCHFLAG_MODE26 | ARCHFLAG_ONLY26
//  (arm7.h:638, arm7.cpp:2000) and FBNeo runs it on its 26-bit ARM2 core.
//  Heavy Smash's code is 26-bit ARM: R15 carries PC *and* PSR, subroutines
//  return with `MOVS PC,R14` restoring the flags from R14's high bits, and
//  TEQP at 0x104 is what enables IRQs.  docs/DEBUG_LOG.md D11 has the
//  measurements.  Amber is ARMv2a and runs RISC OS on MiSTer hardware inside
//  Archie_MiSTer.
//
//  This module keeps the port list hs_arm.vhd had, so hs_top does not care
//  which CPU is inside.
//
//  ---- the handshake ------------------------------------------------------
//  The core's memory front end (rtl/cpu/hs_a23_mem.sv, which replaces Amber's
//  cache+Wishbone) issues exactly one hs_bus transaction per address the core
//  presents: bus_ena is a ONE-clock pulse (hs_bus re-issues from S_IDLE if it
//  is held -- the phantom-transaction trap in docs/HANDOFF.md), and the core
//  cannot move to the next address until that module drops fetch_stall.
//
//  ---- speed --------------------------------------------------------------
//  Amber fetches every cycle it advances, and every fetch here is two 16-bit
//  SDRAM reads.  The effective instruction rate is therefore set by memory,
//  not by cen -- see docs/DEBUG_LOG.md.  cen is wired anyway (i_system_rdy)
//  so the rate is right once fetch bandwidth is fixed (P8: Amber's own cache,
//  which is in the vendored source and inert today because cacheable_area
//  resets to 0 and only CP15 writes change it -- hvysmsh only talks to p0).
//============================================================================
`default_nettype none

module hs_arm2 (
    input  wire        clk,
    input  wire        rst,
    input  wire        cen,          // ARM rate; gates the core, not the bus
    input  wire        irq,          // level, active high (vblank)

    output wire [31:0] bus_adr,
    output wire        bus_rnw,
    output wire        bus_ena,
    output wire [1:0]  bus_acc,      // 00 byte, 01 half, 10 word
    output wire [31:0] bus_dout,
    input  wire [31:0] bus_din,
    input  wire        bus_done,

    output wire [31:0] dbg_pc,
    output wire [1:0]  dbg_mode
);

    // ---------------------------------------------------------------- Amber
    //
    // The core's memory front end is rtl/cpu/hs_a23_mem.sv (instantiated
    // inside the patched a23_core in place of a23_fetch), so the core already
    // speaks hs_bus's protocol and this module is only the wiring plus the
    // reset/cen/irq plumbing.
    a23_core u_cpu (
        .i_clk        (clk),
        .i_reset      (rst),
        .i_irq        (irq),
        .i_firq       (1'b0),
        .i_system_rdy (cen),
        .o_dbg_pc     (dbg_pc),
        .o_dbg_mode   (dbg_mode),
        .o_bus_adr    (bus_adr),
        .o_bus_rnw    (bus_rnw),
        .o_bus_ena    (bus_ena),
        .o_bus_acc    (bus_acc),
        .o_bus_dout   (bus_dout),
        .i_bus_din    (bus_din),
        .i_bus_done   (bus_done)
    );

endmodule

`default_nettype wire
