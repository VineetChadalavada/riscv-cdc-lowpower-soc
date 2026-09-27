// TinyTrust — RV32I register file: 32 x 32-bit, 2 async read / 1 sync write
//
// x0 is not stored; reads of x0 return zero, writes to x0 are dropped.
// DFF-based (decision D3); the latch-based area fallback is no longer needed
// on a full die (see docs/RETARGET.md D18 — RV32E -> RV32I).
//
// WRITE_THROUGH (P2): when set, a read of the address being written in the
// same cycle returns the new data. The multicycle core leaves it 0 (it never
// reads and writes in one cycle, and the default keeps its netlist and the
// P1 area numbers unchanged). The 5-stage core sets it: an instruction three
// slots behind a producer reads the file in ID on the very cycle the producer
// writes it in WB, which is one hop too far for the EX forwarding network.

module regfile #(
    parameter WRITE_THROUGH = 0
) (
    input  wire        clk,

    input  wire        we,
    input  wire [4:0]  waddr,
    input  wire [31:0] wdata,

    input  wire [4:0]  raddr1,
    output wire [31:0] rdata1,
    input  wire [4:0]  raddr2,
    output wire [31:0] rdata2
);

    reg [31:0] regs [1:31];

    always @(posedge clk) begin
        if (we && waddr != 5'd0)
            regs[waddr] <= wdata;
    end

    wire [31:0] raw1 = (raddr1 == 5'd0) ? 32'd0 : regs[raddr1];
    wire [31:0] raw2 = (raddr2 == 5'd0) ? 32'd0 : regs[raddr2];

    wire wt1 = (WRITE_THROUGH != 0) && we && (waddr != 5'd0)
               && (raddr1 == waddr);
    wire wt2 = (WRITE_THROUGH != 0) && we && (waddr != 5'd0)
               && (raddr2 == waddr);

    assign rdata1 = wt1 ? wdata : raw1;
    assign rdata2 = wt2 ? wdata : raw2;

endmodule
