# minisoc -- timing constraints.
#
# Two clocks with no relationship between them.
#
# clk_core is 15 ns (66.7 MHz) on the Artix-7 stand-in. At 10 ns the core
# misses by about 3 ns after synthesis: core_p5 was tuned for the ASIC flow,
# and an FPGA LUT is slower than a standard cell. The simulations run the
# core at 10 ns; the clock ratio is what matters to them, not the speed.
create_clock -name clk_core   -period 15.000 [get_ports clk_core]
create_clock -name clk_periph -period 27.000 [get_ports clk_periph]

# Every path between the two domains goes through a synchronizer, and none
# of them can be timed as a normal single-cycle path: the phase between the
# clocks is arbitrary. So each crossing is given a maximum delay instead of
# being ignored.
#
# -datapath_only drops clock skew from the calculation. The bound is the
# faster of the two periods: it keeps a Gray pointer's bits arriving within
# one clock of each other, so the receiving side can never catch two
# changes in flight at once. Cutting these paths entirely (set_false_path or
# set_clock_groups -asynchronous) would let the tools route one pointer bit
# the long way round the chip, which is the real-world way a correct Gray
# FIFO still fails.
set_max_delay -datapath_only -from [get_clocks clk_core]   -to [get_clocks clk_periph] 15.000
set_max_delay -datapath_only -from [get_clocks clk_periph] -to [get_clocks clk_core]   15.000

# The reset pin is asynchronous by design; each domain synchronizes its
# release (rst_sync), so the pin itself has no timing relationship to meet.
set_false_path -from [get_ports arst_n]
