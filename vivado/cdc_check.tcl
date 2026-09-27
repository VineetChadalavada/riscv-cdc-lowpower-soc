# minisoc -- synthesize the chip for an FPGA and run Vivado's CDC analysis.
#
#   cd minisoc/vivado
#   vivado -mode batch -source cdc_check.tcl
#
# Reports land in vivado/reports/:
#   cdc.rpt              every clock-domain crossing, and whether it is safe
#   clock_interaction.rpt  which clocks talk to which, and how constrained
#   timing.rpt           timing summary
#   utilization.rpt      resources used
#
# The FPGA is a stand-in: minisoc is not aimed at a board. report_cdc works
# on any synthesized netlist, and an Artix-7 is what the free edition of
# Vivado supports.

set here [file normalize [file dirname [info script]]]
set root [file normalize "$here/.."]
set out  "$here/reports"
file mkdir $out

read_verilog [list \
    $root/rtl/cdc/sync_2ff.v  $root/rtl/cdc/rst_sync.v  $root/rtl/cdc/async_fifo.v \
    $root/rtl/soc/minisoc_top.v $root/rtl/soc/tcm.v $root/rtl/soc/perf_counters.v \
    $root/rtl/soc/cdc_apb_bridge.v \
    $root/rtl/periph/apb_decoder.v $root/rtl/periph/apb_uart_tx.v $root/rtl/periph/apb_timer.v \
    $root/rtl/power/core_pd.v $root/rtl/power/pmu.v $root/rtl/power/icg.v \
    $root/rtl/core/core_p5.v $root/rtl/core/regfile.v $root/rtl/core/pmp.v \
]
read_xdc $root/constraints/minisoc.xdc

synth_design -top minisoc_top -part xc7a35tcpg236-1

# reviewed crossings, each with its reason (see the file)
source $root/constraints/cdc_waivers.tcl

report_cdc -details              -file $out/cdc.rpt
report_clock_interaction         -file $out/clock_interaction.rpt
report_timing_summary            -file $out/timing.rpt
report_utilization               -file $out/utilization.rpt

puts "CDC CHECK DONE: reports in $out"
