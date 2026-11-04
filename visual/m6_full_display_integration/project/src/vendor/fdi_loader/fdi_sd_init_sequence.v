// ---------------------------------------------------------------------------
// fdi_sd_init_sequence — SD card SPI-mode power-on initialization sequencer
// (Task 003)
//
// Orchestrates the SD card initialization sequence over SPI:
//     CMD0 (GO_IDLE_STATE) -> CMD8 (SEND_IF_COND) -> {CMD55, ACMD41} poll loop
//
// It instantiates the Task 002 `fdi_sd_cmd_transactor` for every command and makes
// all branch decisions from the single-byte R1 response that transactor
// exposes. Command frame assembly, CRC7 and chip-select timing are entirely
// delegated to the transactor (this module never re-implements them).
//
// ---------------------------------------------------------------------------
// IMPORTANT — known interface limitation (do NOT try to work around it here):
//
//   `fdi_sd_cmd_transactor` only captures the FIRST byte of the R1 response. It
//   does NOT expose the trailing R7 echo bytes of CMD8, nor the R3 OCR content
//   of ACMD41. Consequently this module CANNOT read the CCS bit (OCR[30]) and
//   therefore cannot truly distinguish an SDHC/SDXC card from an SDSC card.
//
//   `card_is_sdhc` is therefore FIXED to 1'b1 as an ASSUMPTION — the target
//   board uses an SDHC card. This is NOT a measured value; it must not be
//   presented as a real CCS-bit detection result. See
//   doc/spec/behavior_spec.md for the full rationale.
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module fdi_sd_init_sequence #(
    parameter BYTE_DIV_WIDTH = 16,
    // Maximum number of ACMD41 polling attempts before declaring failure.
    // Declared as a `parameter` (not a localparam) so a testbench can lower it
    // at instantiation for fast simulation; the production default is 100.
    parameter INIT_POLL_MAX  = 100
)(
    input  wire                      clk,
    input  wire                      rst_n,

    // Init request interface
    input  wire                      init_start,
    output reg                       init_busy,
    output reg                       init_done,
    output reg                       init_error,
    output reg  [2:0]                init_error_code,

    // Result interface (valid only when init_done==1)
    output reg                       card_is_sdhc,
    // Last R1 byte captured by the transactor (raw card answer, debug use)
    output wire [7:0]                init_resp_r1,

    // SPI physical interface (passthrough to the internal fdi_sd_cmd_transactor)
    output wire                      spi_cs_n,
    output wire                      spi_sck,
    output wire                      spi_mosi,
    input  wire                      spi_miso,

    // Byte-engine clock dividers
    input  wire [BYTE_DIV_WIDTH-1:0] spi_clk_div_slow  // 全初始化使用慢速；本窄链不导出未使用快分频口
);

    // -----------------------------------------------------------------------
    // FSM states
    // -----------------------------------------------------------------------
    localparam [3:0] ST_IDLE         = 4'd0,
                     ST_CMD0_START   = 4'd1,
                     ST_CMD0_WAIT    = 4'd2,
                     ST_CMD8_START   = 4'd3,
                     ST_CMD8_WAIT    = 4'd4,
                     ST_CMD55_START  = 4'd5,
                     ST_CMD55_WAIT   = 4'd6,
                     ST_ACMD41_START = 4'd7,
                     ST_ACMD41_WAIT  = 4'd8;

    // -----------------------------------------------------------------------
    // Command constants
    // -----------------------------------------------------------------------
    localparam [5:0]  CMD0      = 6'd0;
    localparam [5:0]  CMD8      = 6'd8;
    localparam [5:0]  CMD55     = 6'd55;
    localparam [5:0]  ACMD41    = 6'd41;

    localparam [31:0] CMD0_ARG  = 32'h0000_0000;
    localparam [31:0] CMD8_ARG  = 32'h0000_01AA;
    localparam [31:0] CMD55_ARG = 32'h0000_0000;
    localparam [31:0] ACMD41_ARG = 32'h4000_0000;

    // Poll counter width: must cover INIT_POLL_MAX (production default 2048).
    localparam POLL_CNT_W = 12;

    // -----------------------------------------------------------------------
    // Registered state
    // -----------------------------------------------------------------------
    reg [3:0]           state;
    reg [POLL_CNT_W-1:0] poll_cnt;

    // Command transactor request signals
    reg                 cmd_start;
    reg [5:0]           cmd_index;
    reg [31:0]          cmd_arg;

    // Command transactor response/status
    /* verilator lint_off UNUSEDSIGNAL */
    wire                cmd_busy; // 复用命令器调试输出，不用于状态判定
    /* verilator lint_on UNUSEDSIGNAL */
    wire                cmd_done;
    wire                cmd_timeout;
    wire [7:0]          resp_r1;
    /* verilator lint_off UNUSEDSIGNAL */
    wire                resp_valid; // 完成拍直接判定R1，保持既有行为
    /* verilator lint_on UNUSEDSIGNAL */

    // 1 = the first command after reset runs the spec power-up
    // conditioning (80 clocks, CS high) inside the transactor. Cleared in
    // ST_CMD0_WAIT — one cycle AFTER the transactor samples it together with
    // cmd_start — so the very first CMD0 is conditioned exactly once and no
    // retry ever re-conditions.
    reg                 pre_cond_r;

    // spi_clk_div_fast is intentionally not used: this module runs the entire
    // initialization at the slow clock; the upper level decides when to switch.

    // -----------------------------------------------------------------------
    // Main FSM
    // -----------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= ST_IDLE;
            poll_cnt        <= {POLL_CNT_W{1'b0}};
            pre_cond_r      <= 1'b1;
            cmd_start       <= 1'b0;
            cmd_index       <= 6'd0;
            cmd_arg         <= 32'h0000_0000;
            init_busy       <= 1'b0;
            init_done       <= 1'b0;
            init_error      <= 1'b0;
            init_error_code <= 3'd0;
            card_is_sdhc    <= 1'b0;
        end else begin
            // Single-cycle pulse defaults: cleared every cycle unless set below.
            init_done  <= 1'b0;
            init_error <= 1'b0;
            cmd_start  <= 1'b0;

            case (state)
                // -----------------------------------------------------------
                // IDLE: accept an init request on init_start && !init_busy.
                // -----------------------------------------------------------
                ST_IDLE: begin
                    if (init_start && !init_busy) begin
                        init_busy       <= 1'b1;
                        init_error_code <= 3'd0;
                        card_is_sdhc    <= 1'b0;
                        poll_cnt        <= {POLL_CNT_W{1'b0}};
                        state           <= ST_CMD0_START;
                    end
                end

                // -----------------------------------------------------------
                // CMD0: issue GO_IDLE_STATE.
                // -----------------------------------------------------------
                ST_CMD0_START: begin
                    cmd_index <= CMD0;
                    cmd_arg   <= CMD0_ARG;
                    cmd_start <= 1'b1;
                    state     <= ST_CMD0_WAIT;
                end

                ST_CMD0_WAIT: begin
                    pre_cond_r <= 1'b0;   // conditioning consumed once
                    if (cmd_timeout) begin
                        // 真卡上电后可能需要多次 CMD0 才进 idle(参考完赛
                        // 经验); 超时消耗轮询预算重试, 预算耗尽才码 3。
                        if (poll_cnt < (INIT_POLL_MAX - 1)) begin
                            poll_cnt <= poll_cnt + 1'b1;
                            state    <= ST_CMD0_START;
                        end else begin
                            init_error      <= 1'b1;
                            init_error_code <= 3'd3;
                            init_busy       <= 1'b0;
                            state           <= ST_IDLE;
                        end
                    end else if (cmd_done) begin
                        if (resp_r1 == 8'h01) begin
                            state <= ST_CMD8_START;
                        end else if (poll_cnt < (INIT_POLL_MAX - 1)) begin
                            // 真卡上电窗口内 CMD0 可能捕获到毛刺或非 idle
                            // 应答(bit7=0 的噪声字节), 与超时同样消耗轮询
                            // 预算重试; 预算耗尽才报码 1(卡无法进入 idle)。
                            poll_cnt <= poll_cnt + 1'b1;
                            state    <= ST_CMD0_START;
                        end else begin
                            // Budget exhausted with an unexpected R1 byte:
                            // the card never reached the idle state.
                            init_error      <= 1'b1;
                            init_error_code <= 3'd1;
                            init_busy       <= 1'b0;
                            state           <= ST_IDLE;
                        end
                    end
                end

                // -----------------------------------------------------------
                // CMD8: issue SEND_IF_COND. Only the R1 first byte is
                // available; resp_r1[2] (Illegal Command) is accepted either
                // way and both paths continue to the ACMD41 poll loop.
                // -----------------------------------------------------------
                ST_CMD8_START: begin
                    cmd_index <= CMD8;
                    cmd_arg   <= CMD8_ARG;
                    cmd_start <= 1'b1;
                    state     <= ST_CMD8_WAIT;
                end

                ST_CMD8_WAIT: begin
                    if (cmd_timeout) begin
                        // CMD8 超时消耗轮询预算重试, 预算耗尽才码 3。
                        if (poll_cnt < (INIT_POLL_MAX - 1)) begin
                            poll_cnt <= poll_cnt + 1'b1;
                            state    <= ST_CMD8_START;
                        end else begin
                            init_error      <= 1'b1;
                            init_error_code <= 3'd3;
                            init_busy       <= 1'b0;
                            state           <= ST_IDLE;
                        end
                    end else if (cmd_done) begin
                        // resp_r1[2]==1 means an old card that does not support
                        // CMD8; this must NOT abort the sequence. We continue
                        // to the ACMD41 polling loop regardless of this bit.
                        state <= ST_CMD55_START;
                    end
                end

                // -----------------------------------------------------------
                // CMD55: APP_CMD prefix, sent before each ACMD41.
                // -----------------------------------------------------------
                ST_CMD55_START: begin
                    cmd_index <= CMD55;
                    cmd_arg   <= CMD55_ARG;
                    cmd_start <= 1'b1;
                    state     <= ST_CMD55_WAIT;
                end

                ST_CMD55_WAIT: begin
                    if (cmd_timeout) begin
                        // 真卡在 busy 期间可对 CMD55 不回 R1(规范允许);
                        // 单次 Ncr 超时消耗轮询预算重试, 预算耗尽才报码 3。
                        if (poll_cnt < (INIT_POLL_MAX - 1)) begin
                            poll_cnt <= poll_cnt + 1'b1;
                            state    <= ST_CMD55_START;
                        end else begin
                            init_error      <= 1'b1;
                            init_error_code <= 3'd3;
                            init_busy       <= 1'b0;
                            state           <= ST_IDLE;
                        end
                    end else if (cmd_done) begin
                        state <= ST_ACMD41_START;
                    end
                end

                // -----------------------------------------------------------
                // ACMD41: SD_SEND_OP_COND with HCS bit set (arg=0x40000000).
                // resp_r1[0] (In Idle State): 1 = keep polling, 0 = ready.
                // -----------------------------------------------------------
                ST_ACMD41_START: begin
                    cmd_index <= ACMD41;
                    cmd_arg   <= ACMD41_ARG;
                    cmd_start <= 1'b1;
                    state     <= ST_ACMD41_WAIT;
                end

                ST_ACMD41_WAIT: begin
                    if (cmd_timeout) begin
                        // ACMD41 期间真卡忙于内部初始化可不回 R1(参考工程
                        // 经验: 重试 2048 次); 单次 Ncr 超时改重试(CMD55+
                        // ACMD41 整轮), 预算耗尽才码 3。
                        if (poll_cnt < (INIT_POLL_MAX - 1)) begin
                            poll_cnt <= poll_cnt + 1'b1;
                            state    <= ST_CMD55_START;
                        end else begin
                            init_error      <= 1'b1;
                            init_error_code <= 3'd3;
                            init_busy       <= 1'b0;
                            state           <= ST_IDLE;
                        end
                    end else if (cmd_done) begin
                        if (resp_r1[0] == 1'b0) begin
                            // Card left Idle state: initialization complete.
                            init_done    <= 1'b1;
                            init_busy    <= 1'b0;
                            card_is_sdhc <= 1'b1;
                            state        <= ST_IDLE;
                        end else begin
                            // Still in Idle state: poll again or give up.
                            if (poll_cnt >= (INIT_POLL_MAX - 1)) begin
                                init_error      <= 1'b1;
                                init_error_code <= 3'd2;
                                init_busy       <= 1'b0;
                                state           <= ST_IDLE;
                            end else begin
                                poll_cnt <= poll_cnt + 1'b1;
                                state    <= ST_CMD55_START;
                            end
                        end
                    end
                end

                // -----------------------------------------------------------
                // Unreachable defensive branch: recover to a clean idle.
                // -----------------------------------------------------------
                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // Task 002 command transactor — owns frame assembly, CRC7, CS timing and
    // R1 capture. spi_clk_div is pinned to spi_clk_div_slow so the whole
    // initialization runs at the slow (<=400 kHz) rate.
    // -----------------------------------------------------------------------
    fdi_sd_cmd_transactor #(
        .BYTE_DIV_WIDTH(BYTE_DIV_WIDTH)
    ) u_cmd_xactor (
        .clk         (clk),
        .rst_n       (rst_n),
        .cmd_start   (cmd_start),
        .cmd_index   (cmd_index),
        .cmd_arg     (cmd_arg),
        .pre_cond    (pre_cond_r),
        // CMD8 的 R7 有 4 个尾随字节; 在卡仍在驱动 MISO 时就发下一条
        // 命令会吞掉 CMD55 首帧(参考工程 extra_response_bytes 同款约定)
        .extra_resp_bytes ((state == ST_CMD8_WAIT) ? 3'd4 : 3'd0),
        .cmd_busy    (cmd_busy),
        .cmd_done    (cmd_done),
        .cmd_timeout (cmd_timeout),
        .resp_r1     (resp_r1),
        .resp_valid  (resp_valid),
        .spi_cs_n    (spi_cs_n),
        .spi_sck     (spi_sck),
        .spi_mosi    (spi_mosi),
        .spi_miso    (spi_miso),
        .spi_clk_div (spi_clk_div_slow)
    );

    // diagnostic visibility of the raw card answer
    assign init_resp_r1 = resp_r1;

    // cmd_busy and resp_valid are intentionally unread: command sequencing is
    // driven exclusively by cmd_done / cmd_timeout, and resp_r1 is guaranteed
    // valid in the same cycle as cmd_done.

endmodule
