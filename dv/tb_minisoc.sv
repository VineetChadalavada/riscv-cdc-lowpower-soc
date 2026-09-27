// minisoc -- whole-chip test.
//
// A short program runs on the core and exercises every path between the
// two clock domains:
//
//   1. UART: set the baud divisor, send "Hi!". The 2nd and 3rd bytes are
//      written while the UART is still busy, so those APB writes stall on
//      PREADY -- the slow path through the bridge.
//   2. Timer: start it and read COUNT twice; the second read must be larger.
//   3. Interrupt: set the timer to fire, enable interrupts and spin. The
//      interrupt crosses from clk_periph to clk_core through a synchronizer;
//      the handler records mcause, clears the timer, and returns.
//   4. Performance counters: read them and store them for the testbench.
//
// The program is written with rv_asm_pkg, so no compiler is needed; the
// testbench loads it straight into RAM before releasing reset.
//
// Checks: the UART line decodes to "Hi!", the timer moved, mcause says
// "machine timer interrupt", exactly 12 peripheral accesses happened (a
// second, spurious interrupt would add two), and the APB protocol rules
// hold on every cycle (assertions below).
//
// Plusargs: +cper=<ns> core clock period, +pper=<ns> peripheral clock period.

module tb_minisoc;
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
    // program loading
    // ---------------------------------------------------------------
    int pc_words = 0;
    function automatic void emit(logic [31:0] insn);
        dut.u_tcm.mem[pc_words] = insn;
        pc_words++;
    endfunction
    function automatic void place(int byte_addr); pc_words = byte_addr / 4; endfunction
    function automatic logic [31:0] ram(int byte_addr); return dut.u_tcm.mem[byte_addr / 4]; endfunction

    localparam int A_DONE = 12'h3FC, A_CNT0 = 12'h400, A_CNT1 = 12'h404, A_MCAUSE = 12'h408,
                   A_PERF = 12'h410;
    localparam int UART_DIV = 3;                       // 4 peripheral clocks per bit

    task automatic load_program();
        for (int k = 0; k < 4096; k++) dut.u_tcm.mem[k] = 32'h0;

        // x10 = UART, x11 = timer, x12 = performance counters
        emit(LUI (10, 32'h10000));
        emit(LUI (11, 32'h10001));
        emit(LUI (12, 32'h20000));
        emit(ADDI(5, 0, 12'h100));
        emit(CSRRW(0, CSR_MTVEC, 5));             // trap handler at 0x100

        // 1. UART
        emit(ADDI(6, 0, UART_DIV));  emit(SW(6, 10, 8));     // DIV
        emit(ADDI(6, 0, "H"));       emit(SW(6, 10, 0));
        emit(ADDI(6, 0, "i"));       emit(SW(6, 10, 0));     // UART busy: stalls
        emit(ADDI(6, 0, "!"));       emit(SW(6, 10, 0));     // stalls again

        // 2. timer
        emit(ADDI(6, 0, 1));         emit(SW(6, 11, 8));     // CTRL = enable
        emit(LW  (7, 11, 0));
        emit(LW  (8, 11, 0));
        emit(SW  (7, 0, A_CNT0));
        emit(SW  (8, 0, A_CNT1));

        // 3. interrupt
        emit(ADDI(20, 0, 0));                                // flag, set by handler
        emit(LW  (7, 11, 0));
        emit(ADDI(7, 7, 200));       emit(SW(7, 11, 4));     // CMP = COUNT + 200
        emit(ADDI(6, 0, 3));         emit(SW(6, 11, 8));     // CTRL = enable + irq
        emit(ADDI(6, 0, 12'h080));   emit(CSRRS(0, CSR_MIE, 6));      // MTIE
        emit(ADDI(6, 0, 8));         emit(CSRRS(0, CSR_MSTATUS, 6));  // MIE
        emit(BEQ (20, 0, 0));                                // spin until the handler runs

        // 4. performance counters
        for (int r = 0; r < 5; r++) emit(LW(13 + r, 12, 4 * r));
        for (int r = 0; r < 5; r++) emit(SW(13 + r, 0, A_PERF + 4 * r));
        emit(ADDI(6, 0, 1));         emit(SW(6, 0, A_DONE));
        emit(JAL (0, 0));                                    // stop here

        // interrupt handler
        place(12'h100);
        emit(CSRR(21, CSR_MCAUSE));  emit(SW(21, 0, A_MCAUSE));
        emit(ADDI(6, 0, 1));         emit(SW(6, 11, 12));    // clear pending
        emit(SW  (0, 11, 8));                                // CTRL = 0
        emit(ADDI(20, 0, 1));
        emit(MRET());
    endtask

    // ---------------------------------------------------------------
    // UART receiver (peripheral clock domain)
    // ---------------------------------------------------------------
    localparam int BIT = UART_DIV + 1;
    string      uart_text = "";
    logic [7:0] uart_char = 0;          // last byte received; a string cannot be shown as a wave
    initial begin
        logic [7:0] ch;
        wait (arst_n);
        forever begin
            @(negedge uart_tx);                              // start bit
            repeat (BIT / 2) @(posedge clk_periph);
            for (int b = 0; b < 8; b++) begin
                repeat (BIT) @(posedge clk_periph);
                ch[b] = uart_tx;
            end
            repeat (BIT) @(posedge clk_periph);
            if (uart_tx !== 1'b1) begin $display("ERROR: UART stop bit missing"); n_err++; end
            uart_text = {uart_text, string'(ch)};
            uart_char = ch;
        end
    end

    // ---------------------------------------------------------------
    // APB protocol assertions (peripheral clock domain)
    // ---------------------------------------------------------------
    wire psel = dut.psel, penable = dut.penable, pready = dut.pready;

    // ACCESS is always preceded by exactly one SETUP cycle
    a_setup_first: assert property (@(posedge clk_periph) disable iff (!dut.rst_periph_n)
        $rose(penable) |-> psel && $past(psel) && !$past(penable))
        else begin $display("ERROR: APB ACCESS without SETUP"); n_err++; end

    a_enable_needs_sel: assert property (@(posedge clk_periph) disable iff (!dut.rst_periph_n)
        penable |-> psel)
        else begin $display("ERROR: PENABLE without PSEL"); n_err++; end

    // while the slave is stalling, the master must hold everything steady
    a_hold_while_waiting: assert property (@(posedge clk_periph) disable iff (!dut.rst_periph_n)
        (psel && penable && !pready) |=> psel && penable
                                        && $stable(dut.paddr) && $stable(dut.pwrite) && $stable(dut.pwdata))
        else begin $display("ERROR: APB signals changed during a wait state"); n_err++; end

    // count wait states, to show the stall path was really exercised
    int n_wait_states = 0;
    always @(posedge clk_periph) if (psel && penable && !pready) n_wait_states++;

    // ---------------------------------------------------------------
    initial begin
        if ($value$plusargs("cper=%f", cper)) ;
        if ($value$plusargs("pper=%f", pper)) ;
        load_program();

        repeat (3) @(posedge clk_core);
        arst_n = 1;

        fork
            // polled, not `wait (ram(...))`: wait only re-checks when a
            // signal in its expression changes, and it cannot see the memory
            // read hidden inside the function call, so it would never wake up
            while (ram(A_DONE) != 1) @(posedge clk_core);
            begin #(500us); $display("ERROR: program did not finish"); n_err++; end
        join_any
        disable fork;
        #(20 * pper);                                        // let the UART finish

        begin
            automatic int cycles = ram(A_PERF + 0),  fetches = ram(A_PERF + 4);
            automatic int p_n    = ram(A_PERF + 8),  p_cyc   = ram(A_PERF + 12), p_max = ram(A_PERF + 16);

            $display("minisoc: core clock %.2f ns, peripheral clock %.2f ns", cper, pper);
            $display("  UART sent \"%s\"", uart_text);
            $display("  timer read %0d then %0d; mcause = %08h", ram(A_CNT0), ram(A_CNT1), ram(A_MCAUSE));
            $display("  %0d core cycles, %0d instruction fetches", cycles, fetches);
            $display("  peripheral accesses %0d: average %.1f core cycles, longest %0d; %0d APB wait states",
                     p_n, real'(p_cyc) / p_n, p_max, n_wait_states);

            if (uart_text != "Hi!")               begin $display("ERROR: UART text wrong"); n_err++; end
            if (ram(A_CNT1) <= ram(A_CNT0))       begin $display("ERROR: timer did not advance"); n_err++; end
            if (ram(A_MCAUSE) !== 32'h8000_0007)  begin $display("ERROR: mcause is not a timer interrupt"); n_err++; end
            if (p_n != 12)                        begin $display("ERROR: expected 12 peripheral accesses"); n_err++; end
            if (n_wait_states == 0)               begin $display("ERROR: the APB stall path never ran"); n_err++; end
            if (dut.fsm_fault)                    begin $display("ERROR: core fault"); n_err++; end
        end

        if (n_err == 0) $display("MINISOC PASS");
        else            $display("MINISOC FAIL: %0d errors", n_err);
        $finish;
    end

endmodule
