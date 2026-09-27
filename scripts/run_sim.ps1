# minisoc -- run the testbenches on Vivado's simulator (xsim).
#
#   .\run_sim.ps1                  every test
#   .\run_sim.ps1 fifo_wfast       one test
#   .\run_sim.ps1 fifo_wfast -Gui  open it in the waveform viewer
#
# A test passes only if it prints its PASS banner; the exit code of xsim
# is 0 even when a testbench reports errors, so it proves nothing.
param([string]$Only = "", [switch]$Gui)

$ErrorActionPreference = "Stop"
$vivado = if ($env:XILINX_VIVADO) { $env:XILINX_VIVADO } else { "C:\Xilinx\Vivado\2021.1" }
$env:PATH = "$vivado\bin;" + $env:PATH

$root = (Resolve-Path "$PSScriptRoot/..").Path
$cdc  = @("$root/rtl/cdc/sync_2ff.v", "$root/rtl/cdc/rst_sync.v",
          "$root/rtl/cdc/pulse_sync.v", "$root/rtl/cdc/async_fifo.v")
$fifo_tb = @("$root/dv/tb_async_fifo.sv") + $cdc

$prims_tb = @("$root/dv/tb_cdc_prims.sv") + $cdc

# The whole chip. The core (rtl/core) and the assembler package (dv/common)
# are copied from TinyTrust; see rtl/core/README.md.
$core = @("$root/rtl/core/core_p5.v", "$root/rtl/core/regfile.v", "$root/rtl/core/pmp.v")
$soc  = @("$root/rtl/soc/minisoc_top.v", "$root/rtl/soc/tcm.v", "$root/rtl/soc/perf_counters.v",
          "$root/rtl/soc/cdc_apb_bridge.v", "$root/rtl/periph/apb_decoder.v",
          "$root/rtl/periph/apb_uart_tx.v", "$root/rtl/periph/apb_timer.v",
          "$root/rtl/power/core_pd.v", "$root/rtl/power/pmu.v", "$root/rtl/power/icg.v")
$chip_tb = @("$root/dv/common/rv_asm_pkg.sv", "$root/dv/tb_minisoc.sv") + $soc + $cdc + $core
$power_tb = @("$root/dv/common/rv_asm_pkg.sv", "$root/dv/tb_power.sv") + $soc + $cdc + $core

# name, top, expected banner, sources, plusargs, defines
$tests = @(
    # power down and wake up, at two clock ratios
    @{ name = "power_pslow"; top = "tb_power"; expect = "POWER PASS"; srcs = $power_tb
       plus = @("cper=10", "pper=27"); defs = @() }
    @{ name = "power_pfast"; top = "tb_power"; expect = "POWER PASS"; srcs = $power_tb
       plus = @("cper=10", "pper=7"); defs = @() }
    # whole chip at three clock ratios
    @{ name = "chip_pslow"; top = "tb_minisoc"; expect = "MINISOC PASS"; srcs = $chip_tb
       plus = @("cper=10", "pper=27"); defs = @() }
    @{ name = "chip_pfast"; top = "tb_minisoc"; expect = "MINISOC PASS"; srcs = $chip_tb
       plus = @("cper=10", "pper=7"); defs = @() }
    @{ name = "chip_near";  top = "tb_minisoc"; expect = "MINISOC PASS"; srcs = $chip_tb
       plus = @("cper=10", "pper=10.37"); defs = @("CDC_META_SIM") }
    # sync_2ff, pulse_sync, rst_sync; binary vs Gray counter crossing
    @{ name = "cdc_prims";      top = "tb_cdc_prims"; expect = "CDC PRIMS PASS"; srcs = $prims_tb
       plus = @(); defs = @() }
    # the same with metastability modelled: the binary crossing must now fail
    # (and does not fail the test), the Gray one must still pass
    @{ name = "cdc_prims_meta"; top = "tb_cdc_prims"; expect = "CDC PRIMS PASS"; srcs = $prims_tb
       plus = @(); defs = @("CDC_META_SIM") }
    # write clock faster than read clock
    @{ name = "fifo_wfast"; top = "tb_async_fifo"; expect = "FIFO PASS"; srcs = $fifo_tb
       plus = @("wper=10", "rper=27"); defs = @() }
    # read clock faster than write clock
    @{ name = "fifo_rfast"; top = "tb_async_fifo"; expect = "FIFO PASS"; srcs = $fifo_tb
       plus = @("wper=27", "rper=10"); defs = @() }
    # nearly equal clocks: the phase between them drifts slowly, so edges
    # land close together again and again -- the worst case for a crossing
    @{ name = "fifo_near";  top = "tb_async_fifo"; expect = "FIFO PASS"; srcs = $fifo_tb
       plus = @("wper=10", "rper=10.37"); defs = @() }
    # with synchronizers modelling metastability (see sync_2ff.v)
    @{ name = "fifo_meta";  top = "tb_async_fifo"; expect = "FIFO PASS"; srcs = $fifo_tb
       plus = @("wper=10", "rper=10.37"); defs = @("CDC_META_SIM") }
)

# The Vivado tools are .bat files that write progress to stderr; with
# ErrorActionPreference = Stop that would abort a clean run.
function Invoke-Tool($exe, $argv, $log) {
    $ErrorActionPreference = "Continue"
    & $exe @argv *> $log
    $code = $LASTEXITCODE
    $ErrorActionPreference = "Stop"
    return $code
}

$fail = 0
foreach ($t in $tests) {
    if ($Only -and $t.name -ne $Only) { continue }
    Write-Host "===== $($t.name) ====="

    $dir = "$root/sim_out/$($t.name)"
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
    New-Item -ItemType Directory -Force $dir | Out-Null
    Push-Location $dir
    try {
        $defArgs = @(); foreach ($d in $t.defs) { $defArgs += @("-d", $d) }
        # quoted: cmd.exe splits an unquoted argument at '='
        $plusArgs = @(); foreach ($p in $t.plus) { $plusArgs += @("-testplusarg", ('"' + $p + '"')) }

        if ((Invoke-Tool "xvlog.bat" (@("-sv") + $defArgs + $t.srcs) "xvlog.out") -ne 0) {
            Write-Host "  COMPILE FAIL"; Get-Content xvlog.log | Select-String "ERROR" | ForEach-Object { "  $_" }
            $fail = 1; continue
        }
        if ((Invoke-Tool "xelab.bat" @("-debug", "typical", "--timescale", "1ns/1ps", "-s", "snap", $t.top) "xelab.out") -ne 0) {
            Write-Host "  ELABORATE FAIL"; Get-Content xelab.log | Select-String "ERROR" | ForEach-Object { "  $_" }
            $fail = 1; continue
        }
        if ($Gui) {
            Invoke-Tool "xsim.bat" (@("snap", "-gui", "-onfinish", "stop") + $plusArgs) "xsim.out" | Out-Null
            continue
        }
        Invoke-Tool "xsim.bat" (@("snap", "-R") + $plusArgs) "xsim.out" | Out-Null
        $out = Get-Content xsim.log
        $out | Where-Object { $_ -match "PASS|FAIL|ERROR|latency|coverage|written|async_fifo:|cdc_prims|counter|pulses|minisoc:|UART|timer read|core cycles|peripheral accesses|power test|PMU ->|clock stopped" } | ForEach-Object { "  $_" }
        if (-not ($out -match [regex]::Escape($t.expect))) { Write-Host "  no '$($t.expect)' banner"; $fail = 1 }
    } finally { Pop-Location }
}

if ($fail) { Write-Host "SIM FAILED"; exit 1 }
Write-Host "ALL PASS"
exit 0
