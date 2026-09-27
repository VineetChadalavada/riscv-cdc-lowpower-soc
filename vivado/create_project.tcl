# minisoc -- build the Vivado project.
#
#   cd minisoc/vivado
#   vivado -mode batch -source create_project.tcl     then open proj/minisoc.xpr
#
# proj/ is generated and gitignored; this script is the source of truth and
# re-running it rebuilds proj/ from scratch.
#
# Simulation sets (Sources panel > right-click > Make Active > Run Simulation):
#   sim_minisoc          the whole chip running its test program, with waves
#   sim_power            the core powered down and woken by the timer, with waves
#   sim_async_fifo       the FIFO, write clock 10 ns / read clock 27 ns, with waves
#   sim_async_fifo_meta  the same with metastability modelled (CDC_META_SIM)
#   sim_cdc_prims        synchronizer, pulse and reset synchronizer checks
#   sim_cdc_prims_meta   the same with metastability modelled

set here [file normalize [file dirname [info script]]]
set root [file normalize "$here/.."]
set proj "$here/proj"

file delete -force $proj
create_project minisoc $proj -force
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

# The CPU is TinyTrust's core, copied in unchanged (see rtl/core/README.md).
set rtl [list \
    $root/rtl/cdc/sync_2ff.v  $root/rtl/cdc/rst_sync.v \
    $root/rtl/cdc/pulse_sync.v $root/rtl/cdc/async_fifo.v \
    $root/rtl/soc/minisoc_top.v $root/rtl/soc/tcm.v $root/rtl/soc/perf_counters.v \
    $root/rtl/soc/cdc_apb_bridge.v \
    $root/rtl/periph/apb_decoder.v $root/rtl/periph/apb_uart_tx.v $root/rtl/periph/apb_timer.v \
    $root/rtl/power/core_pd.v $root/rtl/power/pmu.v $root/rtl/power/icg.v \
    $root/rtl/core/core_p5.v \
    $root/rtl/core/regfile.v \
    $root/rtl/core/pmp.v \
]
add_files -fileset sources_1 $rtl
add_files -fileset constrs_1 $root/constraints/minisoc.xdc
set_property top minisoc_top [get_filesets sources_1]

# The chip test's program is assembled by this package.
set asm $root/dv/common/rv_asm_pkg.sv

# name  top  testbench-files  define  waves
set sims [list \
    [list minisoc         tb_minisoc    [list $asm $root/dv/tb_minisoc.sv] {}           $root/dv/waves_minisoc.tcl] \
    [list power           tb_power      [list $asm $root/dv/tb_power.sv]   {}           $root/dv/waves_power.tcl] \
    [list async_fifo      tb_async_fifo [list $root/dv/tb_async_fifo.sv]  {}           $root/dv/waves_async_fifo.tcl] \
    [list async_fifo_meta tb_async_fifo [list $root/dv/tb_async_fifo.sv]  CDC_META_SIM $root/dv/waves_async_fifo.tcl] \
    [list cdc_prims       tb_cdc_prims  [list $root/dv/tb_cdc_prims.sv]   {}           {}] \
    [list cdc_prims_meta  tb_cdc_prims  [list $root/dv/tb_cdc_prims.sv]   CDC_META_SIM {}] \
]

foreach s $sims {
    lassign $s name top tbs def waves
    set fs sim_$name
    create_fileset -simset $fs
    add_files -fileset $fs -norecurse $tbs
    foreach f $tbs { set_property file_type SystemVerilog [get_files -of_objects [get_filesets $fs] $f] }
    set_property top $top [get_filesets $fs]
    set_property top_lib xil_defaultlib [get_filesets $fs]
    if {$def ne ""} { set_property verilog_define $def [get_filesets $fs] }
    set_property -name {xsim.elaborate.xelab.more_options} -value {--timescale 1ns/1ps} -objects [get_filesets $fs]
    set_property -name {xsim.simulate.xsim.more_options}   -value {-onfinish stop}       -objects [get_filesets $fs]
    if {$waves ne ""} {
        # the wave script ends with `run all`
        set_property -name {xsim.simulate.custom_tcl} -value $waves -objects [get_filesets $fs]
        set_property -name {xsim.simulate.runtime}    -value {0ns}  -objects [get_filesets $fs]
    } else {
        set_property -name {xsim.simulate.runtime}    -value {all}  -objects [get_filesets $fs]
    }
}

current_fileset -simset [get_filesets sim_minisoc]
delete_fileset [get_filesets sim_1]

puts "MINISOC PROJECT READY: $proj/minisoc.xpr"
