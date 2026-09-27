# Wave layout for tb_minisoc: follow one peripheral access from the core,
# across the bridge, onto APB, and back.
#
# Things to look for:
#   - a store to 0x1000_0000: dmem_valid rises in clk_core; a few cycles
#     later psel/penable rise in clk_periph; pready closes it; then
#     br_ready answers the core. The gap is the crossing latency.
#   - the 2nd and 3rd UART writes: pready stays low while uart_tx is busy.
#   - the interrupt: timer irq rises in clk_periph, irq_timer_core follows
#     two core clocks later, and the core jumps to 0x100.

set tb  /tb_minisoc
set dut /tb_minisoc/dut

create_wave_config "minisoc"
set_property needs_save false [current_wave_config]
log_wave -recursive *

set layout [list \
    "Clocks and resets"  [list $tb/clk_core bin  $dut/rst_core_n bin  $tb/clk_periph bin  $dut/rst_periph_n bin] \
    "Core data bus (clk_core)" [list \
        $dut/dmem_valid bin  $dut/dmem_addr hex  $dut/dmem_wstrb bin  $dut/dmem_wdata hex \
        $dut/dmem_ready bin  $dut/dmem_rdata hex  $dut/dmem_fault bin] \
    "Bridge, core side"  [list \
        $dut/u_bridge/c_waiting bin  $dut/u_bridge/req_push bin \
        $dut/u_bridge/rsp_pop bin  $dut/br_ready bin] \
    "APB (clk_periph)"   [list \
        $dut/u_bridge/state dec  $dut/psel bin  $dut/penable bin  $dut/pwrite bin \
        $dut/paddr hex  $dut/pwdata hex  $dut/pready bin  $dut/prdata hex  $dut/pslverr bin] \
    "UART"               [list $dut/u_uart/busy bin  $dut/uart_tx bin  $tb/uart_char ascii] \
    "Interrupt crossing" [list \
        $dut/irq_timer_periph bin  $dut/irq_timer_core bin  $dut/u_core_pd/u_core/pc_f hex] \
]

foreach {group sigs} $layout {
    set g [add_wave_group $group]
    foreach {path radix} $sigs { add_wave -into $g -radix $radix $path }
}

run all
