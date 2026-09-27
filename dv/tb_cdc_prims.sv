// minisoc -- testbench for the small CDC blocks: sync_2ff, pulse_sync,
// rst_sync. Source clock 10 ns, destination clock 27 ns (or as plusargs).
//
// 1. Multi-bit crossing, binary vs Gray.
//    A counter in the source domain increments every cycle and crosses into
//    the destination twice: once as plain binary, once as Gray code. The
//    destination checks that every value it sees is one the source really
//    had -- between the last value it saw and the source's current value.
//
//    In a normal simulation BOTH pass: nothing goes metastable. Compiled
//    with +define+CDC_META_SIM (see sync_2ff.v) the binary copy fails --
//    several bits change at once and resolve inconsistently, producing a
//    mix of old and new bits that is neither value -- while the Gray copy
//    still passes.
//    That is the whole case for Gray-coding a multi-bit crossing, and why
//    a CDC bug is invisible to ordinary simulation.
//
//    The binary check is reported, not failed on: it is expected to fail
//    under CDC_META_SIM. The test *does* fail if it never fails there,
//    because then the metastability model is not doing its job.
//
// 2. pulse_sync: every pulse sent (while not busy) arrives exactly once,
//    and each output pulse is one cycle wide.
//
// 3. rst_sync: reset asserts with no clock edge, and releases on exactly the
//    second clock edge after the input goes high.

module tb_cdc_prims;

    real sper = 10.0, dper = 27.0;
    logic sclk = 0, dclk = 0;
    initial forever #(sper / 2) sclk = ~sclk;
    initial begin #(dper / 3); forever #(dper / 2) dclk = ~dclk; end

    logic arst_n = 0;
    wire  srst_n, drst_n;
    rst_sync u_srst (.clk(sclk), .arst_n(arst_n), .rst_n(srst_n));
    rst_sync u_drst (.clk(dclk), .arst_n(arst_n), .rst_n(drst_n));

    int n_err = 0;

    // =====================================================================
    // 1. counter crossing, binary vs Gray
    // =====================================================================
    localparam W = 6;
    logic [W-1:0] cnt = 0;                                // source domain
    wire  [W-1:0] cnt_gray = cnt ^ (cnt >> 1);
    always @(posedge sclk) if (srst_n) cnt <= cnt + 1;

    wire [W-1:0] bin_d, gray_d;
    sync_2ff #(.W(W)) u_bin  (.clk(dclk), .rst_n(drst_n), .d(cnt),      .q(bin_d));
    sync_2ff #(.W(W)) u_gray (.clk(dclk), .rst_n(drst_n), .d(cnt_gray), .q(gray_d));

    function automatic logic [W-1:0] gray2bin(logic [W-1:0] g);
        logic [W-1:0] b;
        b[W-1] = g[W-1];
        for (int i = W - 2; i >= 0; i--) b[i] = b[i+1] ^ g[i];
        return b;
    endfunction

    // Distance going forward from a to b, modulo the counter size.
    function automatic int fwd(logic [W-1:0] a, logic [W-1:0] b);
        return int'(W'(b - a));
    endfunction

    logic [W-1:0] bin_last = 0, gray_last = 0;
    int bin_bad = 0, gray_bad = 0, n_samples = 0;
    always @(posedge dclk) begin
        if (drst_n && u_bin.sync !== 'x) begin
            // Legal: no further forward than the source currently is. Seeing
            // a value beyond the source means the crossing invented it.
            if (fwd(bin_last, bin_d) > fwd(bin_last, cnt)) bin_bad++;
            if (fwd(gray_last, gray2bin(gray_d)) > fwd(gray_last, cnt)) gray_bad++;
            bin_last  = bin_d;
            gray_last = gray2bin(gray_d);
            n_samples++;
        end
    end

    // =====================================================================
    // 2. pulse_sync
    // =====================================================================
    logic sp = 0;
    wire  sbusy, dp;
    pulse_sync u_ps (.src_clk(sclk), .src_rst_n(srst_n), .src_pulse(sp), .src_busy(sbusy),
                     .dst_clk(dclk), .dst_rst_n(drst_n), .dst_pulse(dp));

    int n_sent = 0, n_got = 0;
    always @(posedge sclk) begin
        if (sp) n_sent++;
        sp <= srst_n && !sbusy && !sp && ($urandom_range(3) == 0);
    end
    always @(posedge dclk) if (dp) n_got++;

    a_pulse_one_cycle: assert property (@(posedge dclk) disable iff (!drst_n) dp |=> !dp)
        else begin $display("ERROR: destination pulse longer than one cycle"); n_err++; end
    a_no_pulse_while_busy: assert property (@(posedge sclk) disable iff (!srst_n) sp |-> !sbusy)
        else begin $display("ERROR: pulse sent while busy"); n_err++; end

    // =====================================================================
    // 3. rst_sync, checked directly
    // =====================================================================
    task automatic check_rst_sync();
        // assert: immediate, between clock edges
        @(posedge sclk); #(sper / 4);
        arst_n = 0; #0.1;
        if (srst_n !== 0) begin $display("ERROR: reset did not assert without a clock edge"); n_err++; end
        // release mid-cycle: must stay in reset through the 1st edge, leave on the 2nd
        #(sper / 2);
        arst_n = 1;
        @(posedge sclk); #0.1;
        if (srst_n !== 0) begin $display("ERROR: reset released on the 1st edge"); n_err++; end
        @(posedge sclk); #0.1;
        if (srst_n !== 1) begin $display("ERROR: reset not released on the 2nd edge"); n_err++; end
    endtask

    // =====================================================================
    initial begin
        if ($value$plusargs("sper=%f", sper)) ;
        if ($value$plusargs("dper=%f", dper)) ;

        repeat (3) @(posedge sclk);
        arst_n = 1;
        repeat (20000) @(posedge sclk);

        // stop sending, let the last pulse land
        wait (!sbusy);
        repeat (10) @(posedge dclk);
        check_rst_sync();

`ifdef CDC_META_SIM
        $display("cdc_prims (metastability model ON), sclk %.2f ns, dclk %.2f ns", sper, dper);
`else
        $display("cdc_prims (metastability model off), sclk %.2f ns, dclk %.2f ns", sper, dper);
`endif
        $display("  counter crossing, %0d samples: binary saw %0d impossible values, Gray saw %0d",
                 n_samples, bin_bad, gray_bad);
        $display("  pulses: sent %0d, received %0d", n_sent, n_got);

        if (gray_bad != 0) begin $display("ERROR: Gray crossing produced impossible values"); n_err++; end
`ifdef CDC_META_SIM
        if (bin_bad == 0) begin
            $display("ERROR: binary crossing never failed -- metastability model not effective");
            n_err++;
        end
`else
        if (bin_bad != 0) begin $display("ERROR: binary crossing failed with no metastability model"); n_err++; end
`endif
        if (n_sent != n_got || n_sent < 100) begin $display("ERROR: pulses lost or too few sent"); n_err++; end

        if (n_err == 0) $display("CDC PRIMS PASS");
        else            $display("CDC PRIMS FAIL: %0d errors", n_err);
        $finish;
    end

endmodule
