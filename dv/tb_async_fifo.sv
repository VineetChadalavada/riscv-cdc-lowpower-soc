// minisoc -- testbench for async_fifo.
//
// Two free-running clocks with no fixed relationship (periods from plusargs),
// a writer and a reader each driven from its own clock, and four phases:
//
//   latency  writer sparse, reader always ready: measures how long one word
//            takes to cross. Nothing else is in the FIFO, so this is the pure
//            synchronizer delay.
//   random   both sides 50%: general traffic.
//   fill     writer flat out, reader slow: drives the FIFO full.
//   drain    writer slow, reader flat out: drives it empty.
//
// Checks
//   scoreboard   every word comes out once, in order, unchanged; the FIFO
//                never holds more than DEPTH words.
//   assertions   pointers change at most one bit per clock (Gray code), and
//                a pointer never moves on a write-when-full or read-when-empty.
//   coverage     full and empty both reached, set and cleared. The test fails
//                below 100%: a test that never filled the FIFO has not tested
//                the full flag, however many words it moved.
//
// Plusargs: +wper=<ns> +rper=<ns> +n=<words per phase>

module tb_async_fifo;

    localparam DW = 16, AW = 3, DEPTH = 1 << AW;

    // ---------------- clocks and resets ----------------
    real wper = 10.0, rper = 27.0;
    logic wclk = 0, rclk = 0;
    initial forever #(wper / 2) wclk = ~wclk;
    initial begin #(rper / 3); forever #(rper / 2) rclk = ~rclk; end   // offset phase

    logic arst_n = 0;
    wire  wrst_n, rrst_n;
    rst_sync u_wrst (.clk(wclk), .arst_n(arst_n), .rst_n(wrst_n));
    rst_sync u_rrst (.clk(rclk), .arst_n(arst_n), .rst_n(rrst_n));

    // ---------------- DUT ----------------
    logic          winc = 0, rinc = 0;
    logic [DW-1:0] wdata = 0;
    wire  [DW-1:0] rdata;
    wire           wfull, rempty;

    async_fifo #(.DW(DW), .AW(AW)) dut (
        .wclk(wclk), .wrst_n(wrst_n), .winc(winc), .wdata(wdata), .wfull(wfull),
        .rclk(rclk), .rrst_n(rrst_n), .rinc(rinc), .rdata(rdata), .rempty(rempty)
    );

    // ---------------- stimulus control ----------------
    logic [8*8-1:0] phase_name;           // for the waveform, ASCII radix
    int wrate, rrate;                     // percent chance of winc / rinc per cycle
    int writes_left = 0;
    int n_err = 0;

    // ---------------- scoreboard ----------------
    typedef struct { logic [DW-1:0] data; realtime t; } entry_t;
    entry_t q[$];
    int     level = 0;                    // words in the FIFO, as the scoreboard sees it

    logic [DW-1:0] next_word = 0;
    int  n_written = 0, n_read = 0;

    // latency stats (latency phase only)
    bit      measuring = 0;
    realtime lat_min = 1e9, lat_max = 0, lat_sum = 0;
    int      lat_n = 0;

    // Declared out here, not inside the always blocks: a variable declared
    // with an initializer inside an always block is static, so the
    // initializer runs once at time zero -- not every time through.
    entry_t  e;
    realtime lat;

    // Writer. Acceptance is judged on the values *before* the edge, which is
    // what the DUT saw: a write happens when winc was high and wfull was low.
    always @(posedge wclk) begin
        if (winc && !wfull) begin
            q.push_back('{wdata, $realtime});
            level = q.size();
            n_written++;
            writes_left--;
            if (q.size() > DEPTH) begin
                $display("ERROR %t: FIFO holds %0d words, depth is %0d", $realtime, q.size(), DEPTH);
                n_err++;
            end
            next_word = next_word + 1;
        end
        if (wrst_n && writes_left > 0 && $urandom_range(99) < wrate) begin
            winc  <= 1'b1;
            wdata <= next_word;
        end else
            winc  <= 1'b0;
    end

    // Reader
    always @(posedge rclk) begin
        if (rinc && !rempty) begin
            if (q.size() == 0) begin
                $display("ERROR %t: read %h from a FIFO the scoreboard says is empty", $realtime, rdata);
                n_err++;
            end else begin
                e = q.pop_front();
                level = q.size();
                if (rdata !== e.data) begin
                    $display("ERROR %t: read %h, expected %h", $realtime, rdata, e.data);
                    n_err++;
                end
                if (measuring) begin
                    lat = $realtime - e.t;
                    lat_sum += lat; lat_n++;
                    if (lat < lat_min) lat_min = lat;
                    if (lat > lat_max) lat_max = lat;
                end
            end
            n_read++;
        end
        rinc <= rrst_n && ($urandom_range(99) < rrate);
    end

    // ---------------- assertions ----------------
    // Gray code: a synchronized pointer is only safe if it moves one bit at a time.
    a_wgray_one_bit: assert property (@(posedge wclk) disable iff (!wrst_n)
        $countones(dut.wgray ^ $past(dut.wgray)) <= 1)
        else begin $display("ERROR %t: write pointer changed more than one bit", $realtime); n_err++; end

    a_rgray_one_bit: assert property (@(posedge rclk) disable iff (!rrst_n)
        $countones(dut.rgray ^ $past(dut.rgray)) <= 1)
        else begin $display("ERROR %t: read pointer changed more than one bit", $realtime); n_err++; end

    // Writing into a full FIFO, or reading an empty one, must be ignored.
    a_no_write_when_full: assert property (@(posedge wclk) disable iff (!wrst_n)
        (winc && wfull) |=> $stable(dut.wbin))
        else begin $display("ERROR %t: pointer moved on a write while full", $realtime); n_err++; end

    a_no_read_when_empty: assert property (@(posedge rclk) disable iff (!rrst_n)
        (rinc && rempty) |=> $stable(dut.rbin))
        else begin $display("ERROR %t: pointer moved on a read while empty", $realtime); n_err++; end

    // ---------------- coverage ----------------
    covergroup cg_write @(posedge wclk);
        option.per_instance = 1;
        cp_full:  coverpoint wfull  { bins becomes_full = (0 => 1); bins leaves_full = (1 => 0); }
        cp_level: coverpoint level  { bins empty = {0}; bins partly = {[1:DEPTH-1]}; bins full = {DEPTH}; }
        cp_push_full: coverpoint (winc && wfull) { bins write_attempt_while_full = {1}; }
    endgroup

    covergroup cg_read @(posedge rclk);
        option.per_instance = 1;
        cp_empty: coverpoint rempty { bins becomes_empty = (0 => 1); bins leaves_empty = (1 => 0); }
        cp_pop_empty: coverpoint (rinc && rempty) { bins read_attempt_while_empty = {1}; }
    endgroup

    cg_write cgw = new();
    cg_read  cgr = new();

    // ---------------- test sequence ----------------
    task automatic run_phase(string name, int n, int wr, int rr);
        phase_name = '0;
        foreach (name[k]) if (k < 8) phase_name[8*(name.len()-1-k) +: 8] = name[k];
        wrate = wr; rrate = rr;
        writes_left = n;
        wait (writes_left == 0);
        // let the reader empty the FIFO before the next phase
        rrate = 100;
        wait (q.size() == 0);
        repeat (6) @(posedge rclk);
    endtask

    int n;
    initial begin
        if ($value$plusargs("wper=%f", wper)) ;
        if ($value$plusargs("rper=%f", rper)) ;
        if (!$value$plusargs("n=%d", n)) n = 500;

        wrate = 0; rrate = 0;
        repeat (3) @(posedge wclk);
        arst_n = 1;
        wait (wrst_n && rrst_n);
        repeat (2) @(posedge wclk);

        measuring = 1;
        run_phase("latency", 50, 5, 100);
        measuring = 0;
        run_phase("random",  n, 50, 50);
        run_phase("fill",    n, 100, 10);
        run_phase("drain",   n, 10, 100);

        $display("async_fifo: wclk %.2f ns, rclk %.2f ns, depth %0d", wper, rper, DEPTH);
        $display("  words written %0d, read %0d", n_written, n_read);
        $display("  crossing latency: min %.1f ns, avg %.1f ns, max %.1f ns  (= %.1f to %.1f read clocks)",
                 lat_min, lat_sum / lat_n, lat_max, lat_min / rper, lat_max / rper);
        $display("  coverage: write side %.0f%%, read side %.0f%%",
                 cgw.get_inst_coverage(), cgr.get_inst_coverage());

        if (n_written != n_read) begin
            $display("ERROR: %0d words written but %0d read", n_written, n_read);
            n_err++;
        end
        if (cgw.get_inst_coverage() < 100 || cgr.get_inst_coverage() < 100) begin
            $display("ERROR: coverage not closed");
            n_err++;
        end

        if (n_err == 0) $display("FIFO PASS");
        else            $display("FIFO FAIL: %0d errors", n_err);
        $finish;
    end

    // a hung test is a failed test
    initial begin
        #(5ms);
        $display("FIFO FAIL: timeout");
        $finish;
    end

endmodule
