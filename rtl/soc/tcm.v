`default_nettype none

// minisoc -- on-chip RAM with two ports: one for instruction fetch, one for
// data. Both run on clk_core.
//
// Synchronous read (the address is registered, data comes out the next
// cycle), which is what FPGA block RAM and ASIC SRAM macros both provide.
// Each access therefore takes two cycles: request, then ready. That halves
// fetch bandwidth compared with a cache hit; it is a deliberate
// simplification, and the performance counters show its cost.

module tcm #(
    parameter WORDS = 4096                // 16 KiB
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        i_valid,
    input  wire [31:0] i_addr,
    output reg         i_ready,
    output reg  [31:0] i_rdata,

    input  wire        d_valid,
    input  wire [31:0] d_addr,
    input  wire [31:0] d_wdata,
    input  wire [3:0]  d_wstrb,
    output reg         d_ready,
    output reg  [31:0] d_rdata
);

    localparam AW = $clog2(WORDS);

    reg [31:0] mem [0:WORDS-1];

    wire [AW-1:0] i_idx = i_addr[AW+1:2];
    wire [AW-1:0] d_idx = d_addr[AW+1:2];

    // ready pulses for one cycle, the cycle after the request is seen
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i_ready <= 1'b0;
            d_ready <= 1'b0;
        end else begin
            i_ready <= i_valid && !i_ready;
            d_ready <= d_valid && !d_ready;
        end
    end

    // memory array: no reset, so it maps onto RAM rather than flops
    integer b;
    always @(posedge clk) begin
        i_rdata <= mem[i_idx];
        d_rdata <= mem[d_idx];
        if (d_valid && !d_ready)
            for (b = 0; b < 4; b = b + 1)
                if (d_wstrb[b]) mem[d_idx][8*b +: 8] <= d_wdata[8*b +: 8];
    end

endmodule

`default_nettype wire
