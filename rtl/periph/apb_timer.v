`default_nettype none

// minisoc -- timer on APB, with an interrupt.
//
// Registers (byte offsets)
//   0x0  COUNT   read: free-running counter while enabled
//   0x4  CMP     read/write: when COUNT reaches CMP, the interrupt is raised
//   0x8  CTRL    read/write: bit 0 = count enable, bit 1 = interrupt enable
//   0xC  STATUS  read: bit 0 = match pending. Write 1 to clear.
//
// irq is a LEVEL in the peripheral clock domain. It stays high until
// software clears STATUS, which is what lets it cross into the core's clock
// domain through a plain two-flop synchronizer: a level cannot be missed,
// however slow the destination clock is. A one-cycle pulse could be.
//
// irq comes straight from a flop. An earlier version drove it from a gate,
// `pending && irq_en`, and report_cdc flagged it (CDC-10): when the inputs
// of a gate change, its output can glitch for a moment, and a synchronizer
// in another clock domain can catch that glitch as a phantom interrupt. A
// flop's output changes once per clock and cannot glitch.

module apb_timer (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [3:0]  paddr,
    input  wire [31:0] pwdata,
    output reg  [31:0] prdata,
    output wire        pready,
    output wire        pslverr,
    output reg         irq
);

    localparam [3:0] R_COUNT = 4'h0, R_CMP = 4'h4, R_CTRL = 4'h8, R_STATUS = 4'hC;

    reg [31:0] count, cmp;
    reg        en, irq_en, pending;

    wire access = psel && penable;
    wire wr     = access && pwrite;

    assign pready  = 1'b1;
    assign pslverr = 1'b0;

    always @(*) begin
        case (paddr)
            R_COUNT:  prdata = count;
            R_CMP:    prdata = cmp;
            R_CTRL:   prdata = {30'd0, irq_en, en};
            R_STATUS: prdata = {31'd0, pending};
            default:  prdata = 32'd0;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count   <= 32'd0;
            cmp     <= 32'hFFFF_FFFF;
            en      <= 1'b0;
            irq_en  <= 1'b0;
            pending <= 1'b0;
            irq     <= 1'b0;
        end else begin
            irq <= pending && irq_en;
            if (en) count <= count + 32'd1;
            if (wr && paddr == R_CMP)  cmp <= pwdata;
            if (wr && paddr == R_CTRL) {irq_en, en} <= pwdata[1:0];

            // a match sets pending; a write of 1 clears it (set wins a tie)
            if (en && count == cmp)                          pending <= 1'b1;
            else if (wr && paddr == R_STATUS && pwdata[0])  pending <= 1'b0;
        end
    end

endmodule

`default_nettype wire
