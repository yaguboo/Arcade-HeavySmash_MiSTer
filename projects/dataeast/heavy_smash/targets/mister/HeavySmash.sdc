derive_pll_clocks
derive_clock_uncertainty

# ---------------------------------------------------------------------------
# SDRAM pins are deliberately unconstrained -- MiSTer practice (see
# stadium_hero StadiumHero.sdc for the full reasoning).  Interface timing is
# set physically: SDRAM_CLK at -5000 ps (180 deg, rtl/pll/pll_0002.v) --
# the phase the controller's read-latch math in hs_sdram.sv was derived
# for.  2026-09-20: the ROM probe read 0/8 at both -5000 and -3000 ps; the
# consistent all-address failure pointed at a systematic error, found in
# the controller (tRCD 15 ns vs 18 required at 100 MHz -- hs_sdram.sv
# S_RCD2).  Phase is NOT the discriminator here; the probe is the judge.
# ---------------------------------------------------------------------------

# Framework video paths (same relaxations as the reference cores)
set_multicycle_path -to {*Hq2x*} -setup 4
set_multicycle_path -to {*Hq2x*} -hold 3
set_multicycle_path -from [get_clocks {*|pll|pll_inst|altera_pll_i|general[0].*|divclk}] -to {ascal|*} -setup 4
set_multicycle_path -from [get_clocks {*|pll|pll_inst|altera_pll_i|general[0].*|divclk}] -to {ascal|*} -hold 3

# ---------------------------------------------------------------------------
# Amber (a23) advances one CPU step every FOUR system clocks, so its
# register-to-register paths have four periods, not one.
#
# The ARM7 multiply exception that used to live here went with gba_cpu: the
# DE156 is a 26-bit ARM2 and this project now runs Amber (DEBUG_LOG D11/D12).
# `*gba_cpu*` matches nothing today, and a constraint that matches nothing is
# worse than none -- it reads as protection.
#
# Why FOUR is the honest number, checked module by module rather than assumed
# (the old comment here is right that a blanket exception is usually false):
# every clocked block inside a23_core updates only when `i_fetch_stall` is low
#
#     a23_execute.v:460         else -> all targets gated by *_update, and
#                               every *_update term carries !fetch_stall
#     a23_decode.v:1544,1659    `else if (!i_fetch_stall | i_fetch_abort)`
#     a23_decode.v:1696         `if (!i_fetch_stall | i_dabt)`
#     a23_register_bank.v:180   `else if (!i_fetch_stall)`
#     a23_multiply.v:186        `if (!i_fetch_stall)`
#     a23_coprocessor.v:101,123,148,173,180   `if (!i_fetch_stall)`
#
# and fetch_abort/dabt are tied low in this design (hs_a23_mem drives
# o_fetch_abort = 0).  hs_a23_mem only drops fetch_stall on a clock where
# i_system_rdy is high, and that is hs_cen's cen_arm -- one clock in four.
# So two successive updates of any register in there are at least four clocks
# apart.  The exception is scoped to a23_core's own registers: hs_a23_mem's
# FSM runs every clock and is deliberately NOT included.
#
# Without this, STA timed the whole execute datapath
# (status_bits_mode_rds_oh -> register read -> barrel shift -> ALU -> address
# -> o_adex) in one 10 ns period and missed by 9.0 ns.
# ---------------------------------------------------------------------------
set amber_regs [get_registers {*a23_core:*|*}]
set_multicycle_path -from $amber_regs -to $amber_regs -setup 4
set_multicycle_path -from $amber_regs -to $amber_regs -hold 3

# The PLL's third output (300 MHz) is a dummy load that keeps the solver from
# re-solving the VCO -- stadium_hero measured that failure.  Its only reader
# is a synchronised liveness counter and must not be timed.
set_false_path -from [get_clocks {*|pll|pll_inst|altera_pll_i|general[2].*|divclk}] -to [get_clocks {*|pll|pll_inst|altera_pll_i|general[0].*|divclk}]
