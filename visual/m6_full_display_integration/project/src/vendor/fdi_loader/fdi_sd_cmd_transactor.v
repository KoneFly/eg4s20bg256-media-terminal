// ---------------------------------------------------------------------------
// fdi_sd_cmd_transactor — SD card SPI-mode command transaction layer (Task 002)
//
// Responsibilities:
//   * Chip-select management: asserted for the whole command transaction,
//     released on completion; held low for at least one byte time before
//     the command frame starts (SD CS setup requirement).
//   * Optional power-up conditioning (pre_cond): clock
//     POWER_UP_BYTES of 0xFF through the engine with CS HIGH and MOSI high
//     before the first command — SD spec requires >=74 clocks so the card
//     can prepare its SPI interface after power-up (real-card proven recipe).
//   * 48-bit command frame transmission: {start(0), transmission(1),
//     index(6), argument(32), crc7(7), stop(1)}, MSB first.
//   * R1 response wait: an R1 byte is qualified by its start bit (bit7==0,
//     0xFF and any bit7=1 noise byte are skipped: power-up line glitches
//     would otherwise be mistaken for R1. Times out after Ncr = 8
//     non-qualified bytes without a response.
//   * Byte-level SPI transfers are delegated to the Task 001 engine
//     (fdi_sd_spi_byte_engine); this module never generates SCK edges itself.
//
// All sequential logic runs on the system clock with an asynchronous
// active-low reset. spi_sck is an output of the instantiated engine and is
// never used as a clock domain.
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module fdi_sd_cmd_transactor #(
    parameter BYTE_DIV_WIDTH = 16
)(
    input  wire                      clk,
    input  wire                      rst_n,

    // Command request interface
    input  wire                      cmd_start,
    input  wire [5:0]                cmd_index,
    input  wire [31:0]               cmd_arg,
    // 1 = run the power-up conditioning phase before this command
    // (first command after reset only; upstream clears it afterwards)
    input  wire                      pre_cond,
    // number of response bytes to drain AFTER the R1 byte before
    // reporting cmd_done (R7 of CMD8 = 4 trailing bytes; the card is still
    // driving MISO while the host starts the next command otherwise —
    // real-card proven convention borrowed from the reference design)
    input  wire [2:0]                extra_resp_bytes,
    output reg                       cmd_busy,
    output reg                       cmd_done,
    output reg                       cmd_timeout,

    // Response interface
    output reg  [7:0]                resp_r1,
    output reg                       resp_valid,

    // SPI physical interface
    output wire                      spi_cs_n,
    output wire                      spi_sck,
    output wire                      spi_mosi,
    input  wire                      spi_miso,

    // Byte engine clock divider (latched at cmd_start)
    input  wire [BYTE_DIV_WIDTH-1:0] spi_clk_div
);

    // -----------------------------------------------------------------------
    // FSM states
    // -----------------------------------------------------------------------
    // State encoding: the three CS-high states (PWR_WAIT/PWR_ISSUE/IDLE)
    // occupy the top of the value range so chip select decodes with ONE
    // range comparator. A multi-term OR of equality tests re-evaluates
    // term-by-term in simulation, which shows a 1-delta low transient on
    // state updates between same-output states — an SPI slave counts that
    // as a phantom chip-select session.
    localparam [2:0] ST_CS_DELAY = 3'd0,   // CS low, waiting one byte time
                     ST_TX_ISSUE = 3'd1,   // byte_start pulse for a frame byte
                     ST_TX_WAIT  = 3'd2,   // frame byte in flight
                     ST_RX_ISSUE = 3'd3,   // byte_start pulse for a response byte
                     ST_RX_WAIT  = 3'd4,   // response byte in flight / decode
                     ST_PWR_WAIT = 3'd5,   // conditioning byte in flight
                     ST_PWR_ISSUE= 3'd6,   // conditioning byte_start pulse
                     ST_IDLE     = 3'd7;   // CS released, waits for cmd_start

    localparam [2:0] TX_LAST     = 3'd5;   // index of the CRC byte
    localparam [3:0] NCR_LAST_FF = 4'd7;   // 8th consecutive 0xFF -> timeout
    // SD spec 6.4.1: at least 74 clocks after power-up before CMD0
    localparam [7:0] POWER_UP_BYTES = 8'd80;

    // -----------------------------------------------------------------------
    // Registered state
    // -----------------------------------------------------------------------
    reg [2:0]                 state;
    reg [5:0]                 cmd_index_latched;
    reg [31:0]                cmd_arg_latched;
    reg [BYTE_DIV_WIDTH-1:0]  div_latched;
    reg [2:0]                 tx_byte_idx;   // 0..5 frame byte selector
    reg [3:0]                 rxff_cnt;      // leading non-qualified bytes received
    reg [BYTE_DIV_WIDTH+4:0]  cs_delay_cnt;  // CS setup counter (one byte time)
    reg [7:0]                 power_cnt;     // conditioning byte counter
    reg [2:0]                 extra_left;    // R7 drain bytes remaining
    reg                       draining;      // post-R1 drain in progress

    reg                        byte_start;
    reg  [7:0]                 byte_tx_data;

    /* verilator lint_off UNUSEDSIGNAL */
    wire                       byte_busy;  // unused: sequencing uses byte_done only
    /* verilator lint_on UNUSEDSIGNAL */
    wire                       byte_done;
    wire [7:0]                 byte_rx_data;

    // -----------------------------------------------------------------------
    // CRC7 over the 40-bit frame prefix {start=0, transmission=1, index, arg}.
    // Numerically identical to zero-extending {1'b1, cmd_index, cmd_arg} to
    // 40 bits: the frame prefix is 0x40|index followed by the argument.
    // -----------------------------------------------------------------------
    wire [39:0] crc_input = {2'b01, cmd_index_latched, cmd_arg_latched};
    wire [6:0]  crc7_result;

    fdi_crc7_calc u_crc7 (
        .data_in (crc_input),
        .crc7_out(crc7_result)
    );

    // One full byte time (16 SCK half-periods) minus one, in system clocks:
    //   16 * (div_latched + 1) - 1 = 16 * div_latched + 15
    wire [BYTE_DIV_WIDTH+4:0] cs_delay_target = {1'b0, div_latched, 4'd0} + {{BYTE_DIV_WIDTH{1'b0}}, 5'd15};

    // Conditioning phase drives DI high with CS released (spec recipe).
    wire in_power = (state == ST_PWR_ISSUE) || (state == ST_PWR_WAIT);

    // -----------------------------------------------------------------------
    // Transmit byte selection. During the response wait (tx_byte_idx frozen
    // at TX_LAST) the CRC byte stays on MOSI: the card ignores MOSI while it
    // drives the R1 response, and a defined, stable value prevents X
    // propagation through the engine.
    // -----------------------------------------------------------------------
    always @(*) begin
        if (in_power)
            byte_tx_data = 8'hFF;
        else case (tx_byte_idx)
            3'd0:    byte_tx_data = {2'b01, cmd_index_latched};  // 0x40|index
            3'd1:    byte_tx_data = cmd_arg_latched[31:24];
            3'd2:    byte_tx_data = cmd_arg_latched[23:16];
            3'd3:    byte_tx_data = cmd_arg_latched[15:8];
            3'd4:    byte_tx_data = cmd_arg_latched[7:0];
            default: byte_tx_data = {crc7_result, 1'b1};          // {crc7, stop}
        endcase
    end

    // -----------------------------------------------------------------------
    // Chip select: low for the whole transaction, high in IDLE and during
    // the power-up conditioning phase (spec: DI high, CS released).
    // Combinational on the state register so that an asynchronous reset
    // releases the chip select immediately. Single range comparator over
    // the encoding above: one input event -> one output event, no transient.
    // -----------------------------------------------------------------------
    assign spi_cs_n = (state >= ST_PWR_WAIT);

    // -----------------------------------------------------------------------
    // Main FSM
    // -----------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= ST_IDLE;
            cmd_busy          <= 1'b0;
            cmd_done          <= 1'b0;
            cmd_timeout       <= 1'b0;
            resp_r1           <= 8'h00;
            resp_valid        <= 1'b0;
            cmd_index_latched <= 6'd0;
            cmd_arg_latched   <= 32'h0000_0000;
            div_latched       <= {BYTE_DIV_WIDTH{1'b0}};
            tx_byte_idx       <= 3'd0;
            rxff_cnt          <= 4'd0;
            cs_delay_cnt      <= {(BYTE_DIV_WIDTH+5){1'b0}};
            power_cnt         <= 8'd0;
            extra_left        <= 3'd0;
            draining          <= 1'b0;
            byte_start        <= 1'b0;
        end else begin
            // Single-cycle pulses: cleared every cycle unless set below.
            cmd_done    <= 1'b0;
            cmd_timeout <= 1'b0;
            resp_valid  <= 1'b0;

            case (state)
                // -----------------------------------------------------------
                // IDLE: accept a request. All request parameters are latched
                // atomically so later input changes cannot disturb the
                // in-flight command (re-entry protection).
                // -----------------------------------------------------------
                ST_IDLE: begin
                    if (cmd_start) begin
                        cmd_index_latched <= cmd_index;
                        cmd_arg_latched   <= cmd_arg;
                        div_latched       <= spi_clk_div;
                        tx_byte_idx       <= 3'd0;
                        rxff_cnt          <= 4'd0;
                        cs_delay_cnt      <= {(BYTE_DIV_WIDTH+5){1'b0}};
                        power_cnt         <= 8'd0;
                        extra_left        <= extra_resp_bytes;
                        draining          <= 1'b0;
                        cmd_busy          <= 1'b1;
                        // first command after reset: run the power-up
                        // conditioning (>=74 clocks, CS high) before the frame
                        byte_start        <= pre_cond;
                        state             <= pre_cond ? ST_PWR_ISSUE : ST_CS_DELAY;
                    end
                end

                // -----------------------------------------------------------
                // Power-up conditioning: clock POWER_UP_BYTES of 0xFF
                // with CS high so the card can finish its power-up sequence.
                // byte_start pulse width mirrors the TX_ISSUE/TX_WAIT
                // convention (high during *ISSUE, cleared on entering *WAIT).
                // -----------------------------------------------------------
                ST_PWR_ISSUE: begin
                    byte_start <= 1'b0;
                    state      <= ST_PWR_WAIT;
                end

                ST_PWR_WAIT: begin
                    if (byte_done) begin
                        if (power_cnt == POWER_UP_BYTES - 8'd1) begin
                            state <= ST_CS_DELAY;
                        end else begin
                            power_cnt  <= power_cnt + 8'd1;
                            byte_start <= 1'b1;
                            state      <= ST_PWR_ISSUE;
                        end
                    end
                end

                // -----------------------------------------------------------
                // Hold CS low for one byte time before the first frame bit.
                // -----------------------------------------------------------
                ST_CS_DELAY: begin
                    if (cs_delay_cnt == cs_delay_target) begin
                        cs_delay_cnt <= {(BYTE_DIV_WIDTH+5){1'b0}};
                        byte_start   <= 1'b1;
                        state        <= ST_TX_ISSUE;
                    end else begin
                        cs_delay_cnt <= cs_delay_cnt + 1'b1;
                    end
                end

                // -----------------------------------------------------------
                // TX_ISSUE: byte_start is a one-cycle pulse; the engine
                // latches byte_tx_data on the next rising edge.
                // -----------------------------------------------------------
                ST_TX_ISSUE: begin
                    byte_start <= 1'b0;
                    state      <= ST_TX_WAIT;
                end

                // -----------------------------------------------------------
                // TX_WAIT: wait for the engine handshake, then chain the next
                // frame byte or switch to the response wait phase.
                // -----------------------------------------------------------
                ST_TX_WAIT: begin
                    if (byte_done) begin
                        if (tx_byte_idx == TX_LAST) begin
                            rxff_cnt   <= 4'd0;
                            byte_start <= 1'b1;
                            state      <= ST_RX_ISSUE;
                        end else begin
                            tx_byte_idx <= tx_byte_idx + 1'b1;
                            byte_start  <= 1'b1;
                            state       <= ST_TX_ISSUE;
                        end
                    end
                end

                // -----------------------------------------------------------
                // RX_ISSUE: launch one response-wait byte (dummy 0xFF on MOSI).
                // -----------------------------------------------------------
                ST_RX_ISSUE: begin
                    byte_start <= 1'b0;
                    state      <= ST_RX_WAIT;
                end

                // -----------------------------------------------------------
                // RX_WAIT: decode each received byte. An R1 response is
                // qualified by its start bit (bit7==0); 0xFF filler and
                // any bit7=1 noise are skipped. Eight non-qualified bytes
                // exhaust the Ncr window and raise cmd_timeout.
                // -----------------------------------------------------------
                ST_RX_WAIT: begin
                    if (byte_done) begin
                        if (draining) begin
                            // consume one R7 trailing byte (value ignored)
                            if (extra_left == 3'd1) begin
                                draining   <= 1'b0;
                                cmd_done   <= 1'b1;
                                cmd_busy   <= 1'b0;
                                state      <= ST_IDLE;
                            end else begin
                                extra_left <= extra_left - 3'd1;
                                byte_start <= 1'b1;
                                state      <= ST_RX_ISSUE;
                            end
                        end else if (!byte_rx_data[7]) begin
                            resp_r1    <= byte_rx_data;
                            resp_valid <= 1'b1;
                            if (extra_left != 3'd0) begin
                                // hold cmd_done until R7 fully drained
                                draining   <= 1'b1;
                                byte_start <= 1'b1;
                                state      <= ST_RX_ISSUE;
                            end else begin
                                cmd_done   <= 1'b1;
                                cmd_busy   <= 1'b0;
                                state      <= ST_IDLE;
                            end
                        end else begin
                            if (rxff_cnt == NCR_LAST_FF) begin
                                cmd_busy    <= 1'b0;
                                cmd_timeout <= 1'b1;
                                state       <= ST_IDLE;
                            end else begin
                                rxff_cnt   <= rxff_cnt + 1'b1;
                                byte_start <= 1'b1;
                                state      <= ST_RX_ISSUE;
                            end
                        end
                    end
                end

                // -----------------------------------------------------------
                // Unreachable defensive branch: recover to a clean idle.
                // -----------------------------------------------------------
                default: begin
                    state      <= ST_IDLE;
                    cmd_busy   <= 1'b0;
                    byte_start <= 1'b0;
                end
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // Task 001 byte engine — owns SCK/MOSI generation and MISO sampling.
    // The divider comes from div_latched, so the engine rate is frozen for
    // the whole command even if spi_clk_div changes afterwards.
    // -----------------------------------------------------------------------
    fdi_sd_spi_byte_engine #(
        .DIV_WIDTH(BYTE_DIV_WIDTH)
    ) u_byte_engine (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (byte_start),
        .tx_byte     (byte_tx_data),
        .clk_divider (div_latched),
        .spi_miso    (spi_miso),
        .spi_sck     (spi_sck),
        .spi_mosi    (spi_mosi),
        .rx_byte     (byte_rx_data),
        .busy        (byte_busy),
        .done        (byte_done)
    );

    // byte_busy is intentionally unused: byte transfers are sequenced
    // exclusively by the byte_done handshake, and the engine is guaranteed
    // to be idle whenever byte_start pulses (one dead cycle between bytes).

endmodule
