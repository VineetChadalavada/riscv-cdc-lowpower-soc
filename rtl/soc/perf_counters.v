`default_nettype none

// minisoc -- performance counters, readable by software (clk_core).
//
// Registers (byte offsets)
//   0x00  CYCLES        clock cycles since reset or clear
//   0x04  FETCHES       instruction fetches completed
//   0x08  P_ACCESSES    accesses to the peripheral bus (through the bridge)
//   0x0C  P_CYCLES      total core cycles those accesses took, first to last
//   0x10  P_MAX         the longest single peripheral access, in core cycles
//   0x14  CLEAR         write anything: zero all counters
//   0x18  SLEEP         cycles the core spent with its clock stopped
//
// These counters are in the always-on domain and keep counting while the
// core is powered down, so software can see how long it slept.
//
// P_CYCLES / P_ACCESSES is the average latency of crossing to the
// peripheral clock domain and back, as the core sees it. It is measured on
// the real design, so it includes FIFO synchronization, the APB transfer and
// any wait states the peripheral inserts.
//
// Reads answer in the same cycle (no wait state).

module perf_counters (
    input  wire        clk,
    input  wire        rst_n,

    // bus slave
    input  wire        valid,
    input  wire [7:0]  addr,
    input  wire        write,
    output wire        ready,
    output reg  [31:0] rdata,

    // events
    input  wire        ev_fetch,        // an instruction fetch completed
    input  wire        ev_sleep,        // the core's clock is stopped this cycle
    input  wire        p_valid,         // the core is waiting on the bridge
    input  wire        p_ready          // the bridge answered
);

    reg [31:0] cycles, fetches, p_accesses, p_cycles, p_max, sleep;
    reg [31:0] p_cur;                    // cycles into the current access

    wire clear = valid && write && (addr == 8'h14);
    wire [31:0] p_this = p_cur + 32'd1;  // length of an access ending now

    assign ready = valid;

    always @(*) begin
        case (addr)
            8'h00:   rdata = cycles;
            8'h04:   rdata = fetches;
            8'h08:   rdata = p_accesses;
            8'h0C:   rdata = p_cycles;
            8'h10:   rdata = p_max;
            8'h18:   rdata = sleep;
            default: rdata = 32'd0;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        // Clear is synchronous and kept out of the reset branch: folding it
        // into `if (!rst_n || clear)` would describe a flop with an
        // asynchronous reset driven by logic, which is not what is meant.
        if (!rst_n) begin
            cycles <= 0; fetches <= 0; p_accesses <= 0; p_cycles <= 0; p_max <= 0; p_cur <= 0; sleep <= 0;
        end else if (clear) begin
            cycles <= 0; fetches <= 0; p_accesses <= 0; p_cycles <= 0; p_max <= 0; p_cur <= 0; sleep <= 0;
        end else begin
            cycles <= cycles + 32'd1;
            if (ev_sleep) sleep <= sleep + 32'd1;
            if (ev_fetch) fetches <= fetches + 32'd1;
            if (p_valid && p_ready) begin
                p_accesses <= p_accesses + 32'd1;
                p_cycles   <= p_cycles + p_this;
                if (p_this > p_max) p_max <= p_this;
                p_cur      <= 32'd0;
            end else if (p_valid)
                p_cur      <= p_this;
        end
    end

endmodule

`default_nettype wire
