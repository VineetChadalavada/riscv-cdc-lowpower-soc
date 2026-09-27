`default_nettype none

// minisoc -- power management unit. Always on. Turns the core's power
// domain off when software asks, and back on when the timer interrupt fires.
//
// Registers (byte offsets, at 0x3000_0000)
//   0x0  CTRL    write 1: go to sleep
//   0x4  STATUS  read: bit 0 = the core has just woken up (it rebooted
//                because of a wake-up, not a cold reset). Write 1 to clear.
//   0x8  STATE   read: the sequencer's current state, for debug
//
// POWER-DOWN, one step per clock:
//   DRAIN    wait until the bridge has no access in flight. Cutting power
//            with a transfer half done would leave the peripheral side
//            waiting for a core that no longer exists.
//   ISOLATE  clamp the core's outputs. From here on nothing the core drives
//            reaches the rest of the chip, so it no longer matters what they do.
//   CLK_OFF  stop the core's clock (through the ICG).
//   RESET    hold the core in reset.
//   OFF      cut the power. Wait for the wake-up.
//
// POWER-UP, the same steps in reverse:
//   PWR_UP   switch power back on; wait PWR_DELAY cycles for the supply to
//            settle (in silicon, the power switch reports "power good").
//   CLK_ON   restart the clock, still in reset, so every flop sees clock
//            edges while reset is asserted and starts from its reset value.
//   RELEASE  release reset.
//   UNISO    remove the isolation clamps. The core is running.
//
// The order is the point. Isolation must be on before power goes off and
// stay on until power is back and the core has left reset, or the rest of
// the chip sees the core's outputs float. The testbench checks each of
// these rules with an assertion.

module pmu #(
    parameter PWR_DELAY = 8
) (
    input  wire        clk,             // clk_core, never gated
    input  wire        rst_n,

    // bus slave
    input  wire        valid,
    input  wire [3:0]  addr,
    input  wire        write,
    input  wire [31:0] wdata,
    output wire        ready,
    output reg  [31:0] rdata,

    input  wire        bridge_busy,     // an access to the peripherals is in flight
    input  wire        wake,            // wake-up request (timer interrupt, synchronized)

    output reg         pwr_on,          // power switch for the core domain
    output reg         iso_en,          // isolation clamps on the core's outputs
    output reg         clk_en,          // core clock enable (to the ICG)
    output reg         core_rst_n       // core reset, 0 = held in reset
);

    localparam [3:0] S_RUN = 4'd0, S_DRAIN = 4'd1, S_ISOLATE = 4'd2, S_CLK_OFF = 4'd3,
                     S_RESET = 4'd4, S_OFF = 4'd5, S_PWR_UP = 4'd6, S_CLK_ON = 4'd7,
                     S_RELEASE = 4'd8, S_UNISO = 4'd9;

    reg [3:0] state;
    reg [7:0] wait_cnt;
    reg       woke;

    wire sleep_req = valid && write && (addr == 4'h0) && wdata[0];
    wire clr_woke  = valid && write && (addr == 4'h4) && wdata[0];

    assign ready = valid;

    always @(*) begin
        case (addr)
            4'h4:    rdata = {31'd0, woke};
            4'h8:    rdata = {28'd0, state};
            default: rdata = 32'd0;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_RUN;
            wait_cnt   <= 8'd0;
            woke       <= 1'b0;
            pwr_on     <= 1'b1;
            iso_en     <= 1'b0;
            clk_en     <= 1'b1;
            core_rst_n <= 1'b1;
        end else begin
            if (clr_woke) woke <= 1'b0;

            case (state)
                S_RUN:     if (sleep_req)    state <= S_DRAIN;
                S_DRAIN:   if (!bridge_busy) state <= S_ISOLATE;
                S_ISOLATE: begin iso_en <= 1'b1;     state <= S_CLK_OFF; end
                S_CLK_OFF: begin clk_en <= 1'b0;     state <= S_RESET;   end
                S_RESET:   begin core_rst_n <= 1'b0; state <= S_OFF;     end
                S_OFF: begin
                    pwr_on <= 1'b0;
                    if (wake && !pwr_on) begin   // at least one cycle fully off
                        pwr_on   <= 1'b1;
                        wait_cnt <= PWR_DELAY;
                        state    <= S_PWR_UP;
                    end
                end
                S_PWR_UP:  if (wait_cnt == 0) state <= S_CLK_ON;
                           else wait_cnt <= wait_cnt - 8'd1;
                S_CLK_ON:  begin clk_en <= 1'b1;     wait_cnt <= 8'd2; state <= S_RELEASE; end
                S_RELEASE: if (wait_cnt == 0) begin core_rst_n <= 1'b1; state <= S_UNISO; end
                           else wait_cnt <= wait_cnt - 8'd1;
                S_UNISO:   begin iso_en <= 1'b0;     woke <= 1'b1;     state <= S_RUN; end
                default:   state <= S_RUN;
            endcase
        end
    end

endmodule

`default_nettype wire
