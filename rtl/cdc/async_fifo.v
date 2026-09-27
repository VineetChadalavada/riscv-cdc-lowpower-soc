`default_nettype none

// minisoc -- asynchronous FIFO: moves a stream of words between two clock
// domains that have no fixed relationship.
//
//   write side (wclk)                         read side (rclk)
//   ┌──────────────┐    memory, written by    ┌──────────────┐
//   │ write pointer│──► wclk, read by rclk ──►│ read pointer │
//   │  wfull       │                          │  rempty      │
//   └──────┬───────┘                          └──────┬───────┘
//          │  Gray-coded pointers, each synchronized │
//          └───────────────◄──── sync_2ff ◄──────────┘
//          └─────────────── sync_2ff ────►───────────┘
//
// Each side keeps its own pointer and needs to see the other side's pointer
// to know whether the FIFO is full or empty. Pointers are multi-bit, so they
// cross as Gray code: consecutive Gray values differ in exactly one bit, so a
// synchronizer catching the pointer mid-change sees either the old value or
// the new one -- never a mix that points somewhere random.
//
// Pointers are one bit wider than the address. The extra bit tells "full"
// (write has lapped read) from "empty" (they are equal) when the address
// bits match.
//
// Both flags are pessimistic, which is what makes this safe. The write side
// sees a read pointer that is 2-3 cycles old, so it may think the FIFO is
// fuller than it is -- never emptier. Likewise the read side may see empty
// for a couple of cycles after a write. Neither loses data; both only cost
// latency.
//
// The design follows Cliff Cummings, "Simulation and Synthesis Techniques
// for Asynchronous FIFO Design" (SNUG 2002), the standard reference.

module async_fifo #(
    parameter DW = 32,          // data width
    parameter AW = 3            // address width: depth = 2**AW, AW >= 2
) (
    // write domain
    input  wire          wclk,
    input  wire          wrst_n,
    input  wire          winc,      // write wdata this cycle (ignored if full)
    input  wire [DW-1:0] wdata,
    output reg           wfull,

    // read domain
    input  wire          rclk,
    input  wire          rrst_n,
    input  wire          rinc,      // pop rdata this cycle (ignored if empty)
    output wire [DW-1:0] rdata,     // head of the FIFO, valid while !rempty
    output reg           rempty
);

    localparam DEPTH = 1 << AW;

    reg [DW-1:0] mem [0:DEPTH-1];

    // Both sides' pointers are declared up front, because each side's logic
    // refers to the other side's pointer.
    reg  [AW:0] wbin, wgray;                     // write domain
    reg  [AW:0] rbin, rgray;                     // read domain
    wire [AW:0] rgray_w;                         // read pointer, synchronized into wclk
    wire [AW:0] wgray_r;                         // write pointer, synchronized into rclk

    // ---------------- write domain ----------------
    wire [AW:0] wbin_next  = wbin + {{AW{1'b0}}, (winc & ~wfull)};
    wire [AW:0] wgray_next = (wbin_next >> 1) ^ wbin_next;

    // Full: the next write pointer has lapped the read pointer exactly once.
    // In Gray code that is "top two bits inverted, the rest equal".
    wire wfull_next = (wgray_next == {~rgray_w[AW:AW-1], rgray_w[AW-2:0]});

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wbin  <= 0;
            wgray <= 0;
            wfull <= 1'b0;
        end else begin
            wbin  <= wbin_next;
            wgray <= wgray_next;
            wfull <= wfull_next;
        end
    end

    always @(posedge wclk)
        if (winc && !wfull) mem[wbin[AW-1:0]] <= wdata;

    sync_2ff #(.W(AW+1)) u_sync_r2w (.clk(wclk), .rst_n(wrst_n), .d(rgray), .q(rgray_w));

    // ---------------- read domain ----------------
    wire [AW:0] rbin_next  = rbin + {{AW{1'b0}}, (rinc & ~rempty)};
    wire [AW:0] rgray_next = (rbin_next >> 1) ^ rbin_next;

    // Empty: after this read, the read pointer has caught up with the write
    // pointer.
    wire rempty_next = (rgray_next == wgray_r);

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rbin   <= 0;
            rgray  <= 0;
            rempty <= 1'b1;
        end else begin
            rbin   <= rbin_next;
            rgray  <= rgray_next;
            rempty <= rempty_next;
        end
    end

    // Read straight from the memory: the word at the head is always on
    // rdata (first-word fall-through), so a read costs no extra cycle.
    assign rdata = mem[rbin[AW-1:0]];

    sync_2ff #(.W(AW+1)) u_sync_w2r (.clk(rclk), .rst_n(rrst_n), .d(wgray), .q(wgray_r));

endmodule

`default_nettype wire
