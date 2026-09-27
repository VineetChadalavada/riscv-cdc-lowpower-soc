# Wave layout for tb_power: the power sequence, and what the core domain
# looks like from both sides of the isolation cells.
#
# Things to look for:
#   - PMU state steps through DRAIN, ISOLATE, CLK_OFF, RESET, OFF, one clock each.
#   - gclk_core stops while clk_core keeps running (the ICG).
#   - while pwr_on is low, "inside" signals are X (red) and "outside" the
#     clamps they are a clean 0.
#   - the timer interrupt rises, and the sequence runs in reverse.

set tb  /tb_power
set dut /tb_power/dut
set pd  /tb_power/dut/u_core_pd

create_wave_config "power"
set_property needs_save false [current_wave_config]
log_wave -recursive *

set layout [list \
    "Clocks"               [list $tb/clk_core bin  $dut/gclk_core bin  $tb/clk_periph bin] \
    "PMU"                  [list $dut/u_pmu/state dec  $dut/pd_pwr_on bin  $dut/pd_iso_en bin \
                                 $dut/pd_clk_en bin  $dut/pd_rst_n bin  $dut/irq_timer_core bin] \
    "Core domain, inside"  [list $pd/out_domain hex  {/tb_power/dut/u_core_pd/u_core/u_regfile/regs[10]} hex] \
    "Core domain, outside (isolated)" [list $dut/imem_valid bin  $dut/imem_addr hex \
                                 $dut/dmem_valid bin  $dut/dmem_addr hex] \
    "Performance"          [list $dut/u_perf/sleep dec  $dut/u_perf/cycles dec] \
    "UART"                 [list $dut/uart_tx bin] \
]

foreach {group sigs} $layout {
    set g [add_wave_group $group]
    foreach {path radix} $sigs { add_wave -into $g -radix $radix $path }
}

run all
