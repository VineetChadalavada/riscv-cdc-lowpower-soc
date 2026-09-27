`default_nettype none

// minisoc -- bridge from the core's data bus (clk_core) to an APB bus
// (clk_periph), where the two clocks are unrelated.
//
//   clk_core                        │  clk_periph
//                                   │
//   core request ──► request FIFO ──┼──► APB master ──► PSEL/PENABLE/...
//   (valid/ready)                   │    (IDLE→SETUP→ACCESS)
//   core response ◄─ response FIFO ◄┼─── PRDATA/PSLVERR when PREADY
//
// Everything that crosses goes through an async_fifo, so the only CDC in
// this block is the one already verified there. Nothing else in the two
// halves talks to the other side.
//
// One access at a time: the core never has more than one data access in
// flight, so the FIFOs never hold more than one entry. They are 4 deep
// because that is the smallest async_fifo (AW = 2).
//
// Latency, for an APB slave with no wait states: the request crosses (~3
// periph clocks), the APB transfer takes 2 periph clocks, the response
// crosses back (~3 core clocks) and is registered (1 core clock).
// perf_counters measures it.
//
// Why the response is registered before the core sees it: read straight
// from the FIFO, the fault bit went combinationally into the core's stall
// logic and from there to the enables of hundreds of pipeline registers.
// That is logically safe -- the data is only used once the synchronized
// empty flag says it is stable -- but it spreads the crossing through the
// whole core, and Vivado's report_cdc flagged 380 critical paths from it.
// Registered, the crossing ends at one register loaded under a synchronized
// enable: the standard FIFO pattern, confined to this block.

module cdc_apb_bridge (
    // ---- core side (clk_core) ----
    input  wire        clk_core,
    input  wire        rst_core_n,
    input  wire        c_valid,
    input  wire [31:0] c_addr,
    input  wire [31:0] c_wdata,
    input  wire [3:0]  c_wstrb,          // nonzero = write
    output wire        c_ready,
    output wire [31:0] c_rdata,
    output wire        c_fault,
    output wire        c_busy,          // an access is in flight (for the PMU)

    // ---- APB side (clk_periph) ----
    input  wire        clk_periph,
    input  wire        rst_periph_n,
    output reg  [15:0] paddr,
    output reg         psel,
    output reg         penable,
    output reg         pwrite,
    output reg  [31:0] pwdata,
    output reg  [3:0]  pstrb,
    input  wire [31:0] prdata,
    input  wire        pready,
    input  wire        pslverr
);

    // =====================================================================
    // core side
    // =====================================================================
    // A request is pushed once, then the core waits for the response.
    reg  c_waiting;
    wire req_wfull, rsp_rempty;
    wire req_push = c_valid && !c_waiting && !req_wfull;

    wire [32:0] rsp_head;                // {pslverr, prdata}, straight from the FIFO
    reg  [32:0] c_rsp;                   // the same, registered in clk_core
    reg         c_rsp_valid;
    wire        rsp_pop = c_waiting && !rsp_rempty && !c_rsp_valid;

    assign c_ready = c_rsp_valid;
    assign c_busy  = c_waiting;
    assign c_rdata = c_rsp[31:0];
    assign c_fault = c_rsp[32];

    always @(posedge clk_core or negedge rst_core_n) begin
        if (!rst_core_n) begin
            c_waiting   <= 1'b0;
            c_rsp_valid <= 1'b0;
        end else begin
            if (req_push)     c_waiting <= 1'b1;
            else if (c_ready) c_waiting <= 1'b0;
            c_rsp_valid <= rsp_pop;              // ready for exactly one cycle
        end
    end

    // no reset: a data register, only looked at while c_rsp_valid is high
    always @(posedge clk_core)
        if (rsp_pop) c_rsp <= rsp_head;

    // =====================================================================
    // the two crossings
    // =====================================================================
    // request: {write, strobes, address, data}
    wire [52:0] req_head;
    wire        req_rempty;
    reg         req_pop;

    async_fifo #(.DW(53), .AW(2)) u_req (
        .wclk(clk_core),   .wrst_n(rst_core_n),   .winc(req_push),
        .wdata({|c_wstrb, c_wstrb, c_addr[15:0], c_wdata}), .wfull(req_wfull),
        .rclk(clk_periph), .rrst_n(rst_periph_n), .rinc(req_pop),
        .rdata(req_head), .rempty(req_rempty)
    );

    reg         rsp_push;
    reg  [32:0] rsp_data;
    wire        rsp_wfull;               // never full: one access in flight

    async_fifo #(.DW(33), .AW(2)) u_rsp (
        .wclk(clk_periph), .wrst_n(rst_periph_n), .winc(rsp_push),
        .wdata(rsp_data), .wfull(rsp_wfull),
        .rclk(clk_core),   .rrst_n(rst_core_n),   .rinc(rsp_pop),
        .rdata(rsp_head), .rempty(rsp_rempty)
    );

    // =====================================================================
    // APB master (clk_periph)
    // =====================================================================
    localparam [1:0] S_IDLE = 2'd0, S_SETUP = 2'd1, S_ACCESS = 2'd2;
    reg [1:0] state;

    always @(posedge clk_periph or negedge rst_periph_n) begin
        if (!rst_periph_n) begin
            state    <= S_IDLE;
            psel     <= 1'b0;
            penable  <= 1'b0;
            pwrite   <= 1'b0;
            paddr    <= 16'd0;
            pwdata   <= 32'd0;
            pstrb    <= 4'd0;
            req_pop  <= 1'b0;
            rsp_push <= 1'b0;
            rsp_data <= 33'd0;
        end else begin
            req_pop  <= 1'b0;
            rsp_push <= 1'b0;
            case (state)
                S_IDLE: if (!req_rempty && !req_pop) begin
                    // take the request off the FIFO and drive the SETUP phase
                    {pwrite, pstrb, paddr, pwdata} <= req_head;
                    psel    <= 1'b1;
                    req_pop <= 1'b1;
                    state   <= S_SETUP;
                end
                S_SETUP: begin
                    penable <= 1'b1;
                    state   <= S_ACCESS;
                end
                S_ACCESS: if (pready) begin
                    // the slave has finished: send the result back
                    psel     <= 1'b0;
                    penable  <= 1'b0;
                    rsp_data <= {pslverr, pwrite ? 32'd0 : prdata};
                    rsp_push <= 1'b1;
                    state    <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
