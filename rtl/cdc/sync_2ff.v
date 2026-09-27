`default_nettype none

// minisoc -- two-flop synchronizer.
//
// Brings a signal from another clock domain into this one. The first flop
// may go metastable when its input changes near the clock edge; the second
// flop gives it a full clock period to settle before anything uses it.
//
// USE IT ONLY FOR:
//   - single-bit level signals, or
//   - multi-bit values where at most ONE bit changes between consecutive
//     values (a Gray-coded counter). Each bit resolves independently, so a
//     binary counter going 0111 -> 1000 can be seen as any mix of the two,
//     e.g. 1111. That is the classic CDC bug, and the async FIFO avoids it
//     by synchronizing Gray pointers.
//
// ASYNC_REG tells Vivado these flops are a synchronizer: it places them next
// to each other (to maximise settling time) and report_cdc recognises the
// structure as safe.
//
// METASTABILITY IN SIMULATION
// An ordinary RTL simulation never goes metastable: the first flop always
// captures the new value cleanly, so a CDC bug passes every normal test.
// Compile with +define+CDC_META_SIM and the first flop models the real
// thing: a bit whose input changed within a short window before the clock
// edge (setup/hold, `CDC_META_WINDOW, default 1 ns) resolves to its old or
// new value at random, independently of the other bits. Bits that changed
// earlier are captured cleanly, as they are in silicon. A design with a CDC
// bug then fails in simulation too.

module sync_2ff #(
    parameter W = 1,
    parameter [W-1:0] RESET_VAL = {W{1'b0}}
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [W-1:0] d,        // from the other clock domain
    output wire [W-1:0] q         // safe to use in this domain
);

    (* ASYNC_REG = "TRUE" *) reg [W-1:0] meta;
    (* ASYNC_REG = "TRUE" *) reg [W-1:0] sync;

`ifdef CDC_META_SIM
  `ifndef CDC_META_WINDOW
    `define CDC_META_WINDOW 1.0
  `endif
    // Simulation only. When did each input bit last change?
    realtime t_chg [0:W-1];
    genvar g;
    for (g = 0; g < W; g = g + 1) begin : g_watch
        initial t_chg[g] = -1.0e9;
        always @(d[g]) t_chg[g] = $realtime;
    end

    reg [W-1:0] pick;
    integer     i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            meta <= RESET_VAL;
            sync <= RESET_VAL;
        end else begin
            // A bit that changed just before this edge may still read as its
            // old value (the inverse of the new one, since it changed once).
            for (i = 0; i < W; i = i + 1)
                pick[i] = ($realtime - t_chg[i] < `CDC_META_WINDOW && ($urandom & 1))
                          ? ~d[i] : d[i];
            meta <= pick;
            sync <= meta;
        end
    end
`else
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            meta <= RESET_VAL;
            sync <= RESET_VAL;
        end else begin
            meta <= d;
            sync <= meta;
        end
    end
`endif

    assign q = sync;

endmodule

`default_nettype wire
