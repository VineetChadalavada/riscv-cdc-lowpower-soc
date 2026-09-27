`default_nettype none

// minisoc -- APB address decoder: one master, two slaves.
//
//   paddr[15:12] = 0   UART
//   paddr[15:12] = 1   timer
//   anything else      no slave: the decoder answers itself, at once, with
//                      PSLVERR, so a stray access faults instead of hanging
//                      the bus waiting for a PREADY that never comes.

module apb_decoder (
    input  wire        psel,
    input  wire [15:0] paddr,
    output wire [31:0] prdata,
    output wire        pready,
    output wire        pslverr,

    output wire        psel_uart,
    input  wire [31:0] prdata_uart,
    input  wire        pready_uart,
    input  wire        pslverr_uart,

    output wire        psel_timer,
    input  wire [31:0] prdata_timer,
    input  wire        pready_timer,
    input  wire        pslverr_timer
);

    wire hit_uart  = (paddr[15:12] == 4'h0);
    wire hit_timer = (paddr[15:12] == 4'h1);

    assign psel_uart  = psel && hit_uart;
    assign psel_timer = psel && hit_timer;

    assign prdata  = hit_uart  ? prdata_uart  : hit_timer ? prdata_timer  : 32'd0;
    assign pready  = hit_uart  ? pready_uart  : hit_timer ? pready_timer  : 1'b1;
    assign pslverr = hit_uart  ? pslverr_uart : hit_timer ? pslverr_timer : 1'b1;

endmodule

`default_nettype wire
