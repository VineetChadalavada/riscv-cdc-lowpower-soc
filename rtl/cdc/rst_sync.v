`default_nettype none

// minisoc -- reset synchronizer: asynchronous assert, synchronous release.
//
// Every clock domain gets its own copy.
//
// ASSERT is asynchronous: the moment the external reset goes low, the
// output goes low, even with no clock running.
//
// RELEASE is synchronous: the output goes high only on a clock edge, two
// edges after the external reset goes high. Released straight from a pin,
// reset could let go close to a clock edge -- some flops would leave reset
// this cycle and some the next, and a state machine could start in an
// illegal state. Released from a flop, it is an ordinary timed signal that
// static timing analysis checks (recovery/removal).

module rst_sync (
    input  wire clk,
    input  wire arst_n,       // asynchronous reset, from a pin
    output wire rst_n         // reset for this clock domain
);

    (* ASYNC_REG = "TRUE" *) reg r0, r1;

    always @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            r0 <= 1'b0;
            r1 <= 1'b0;
        end else begin
            r0 <= 1'b1;
            r1 <= r0;
        end
    end

    assign rst_n = r1;

endmodule

`default_nettype wire
