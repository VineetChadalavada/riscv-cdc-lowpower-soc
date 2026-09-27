`default_nettype none

// minisoc -- one-cycle pulse from one clock domain to another.
//
// A one-cycle pulse cannot go through a plain two-flop synchronizer: if the
// destination clock is slower, the pulse can fall between two destination
// edges and vanish. So the source turns each pulse into a level change (a
// toggle), the toggle crosses -- a level cannot be missed -- and the
// destination turns each change back into a pulse.
//
//   src_pulse  _|‾|___________|‾|________
//   src_toggle ___|‾‾‾‾‾‾‾‾‾‾‾‾‾|________
//   dst_pulse  ________|‾|___________|‾|_   (2-3 destination cycles later)
//
// RULE: do not send a new pulse while src_busy is high. Two pulses that
// toggle the level twice before the destination samples it are both lost.
// src_busy stays high until the destination's view of the toggle has come
// back across, so it covers any clock ratio.

module pulse_sync (
    input  wire src_clk,
    input  wire src_rst_n,
    input  wire src_pulse,
    output wire src_busy,

    input  wire dst_clk,
    input  wire dst_rst_n,
    output wire dst_pulse
);

    // source domain: pulse -> toggle
    reg src_toggle;
    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n)     src_toggle <= 1'b0;
        else if (src_pulse) src_toggle <= ~src_toggle;
    end

    // destination domain: synchronize, then toggle -> pulse
    wire dst_toggle;
    sync_2ff u_fwd (.clk(dst_clk), .rst_n(dst_rst_n), .d(src_toggle), .q(dst_toggle));

    reg dst_toggle_q;
    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) dst_toggle_q <= 1'b0;
        else            dst_toggle_q <= dst_toggle;
    end
    assign dst_pulse = dst_toggle ^ dst_toggle_q;

    // back to the source: busy until the destination has caught up
    wire src_ack;
    sync_2ff u_ack (.clk(src_clk), .rst_n(src_rst_n), .d(dst_toggle_q), .q(src_ack));
    assign src_busy = src_toggle ^ src_ack;

endmodule

`default_nettype wire
