# minisoc -- CDC waivers: findings reviewed and accepted, with the reason.
#
# Sourced after synthesis, before report_cdc (waivers name netlist objects,
# which only exist once the design is synthesized). A waiver is a claim that
# a human checked the crossing; each one here says why it is safe, and
# anything NOT matched by one still shows up in the report.
#
# Every waiver is scoped to the async FIFOs inside the bridge. A new
# crossing anywhere else in the design is not covered and will be reported.

# CDC-6: multi-bit value through a synchronizer.
# These are the FIFO read/write pointers. They cross as Gray code, so only
# one bit changes per clock, and minisoc.xdc bounds their skew with
# set_max_delay -datapath_only so the bits cannot arrive a clock apart.
# (Vivado cannot see that a bus is Gray-coded, so it always warns.)
create_waiver -type CDC -id CDC-6 -user minisoc \
    -from [get_pins -hier -filter {NAME =~ u_bridge/u_*/*gray_reg*/C}] \
    -to   [get_pins -hier -filter {NAME =~ u_bridge/u_*/u_sync_*/meta_reg*/D}] \
    -description {Gray-coded async FIFO pointer; skew bounded by set_max_delay -datapath_only}

# CDC-15: data from the FIFO memory captured by a register with an enable.
# This is the FIFO data path, and the pattern it is meant to have: the
# memory is written in one clock domain and read in the other, and the
# reading register only loads when the synchronized pointers say the entry
# was written at least two clocks earlier and is stable.
#   request FIFO  -> APB address/data/control registers (clk_periph)
#   response FIFO -> c_rsp, the registered response (clk_core)
create_waiver -type CDC -id CDC-15 -user minisoc \
    -from [get_pins -hier -filter {NAME =~ u_bridge/u_req/mem_reg*/CLK}] \
    -to   [get_pins -hier -filter {NAME =~ u_bridge/p*_reg*/*}] \
    -description {Async FIFO read data, loaded under a synchronized not-empty enable}

create_waiver -type CDC -id CDC-15 -user minisoc \
    -from [get_pins -hier -filter {NAME =~ u_bridge/u_rsp/mem_reg*/CLK}] \
    -to   [get_pins -hier -filter {NAME =~ u_bridge/c_rsp_reg*/*}] \
    -description {Async FIFO read data, loaded under a synchronized not-empty enable}
