# Wave layout for tb_async_fifo: write side on top, read side below, and the
# two synchronized pointers in the middle -- the crossing itself.
#
# Things to look for:
#   - wgray changes one bit at a time; wgray_r follows it 2-3 read clocks later.
#   - rempty falls a few read clocks after a write: that delay is the
#     synchronizer latency the testbench measures.
#   - in the "fill" phase wfull goes high and winc keeps asking; wbin holds.

set tb  /tb_async_fifo
set dut /tb_async_fifo/dut

create_wave_config "async_fifo"
set_property needs_save false [current_wave_config]
log_wave -recursive *

set layout [list \
    "Test"              [list $tb/phase_name ascii  $tb/level dec] \
    "Write side (wclk)" [list $tb/wclk bin  $tb/wrst_n bin  $tb/winc bin  $tb/wdata hex \
                              $tb/wfull bin  $dut/wbin dec  $dut/wgray bin] \
    "Crossing"          [list $dut/wgray_r bin  $dut/rgray_w bin] \
    "Read side (rclk)"  [list $tb/rclk bin  $tb/rrst_n bin  $tb/rinc bin  $tb/rdata hex \
                              $tb/rempty bin  $dut/rbin dec  $dut/rgray bin] \
]

foreach {group sigs} $layout {
    set g [add_wave_group $group]
    foreach {path radix} $sigs { add_wave -into $g -radix $radix $path }
}

run all
