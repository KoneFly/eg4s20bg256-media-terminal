// SPI Mode 0 byte engine — MSB-first, 8-bit full-duplex transfer
// CPOL=0, CPHA=0: SCK idle low, sample MISO on rising edge, update MOSI on falling edge
// All sequential state driven by system clock; SCK is output only, never a clock domain

`timescale 1ns/1ps

module fdi_sd_spi_byte_engine #(
    parameter DIV_WIDTH = 16
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 start,
    input  wire [7:0]           tx_byte,
    input  wire [DIV_WIDTH-1:0] clk_divider,
    input  wire                 spi_miso,
    output reg                  spi_sck,
    output reg                  spi_mosi,
    output reg  [7:0]           rx_byte,
    output reg                  busy,
    output reg                  done
);

    // State encoding
    localparam [1:0] ST_IDLE      = 2'd0,
                     ST_WAIT_RISE = 2'd1,
                     ST_WAIT_FALL = 2'd2;

    reg [1:0] state;

    // Latched transfer parameters (captured atomically on request acceptance)
    reg [7:0]            tx_latched;
    reg [DIV_WIDTH-1:0]  half_period_m1;   // = clk_divider at acceptance; half period = half_period_m1 + 1

    // Timing and bit-position counters
    reg [DIV_WIDTH:0]    half_cnt;         // counts system clocks within one SCK half-period
    reg [2:0]            bit_cnt;          // current bit index: 7 = MSB first, 0 = LSB last

    // Internal receive shift register (accumulates MISO samples MSB-first)
    reg [7:0]            rx_latched;

    // All sequential logic: async active-low reset, positive-edge system clock
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= ST_IDLE;
            spi_sck        <= 1'b0;
            spi_mosi       <= 1'b1;
            rx_byte        <= 8'h00;
            busy           <= 1'b0;
            done           <= 1'b0;
            tx_latched     <= 8'hFF;
            half_period_m1 <= {DIV_WIDTH{1'b0}};
            half_cnt       <= {(DIV_WIDTH + 1){1'b0}};
            bit_cnt        <= 3'd7;
            rx_latched     <= 8'h00;
        end else begin
            // Default: done deasserts every cycle unless explicitly overridden below
            done <= 1'b0;

            case (state)
                // ----------------------------------------------------------
                // IDLE: SCK low, busy deasserted. Accept request on start.
                // ----------------------------------------------------------
                ST_IDLE: begin
                    spi_sck  <= 1'b0;
                    busy     <= 1'b0;
                    if (start) begin
                        // Latch all transfer parameters atomically
                        tx_latched     <= tx_byte;
                        half_period_m1 <= clk_divider;
                        half_cnt       <= {(DIV_WIDTH + 1){1'b0}};
                        bit_cnt        <= 3'd7;
                        rx_latched     <= 8'h00;
                        // Drive first MOSI bit (MSB = tx_byte[7]) before any SCK edge
                        spi_mosi       <= tx_byte[7];
                        busy           <= 1'b1;
                        state          <= ST_WAIT_RISE;
                    end
                end

                // ----------------------------------------------------------
                // WAIT_RISE: hold SCK low for one programmed half-period.
                // When the half-period expires, generate the SCK rising edge
                // and sample MISO directly into the current result bit.
                // ----------------------------------------------------------
                ST_WAIT_RISE: begin
                    spi_sck <= 1'b0;
                    if (half_cnt == {1'b0, half_period_m1}) begin
                        spi_sck                <= 1'b1;
                        rx_latched[bit_cnt]     <= spi_miso;
                        half_cnt               <= {(DIV_WIDTH + 1){1'b0}};
                        state                  <= ST_WAIT_FALL;
                    end else begin
                        half_cnt <= half_cnt + 1'd1;
                    end
                end

                // ----------------------------------------------------------
                // WAIT_FALL: hold SCK high for one programmed half-period.
                // On expiry, generate the falling edge and prepare the next
                // MOSI bit while SCK is low. The eighth falling edge closes
                // the byte transaction.
                // ----------------------------------------------------------
                ST_WAIT_FALL: begin
                    spi_sck <= 1'b1;
                    if (half_cnt == {1'b0, half_period_m1}) begin
                        spi_sck  <= 1'b0;
                        half_cnt <= {(DIV_WIDTH + 1){1'b0}};
                        if (bit_cnt == 3'd0) begin
                            // The eighth falling edge closes the transaction.
                            // The last receive bit was captured on the preceding
                            // rising edge, so the complete byte is now stable.
                            rx_byte  <= rx_latched;
                            busy     <= 1'b0;
                            done     <= 1'b1;
                            spi_mosi <= 1'b1;
                            state    <= ST_IDLE;
                        end else begin
                            bit_cnt  <= bit_cnt - 1'd1;
                            spi_mosi <= tx_latched[bit_cnt - 1'd1];
                            state    <= ST_WAIT_RISE;
                        end
                    end else begin
                        half_cnt <= half_cnt + 1'd1;
                    end
                end

                default: begin
                    state      <= ST_IDLE;
                    spi_sck    <= 1'b0;
                    spi_mosi   <= 1'b1;
                    busy       <= 1'b0;
                    half_cnt   <= {(DIV_WIDTH + 1){1'b0}};
                    bit_cnt    <= 3'd7;
                    rx_latched <= 8'h00;
                end
            endcase
        end
    end

endmodule
