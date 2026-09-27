// minisoc -- power-down and wake-up test.
//
// The program:
//   cold boot  reads PMU STATUS: 0, so this is a cold start. Prints "S",
//              sets the timer to fire in a while, asks the PMU to sleep,
//              and spins. The PMU isolates the core, stops its clock,
//              resets it and cuts its power.
//   wake-up    the timer interrupt (crossing from clk_periph) wakes the PMU,
//              which powers the core back up. The core reboots from address
//              0, reads STATUS: 1, so it takes the wake-up path: clears the
//              status and the timer, prints "W", records how long it slept.
//
// Checks
//   - the UART says "SW": both halves ran, in order;
//   - the core's register file really was lost (filled with X by the power
//     model), so the wake-up path worked from a genuine cold core;
//   - the sleep counter shows the core's clock was stopped for a while;
//   - the power sequence rules, every cycle (assertions below):
//       isolation is on whenever power is off
//       the clock is stopped whenever power is off
//       the core is held in reset whenever power is off
//       isolation goes on before power goes off, and comes off after reset
//       nothing unknown (X) ever leaves the core's domain
//
// Plusargs: +cper=<ns> +pper=<ns>

module tb_power;
    import rv_asm_pkg::*;

    real cper = 10.0, pper = 27.0;
    logic clk_core = 0, clk_periph = 0;
    initial forever #(cper / 2) clk_core = ~clk_core;
    initial begin #(pper / 3); forever #(pper / 2) clk_periph = ~clk_periph; end

    logic arst_n = 0;
    wire  uart_tx;
    minisoc_top dut (.clk_core(clk_core), .clk_periph(clk_periph), .arst_n(arst_n), .uart_tx(uart_tx));

    int n_err = 0;

    // ---------------------------------------------------------------
    // program
    // ---------------------------------------------------------------
    int pc_words = 0;
    function automatic void emit(logic [31:0] insn); dut.u_tcm.mem[pc_words] = insn; pc_words++; endfunction
    function automatic void place(int byte_addr); pc_words = byte_addr / 4; endfunction
    function automatic int  here(); return pc_words * 4; endfunction
    function automatic logic [31:0] ram(int byte_addr); return dut.u_tcm.mem[byte_addr / 4]; endfunction

    localparam int A_DONE = 12'h3FC, A_SLEEP = 12'h410, A_TOTAL = 12'h414;
    localparam int WAKE   = 12'h080;              // wake-up path
    localparam int UART_DIV = 3;

    task automatic load_program();
        int br;
        for (int k = 0; k < 4096; k++) dut.u_tcm.mem[k] = 32'h0;

        // both paths start here: nothing survives a power-down but RAM
        emit(LUI (10, 32'h10000));                 // UART
        emit(LUI (11, 32'h10001));                 // timer
        emit(LUI (12, 32'h20000));                 // performance counters
        emit(LUI (13, 32'h30000));                 // PMU
        emit(ADDI(6, 0, UART_DIV));  emit(SW(6, 10, 8));
        emit(LW  (7, 13, 4));                      // PMU STATUS: 1 = woke up
        br = here();
        emit(BNE (7, 0, WAKE - br));

        // cold boot
        emit(ADDI(6, 0, "S"));       emit(SW(6, 10, 0));
        emit(ADDI(6, 0, 1));         emit(SW(6, 11, 8));      // timer on
        emit(LW  (7, 11, 0));
        emit(ADDI(7, 7, 300));       emit(SW(7, 11, 4));      // CMP = COUNT + 300
        emit(ADDI(6, 0, 3));         emit(SW(6, 11, 8));      // timer on, interrupt on
        emit(ADDI(6, 0, 1));         emit(SW(6, 13, 0));      // PMU: sleep
        emit(JAL (0, 0));                                     // wait to be switched off

        // wake-up
        place(WAKE);
        emit(ADDI(6, 0, 1));         emit(SW(6, 13, 4));      // clear PMU STATUS
        emit(SW  (6, 11, 12));                                // clear the timer match
        emit(SW  (0, 11, 8));                                 // timer off
        emit(ADDI(6, 0, "W"));       emit(SW(6, 10, 0));
        emit(LW  (14, 12, 12'h18));  emit(SW(14, 0, A_SLEEP));
        emit(LW  (15, 12, 0));       emit(SW(15, 0, A_TOTAL));
        emit(ADDI(6, 0, 1));         emit(SW(6, 0, A_DONE));
        emit(JAL (0, 0));
    endtask

    // ---------------------------------------------------------------
    // UART receiver
    // ---------------------------------------------------------------
    localparam int BIT = UART_DIV + 1;
    string uart_text = "";
    initial begin
        logic [7:0] ch;
        wait (arst_n);
        forever begin
            @(negedge uart_tx);
            repeat (BIT / 2) @(posedge clk_periph);
            for (int b = 0; b < 8; b++) begin repeat (BIT) @(posedge clk_periph); ch[b] = uart_tx; end
            repeat (BIT) @(posedge clk_periph);
            uart_text = {uart_text, string'(ch)};
        end
    end

    // ---------------------------------------------------------------
    // power sequence assertions (always-on clock)
    // ---------------------------------------------------------------
    wire pwr_on = dut.pd_pwr_on, iso_en = dut.pd_iso_en, clk_en = dut.pd_clk_en, prst_n = dut.pd_rst_n;
    wire on_rst_n = dut.rst_core_n;

    a_iso_while_off: assert property (@(posedge clk_core) disable iff (!on_rst_n)
        !pwr_on |-> iso_en)
        else begin $display("ERROR %t: power off without isolation", $realtime); n_err++; end

    a_clock_stopped_while_off: assert property (@(posedge clk_core) disable iff (!on_rst_n)
        !pwr_on |-> !clk_en)
        else begin $display("ERROR %t: core clock running with power off", $realtime); n_err++; end

    a_reset_while_off: assert property (@(posedge clk_core) disable iff (!on_rst_n)
        !pwr_on |-> !prst_n)
        else begin $display("ERROR %t: core not in reset with power off", $realtime); n_err++; end

    // isolation comes on strictly before power goes off...
    a_iso_before_off: assert property (@(posedge clk_core) disable iff (!on_rst_n)
        $fell(pwr_on) |-> $past(iso_en))
        else begin $display("ERROR %t: power cut in the same cycle as isolation", $realtime); n_err++; end

    // ...and goes off only after the core has left reset
    a_uniso_after_reset: assert property (@(posedge clk_core) disable iff (!on_rst_n)
        $fell(iso_en) |-> pwr_on && prst_n && $past(prst_n))
        else begin $display("ERROR %t: isolation removed before the core was running", $realtime); n_err++; end

    // the clock only restarts with power good
    a_clock_needs_power: assert property (@(posedge clk_core) disable iff (!on_rst_n)
        $rose(clk_en) |-> pwr_on)
        else begin $display("ERROR %t: clock started with power off", $realtime); n_err++; end

    // nothing unknown leaves the core domain, ever
    a_no_x_escapes: assert property (@(posedge clk_core) disable iff (!on_rst_n)
        !$isunknown({dut.imem_valid, dut.dmem_valid, dut.fsm_fault})
        && (!dut.dmem_valid || !$isunknown({dut.dmem_addr, dut.dmem_wstrb})))
        else begin $display("ERROR %t: X escaped the core's power domain", $realtime); n_err++; end

    // ---------------------------------------------------------------
    // observe: the sequence, and proof that state was really lost
    // ---------------------------------------------------------------
    bit regs_lost = 0;
    always @(posedge clk_core)
        if (!pwr_on && $isunknown(dut.u_core_pd.u_core.u_regfile.regs[10])) regs_lost = 1;

    logic [3:0] last_state = 0;
    string names[10] = '{"RUN", "DRAIN", "ISOLATE", "CLK_OFF", "RESET",
                         "OFF", "PWR_UP", "CLK_ON", "RELEASE", "UNISO"};
    always @(posedge clk_core) begin
        if (dut.u_pmu.state != last_state) begin
            $display("  %8.0f ns  PMU -> %s", $realtime, names[dut.u_pmu.state]);
            last_state = dut.u_pmu.state;
        end
    end

    // ---------------------------------------------------------------
    initial begin
        if ($value$plusargs("cper=%f", cper)) ;
        if ($value$plusargs("pper=%f", pper)) ;
        load_program();

        repeat (3) @(posedge clk_core);
        arst_n = 1;

        fork
            while (ram(A_DONE) != 1) @(posedge clk_core);
            begin #(1ms); $display("ERROR: program did not finish"); n_err++; end
        join_any
        disable fork;
        #(30 * BIT * pper);                                  // let the UART finish

        $display("power test: core clock %.2f ns, peripheral clock %.2f ns", cper, pper);
        $display("  UART sent \"%s\"", uart_text);
        $display("  core clock stopped for %0d of %0d cycles; register file lost during sleep: %s",
                 ram(A_SLEEP), ram(A_TOTAL), regs_lost ? "yes" : "no");

        if (uart_text != "SW")   begin $display("ERROR: UART text wrong"); n_err++; end
        if (!regs_lost)          begin $display("ERROR: power model did not clear the register file"); n_err++; end
        if (ram(A_SLEEP) < 100)  begin $display("ERROR: the core hardly slept"); n_err++; end

        if (n_err == 0) $display("POWER PASS");
        else            $display("POWER FAIL: %0d errors", n_err);
        $finish;
    end

endmodule
