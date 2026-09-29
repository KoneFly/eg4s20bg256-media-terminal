// ---------------------------------------------------------------------------
// sd_block_reader — SD card SPI-mode single-block reader (Task 004)
//
// Reads exactly one 512-byte data block using CMD17 (READ_SINGLE_BLOCK):
//
//     IDLE -> CMD17_START -> CMD17_WAIT -> TOKEN_WAIT -> DATA_RX (x512)
//          -> CRC_RX (x2) -> CRC_CHECK -> DONE -> IDLE
//
// Responsibilities:
//   * Issue CMD17 through the Task 002 `sd_cmd_transactor` (command frame,
//     CRC7 and R1 response are fully delegated; never re-implemented here).
//   * Wait for the 0xFE data token (bounded by the NAC_TIMEOUT byte budget).
//   * Receive the 512-byte payload and the 2-byte CRC16 through a dedicated
//     `sd_spi_byte_engine` instance (the transactor releases CS after its R1
//     response, so the data phase needs its own byte engine).
//   * Verify the block CRC16 with `crc16_ccitt` and raise crc_error on a
//     mismatch (a CRC error still completes the transaction).
//   * Present the payload as 128 words of 32-bit big-endian data (data_valid
//     pulses once per word).
//
// SPI ownership: chip select is held low for the whole transaction and is
// driven by this module. The command phase SCK/MOSI come from the transactor;
// the data phase SCK/MOSI come from the data byte engine. A two-way mux
// selects between them (command phase while cmd_busy==1, data phase after the
// R1 response is captured). The transactor's cs_n output is intentionally
// ignored — it would release CS too early for a read transaction.
//
// All sequential logic runs on the system clock with an asynchronous active-
// low reset; spi_sck is never used as a clock domain.
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module sd_block_reader #(
    parameter BYTE_DIV_WIDTH = 16,
    parameter NAC_TIMEOUT     = 16'd10000
)(
    input  wire                      clk,
    input  wire                      rst_n,

    // Control interface
    input  wire                      read_start,
    input  wire [31:0]               block_addr,
    output reg                       read_busy,
    output reg                       read_done,
    output reg                       read_timeout,
    output reg                       crc_error,

    // Data output interface
    output reg  [31:0]               data_out,
    output reg                       data_valid,

    // SPI physical interface
    output wire                      spi_cs_n,
    output wire                      spi_sck,
    output wire                      spi_mosi,
    input  wire                      spi_miso,

    // Byte-engine clock divider
    input  wire [BYTE_DIV_WIDTH-1:0] spi_clk_div
);

    // -----------------------------------------------------------------------
    // FSM states
    // -----------------------------------------------------------------------
    localparam [3:0] ST_IDLE       = 4'd0,
                     ST_CMD17_START= 4'd1,
                     ST_CMD17_WAIT = 4'd2,
                     ST_TOKEN_WAIT = 4'd3,
                     ST_DATA_RX    = 4'd4,
                     ST_CRC_RX     = 4'd5,
                     ST_CRC_CHECK  = 4'd6,
                     ST_DONE       = 4'd7;

    localparam [7:0] DATA_TOKEN   = 8'hFE;   // single-block read start token
    localparam [5:0] CMD17        = 6'd17;

    // -----------------------------------------------------------------------
    // Registered state
    // -----------------------------------------------------------------------
    reg [3:0]                state;
    reg [31:0]               addr_latched;

    // Command transactor request/status
    reg                      cmd_start;
    wire                     cmd_busy;
    wire                     cmd_done;
    wire                     cmd_timeout;
    wire [7:0]               resp_r1;
    wire                     resp_valid;

    // Data byte engine request/status
    reg                      data_start;
    wire [7:0]               data_tx_byte;
    wire [7:0]               data_rx_byte;
    wire                     data_busy;
    wire                     data_done;

    // CRC16 path
    reg                      crc_clear;
    reg                      crc_feed;
    reg  [7:0]               crc_byte;
    wire [15:0]              crc_out;

    // Payload counters
    reg  [9:0]               byte_cnt;      // 0..511 payload bytes received
    reg  [1:0]               word_cnt;      // 0..3 within a 32-bit word
    reg  [6:0]               word_index;    // 0..127 words output (informational)

    // Token wait timeout counter
    reg  [15:0]              token_wait;

    // CRC capture / compare
    reg  [15:0]              crc_rx;

    // SPI phase wires — transactor owns SCK/MOSI during the command phase,
    // the data byte engine owns them during the token/data/CRC phase.
    wire                     xactor_cs_n;
    wire                     xactor_sck;
    wire                     xactor_mosi;
    wire                     data_sck;
    wire                     data_mosi;

    // -----------------------------------------------------------------------
    // Command transactor — owns the CMD17 frame, CRC7 and R1 capture.
    // cmd_arg is driven from addr_latched (latched at read_start) so a
    // re-entrant read_start while busy can never alter an in-flight command.
    // -----------------------------------------------------------------------
    sd_cmd_transactor #(
        .BYTE_DIV_WIDTH(BYTE_DIV_WIDTH)
    ) u_cmd_xactor (
        .clk         (clk),
        .rst_n       (rst_n),
        .cmd_start   (cmd_start),
        .cmd_index   (CMD17),
        .cmd_arg     (addr_latched),
        .pre_cond    (1'b0),
        .extra_resp_bytes (3'd0),
        .cmd_busy    (cmd_busy),
        .cmd_done    (cmd_done),
        .cmd_timeout (cmd_timeout),
        .resp_r1     (resp_r1),
        .resp_valid  (resp_valid),
        .spi_cs_n    (xactor_cs_n),
        .spi_sck     (xactor_sck),
        .spi_mosi    (xactor_mosi),
        .spi_miso    (spi_miso),
        .spi_clk_div (spi_clk_div)
    );

    // -----------------------------------------------------------------------
    // Data byte engine — owns the SCK/MOSI generation for the token, payload
    // and CRC bytes. MOSI is held at 0xFF so the card sees idle clock/data.
    // -----------------------------------------------------------------------
    sd_spi_byte_engine #(
        .DIV_WIDTH(BYTE_DIV_WIDTH)
    ) u_data_engine (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (data_start),
        .tx_byte     (data_tx_byte),
        .clk_divider (spi_clk_div),
        .spi_miso    (spi_miso),
        .spi_sck     (data_sck),
        .spi_mosi    (data_mosi),
        .rx_byte     (data_rx_byte),
        .busy        (data_busy),
        .done        (data_done)
    );

    // -----------------------------------------------------------------------
    // CRC16 engine — feeds on the received payload bytes. crc_feed is asserted
    // exactly once per payload byte (after the engine returns that byte).
    // -----------------------------------------------------------------------
    crc16_ccitt u_crc16 (
        .clk        (clk),
        .rst_n      (rst_n),
        .data_valid (crc_feed),
        .data_in    (crc_byte),
        .crc_clear  (crc_clear),
        .crc_out    (crc_out)
    );

    // -----------------------------------------------------------------------
    // SPI ownership muxes.
    //   * Chip select: low whenever a transaction is in flight.
    //   * SCK / MOSI: transactor during the command phase, data engine after.
    //
    // The command phase is identified by the transactor's cmd_busy flag; it is
    // low again by the time the data engine runs, so the switch is hazard-free.
    // xactor_cs_n is intentionally unused (would release CS too early for a
    // read transaction); chip select is driven exclusively by this module.
    // -----------------------------------------------------------------------
    assign spi_cs_n  = (state == ST_IDLE) ? 1'b1 : 1'b0;
    assign spi_sck   = cmd_busy ? xactor_sck  : data_sck;
    assign spi_mosi  = cmd_busy ? xactor_mosi : data_mosi;

    // The data engine always transmits idle 0xFF: the card ignores MOSI while
    // it drives data, and a stable value avoids X propagation.
    assign data_tx_byte = 8'hFF;

    // -----------------------------------------------------------------------
    // Main FSM
    // -----------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= ST_IDLE;
            addr_latched <= 32'h0000_0000;
            cmd_start    <= 1'b0;
            data_start   <= 1'b0;
            crc_clear    <= 1'b0;
            crc_feed     <= 1'b0;
            crc_byte     <= 8'h00;
            byte_cnt     <= 10'd0;
            word_cnt     <= 2'd0;
            word_index   <= 7'd0;
            token_wait   <= 16'd0;
            crc_rx       <= 16'h0000;
            read_busy    <= 1'b0;
            read_done    <= 1'b0;
            read_timeout <= 1'b0;
            crc_error    <= 1'b0;
            data_out     <= 32'h0000_0000;
            data_valid   <= 1'b0;
        end else begin
            // Single-cycle pulse defaults: cleared every cycle unless set below.
            cmd_start  <= 1'b0;
            data_start <= 1'b0;
            read_done  <= 1'b0;
            data_valid <= 1'b0;
            crc_clear  <= 1'b0;
            crc_feed   <= 1'b0;

            case (state)
                // -----------------------------------------------------------
                // IDLE: accept one read request. The block address is latched
                // here so a re-entrant read_start during the transaction cannot
                // disturb the in-flight parameters (re-entry protection).
                // -----------------------------------------------------------
                ST_IDLE: begin
                    if (read_start && !read_busy) begin
                        addr_latched <= block_addr;
                        byte_cnt     <= 10'd0;
                        word_cnt     <= 2'd0;
                        word_index   <= 7'd0;
                        token_wait   <= 16'd0;
                        crc_rx       <= 16'h0000;
                        crc_error    <= 1'b0;
                        read_timeout <= 1'b0;
                        crc_clear    <= 1'b1;   // reset CRC to 0x0000
                        read_busy    <= 1'b1;
                        state        <= ST_CMD17_START;
                    end
                end

                // -----------------------------------------------------------
                // CMD17_START: pulse cmd_start; the transactor latches
                // cmd_index=17 and cmd_arg=addr_latched on the next edge.
                // -----------------------------------------------------------
                ST_CMD17_START: begin
                    crc_clear <= 1'b0;
                    cmd_start <= 1'b1;
                    state     <= ST_CMD17_WAIT;
                end

                // -----------------------------------------------------------
                // CMD17_WAIT: wait for the R1 response (cmd_done) or a
                // command timeout (cmd_timeout). Either way the command phase
                // is over; a timeout aborts the read.
                // -----------------------------------------------------------
                ST_CMD17_WAIT: begin
                    if (cmd_timeout) begin
                        read_timeout <= 1'b1;
                        state        <= ST_DONE;
                    end else if (cmd_done) begin
                        token_wait <= 16'd0;
                        // (R1 != 0x00 would be a card error; for this task the
                        //  success path is the only one exercised, but a
                        //  non-zero R1 still proceeds to the token wait so a
                        //  missing token surfaces as read_timeout.)
                        data_start <= 1'b1;
                        state      <= ST_TOKEN_WAIT;
                    end
                end

                // -----------------------------------------------------------
                // TOKEN_WAIT: read bytes until 0xFE arrives. Each received
                // byte costs one token_wait increment; exceeding NAC_TIMEOUT
                // bytes raises read_timeout (data token timeout).
                // -----------------------------------------------------------
                ST_TOKEN_WAIT: begin
                    if (data_done) begin
                        if (data_rx_byte == DATA_TOKEN) begin
                            byte_cnt <= 10'd0;
                            word_cnt <= 2'd0;
                            data_start <= 1'b1;   // issue first payload byte
                            state    <= ST_DATA_RX;
                        end else if (token_wait == (NAC_TIMEOUT - 1)) begin
                            read_timeout <= 1'b1;
                            state        <= ST_DONE;
                        end else begin
                            token_wait <= token_wait + 1'b1;
                            data_start <= 1'b1;   // read another token byte
                        end
                    end
                end

                // -----------------------------------------------------------
                // DATA_RX: receive 512 payload bytes. Each received byte is
                // fed to the CRC16 engine and packed into 32-bit big-endian
                // words. data_valid pulses once per complete 4-byte word.
                // -----------------------------------------------------------
                ST_DATA_RX: begin
                    if (data_done) begin
                        crc_feed <= 1'b1;         // feed this byte into CRC
                        crc_byte <= data_rx_byte; // (consumed on next edge)
                        case (word_cnt)
                            2'd0: data_out[31:24] <= data_rx_byte;
                            2'd1: data_out[23:16] <= data_rx_byte;
                            2'd2: data_out[15:8]  <= data_rx_byte;
                            2'd3: data_out[7:0]   <= data_rx_byte;
                        endcase
                        if (word_cnt == 2'd3) begin
                            data_valid <= 1'b1;   // complete 32-bit word
                            word_index <= word_index + 1'b1;
                        end
                        if (byte_cnt == 10'd511) begin
                            // Last payload byte: next are the 2 CRC bytes.
                            byte_cnt   <= 10'd0;
                            data_start <= 1'b1;   // issue first CRC byte
                            state      <= ST_CRC_RX;
                        end else begin
                            byte_cnt  <= byte_cnt + 1'b1;
                            word_cnt  <= word_cnt + 1'b1;
                            data_start <= 1'b1;   // issue next payload byte
                        end
                    end
                end

                // -----------------------------------------------------------
                // CRC_RX: receive the 2-byte block CRC16 (MSB first) from the
                // card and latch it for comparison.
                // -----------------------------------------------------------
                ST_CRC_RX: begin
                    if (data_done) begin
                        if (byte_cnt == 10'd0) begin
                            crc_rx[15:8] <= data_rx_byte;   // first (MSB) CRC byte
                            byte_cnt     <= 10'd1;
                            data_start   <= 1'b1;          // issue second CRC byte
                        end else begin
                            crc_rx[7:0] <= data_rx_byte;   // second (LSB) CRC byte
                            state       <= ST_CRC_CHECK;
                        end
                    end
                end

                // -----------------------------------------------------------
                // CRC_CHECK: compare the running CRC16 with the received CRC.
                // A mismatch raises crc_error but still completes the read.
                // -----------------------------------------------------------
                ST_CRC_CHECK: begin
                    if (crc_out == crc_rx)
                        crc_error <= 1'b0;
                    else
                        crc_error <= 1'b1;
                    state <= ST_DONE;
                end

                // -----------------------------------------------------------
                // DONE: present the single-cycle completion handshake and
                // release read_busy, then return to IDLE.
                // -----------------------------------------------------------
                ST_DONE: begin
                    read_done  <= 1'b1;
                    read_busy  <= 1'b0;
                    state      <= ST_IDLE;
                end

                // -----------------------------------------------------------
                // Unreachable defensive branch: recover to a clean idle.
                // -----------------------------------------------------------
                default: begin
                    state     <= ST_IDLE;
                    read_busy <= 1'b0;
                end
            endcase
        end
    end

endmodule
