`default_nettype none

// minisoc -- transmit-only UART on APB. 8 data bits, no parity, 1 stop bit.
//
// Registers (byte offsets)
//   0x0  TXDATA  write: send a byte
//   0x4  STATUS  read:  bit 0 = busy (a byte is being shifted out)
//   0x8  DIV     read/write: clock cycles per bit, minus 1
//
// A write to TXDATA while a byte is still going out is not dropped and not
// an error: the slave holds PREADY low until the shifter is free, so the
// write simply takes longer. This is the APB wait state, and it is what
// makes the bridge latency vary with what the peripheral is doing.

module apb_uart_tx (
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
    output wire        tx
);

    localparam [3:0] R_TXDATA = 4'h0, R_STATUS = 4'h4, R_DIV = 4'h8;

    reg [15:0] div;
    reg [15:0] baud_cnt;
    reg [3:0]  bits_left;       // 10 = start + 8 data + stop; 0 = idle
    reg [9:0]  shifter;         // LSB goes out first

    wire busy   = (bits_left != 4'd0);
    wire access = psel && penable;
    wire tx_wr  = access && pwrite && (paddr == R_TXDATA);

    assign pready  = !(tx_wr && busy);                 // stall a write while busy
    assign pslverr = access && !(paddr == R_TXDATA || paddr == R_STATUS || paddr == R_DIV);
    assign tx      = busy ? shifter[0] : 1'b1;         // line idles high

    always @(*) begin
        case (paddr)
            R_STATUS: prdata = {31'd0, busy};
            R_DIV:    prdata = {16'd0, div};
            default:  prdata = 32'd0;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div       <= 16'd15;
            baud_cnt  <= 16'd0;
            bits_left <= 4'd0;
            shifter   <= 10'h3FF;
        end else begin
            if (access && pwrite && paddr == R_DIV) div <= pwdata[15:0];

            if (tx_wr && !busy) begin
                shifter   <= {1'b1, pwdata[7:0], 1'b0};   // stop, data, start
                bits_left <= 4'd10;
                baud_cnt  <= div;
            end else if (busy) begin
                if (baud_cnt == 16'd0) begin
                    shifter   <= {1'b1, shifter[9:1]};
                    bits_left <= bits_left - 4'd1;
                    baud_cnt  <= div;
                end else
                    baud_cnt  <= baud_cnt - 16'd1;
            end
        end
    end

endmodule

`default_nettype wire
