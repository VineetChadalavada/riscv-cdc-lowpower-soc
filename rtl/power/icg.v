`default_nettype none

// minisoc -- integrated clock gate (ICG): turns a clock off without
// glitching it.
//
// Gating a clock with a plain AND gate is unsafe: if `en` changes while the
// clock is high, the output gets a short pulse -- a glitch that clocks some
// flops and not others. So `en` goes through a latch that is transparent
// only while the clock is LOW. While the clock is high the latch holds, so
// the gate's enable cannot change in the middle of a high phase, and the
// output only ever has whole clock pulses.
//
// In an ASIC this is one standard cell (the library's ICG). This model is
// what that cell does. On an FPGA the equivalent is a BUFGCE.

module icg (
    input  wire clk,
    input  wire en,
    output wire gclk
);

    reg en_latched;
    always @(*)
        if (!clk) en_latched = en;

    assign gclk = clk & en_latched;

endmodule

`default_nettype wire
