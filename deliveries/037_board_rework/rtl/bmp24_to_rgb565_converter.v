// ---------------------------------------------------------------------------
// bmp24_to_rgb565_converter — 24-bit uncompressed BMP -> RGB565 pixel stream
// (Task 005)
//
// Parses the 54-byte BMP file header from the Task 004 sd_block_reader data
// stream (32-bit big-endian words, data_valid pulse per word), validates the
// format (signature 0x4D42 / BITMAPINFOHEADER size 40 / planes 1 / bit depth
// 24 / compression 0 / non-zero dimensions), extracts width / height /
// pixel-data offset, then converts the BGR888 pixel payload to an RGB565
// pixel stream with X/Y coordinates for direct SDRAM frame-buffer writes.
//
// FSM:  IDLE -> PARSE_HEADER -> VALIDATE -> WAIT_PIXEL_DATA -> CONVERT_PIXELS
//        -> DONE -> IDLE
// Error paths (format_error / size_error) short-circuit VALIDATE -> DONE.
//
// Design notes
// ------------
// * Single-always FSM (state transitions are coded directly in the sequential
//   block).  This avoids the classic two-always race where a combinational
//   state_next block is sampled with stale values when an input (convert_start
//   / data_valid) changes exactly at the clock edge.
// * Header bytes are captured in a 54-byte array; multi-byte fields are
//   reassembled little-endian (BMP native order) from the big-endian stream.
// * The pixel payload starts at pixel_offset (usually 54).  The first payload
//   word is consumed starting from byte offset `skip` (0..3) inside the word,
//   so arbitrary non-4-aligned offsets are supported.
// * Pixel bytes are processed one byte per cycle; a 3-byte BGR collector
//   emits one RGB565 pixel every third pixel byte (max 1 pixel/cycle).
//   Input words must be spaced >= 4 cycles apart; the upstream sd_block_reader
//   always satisfies this (SPI bit engine: >= 32 SPI clock periods per word).
// * Row padding (row byte width aligned to 4 bytes) is skipped via the row
//   byte position counter.
// * Output coordinates are the sequential stream counters: the 1st emitted
//   pixel is (0,0), the (width+1)-th is (0,1), the last is (width-1,height-1).
//   A positive BMP height stores bottom-up rows; the physical row order is
//   left to the SDRAM write/read addressing (Task 006) — this module only
//   tags each emitted pixel with its output coordinate.  Negative height
//   (top-down storage) is accepted and its absolute value is reported.
// * Truncation RGB888->RGB565 (R[7:3], G[7:2], B[7:3]) is implemented by the
//   dedicated rgb888_to_rgb565 submodule.
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module bmp24_to_rgb565_converter #(
    parameter MAX_WIDTH  = 16'd4096,
    parameter MAX_HEIGHT = 16'd4096
)(
    // system
    input  wire                clk,
    input  wire                rst_n,

    // control
    input  wire                convert_start,
    output reg                 convert_busy,
    output reg                 convert_done,
    output reg                 format_error,
    output reg                 size_error,

    // input data (Task 004 sd_block_reader, big-endian)
    input  wire [31:0]         data_in,
    input  wire                data_valid,

    // image info output
    output reg  [15:0]         image_width,
    output reg  [15:0]         image_height,

    // pixel stream output
    output reg  [15:0]         pixel_out,
    output reg                 pixel_valid,
    output reg  [12:0]         pixel_x,
    output reg  [11:0]         pixel_y
);

    // -----------------------------------------------------------------------
    // FSM states
    // -----------------------------------------------------------------------
    localparam [2:0] ST_IDLE            = 3'd0,
                     ST_PARSE_HEADER    = 3'd1,
                     ST_VALIDATE        = 3'd2,
                     ST_WAIT_PIXEL_DATA = 3'd3,
                     ST_CONVERT_PIXELS  = 3'd4,
                     ST_DONE            = 3'd5;

    // -----------------------------------------------------------------------
    // sequential registers
    // -----------------------------------------------------------------------
    reg [2:0]  state;
    reg        start_d;                       // convert_start edge detect

    // header capture
    reg [7:0]  header_buf [0:53];             // 54-byte BMP header
    reg [31:0] stream_cnt;                    // bytes consumed from stream

    // geometry / info (locked during VALIDATE)
    reg [31:0] pixel_offset_reg;
    reg [15:0] image_width_reg;
    reg [15:0] image_height_reg;
    reg [31:0] total_pixels_reg;              // width * height
    reg [15:0] pixel_bytes_per_row;           // width * 3
    reg [15:0] row_bytes;                     // ((width*3+3)>>2)<<2

    // CONVERT_PIXELS data path
    reg [31:0] cur_word;                      // latched input word
    reg [2:0]  word_byte;                     // byte index inside word (0..4)
    reg        word_valid;                    // word still has bytes to process
    reg [15:0] row_pos;                       // byte position inside current row
    reg [15:0] x_cnt;                         // pixel column 0..width-1
    reg [15:0] y_cnt;                         // output row 0..height-1
    reg [31:0] px_total;                      // pixels emitted so far
    reg [7:0]  px_buf0;                       // B (1st byte of BGR triplet)
    reg [7:0]  px_buf1;                       // G (2nd byte)
    reg [1:0]  px_byte_cnt;                   // collected bytes 0..2
    reg [7:0]  cur_word_byte;                 // current byte (combinational)

    // -----------------------------------------------------------------------
    // combinational header field extraction (little-endian)
    // -----------------------------------------------------------------------
    wire [15:0] file_signature = {header_buf[1],  header_buf[0]};
    wire [31:0] pixel_offset_w = {header_buf[13], header_buf[12],
                                  header_buf[11], header_buf[10]};
    wire [15:0] info_size_w    = {header_buf[15], header_buf[14]};
    wire [31:0] width_raw      = {header_buf[21], header_buf[20],
                                  header_buf[19], header_buf[18]};
    wire [31:0] height_raw     = {header_buf[25], header_buf[24],
                                  header_buf[23], header_buf[22]};
    wire [15:0] planes_w       = {header_buf[27], header_buf[26]};
    wire [15:0] bit_depth_w    = {header_buf[29], header_buf[28]};
    wire [31:0] compress_w     = {header_buf[33], header_buf[32],
                                  header_buf[31], header_buf[30]};

    // absolute (unsigned) dimensions
    wire [31:0] width_abs  = width_raw[31]  ? (~width_raw  + 32'd1) : width_raw;
    wire [31:0] height_abs = height_raw[31] ? (~height_raw + 32'd1) : height_raw;

    // format / size validation (combinational, evaluated in VALIDATE)
    wire fmt_comb = (file_signature == 16'h4D42) &&
                    (info_size_w    == 16'd40)    &&
                    (planes_w       == 16'd1)     &&
                    (bit_depth_w    == 16'd24)    &&
                    (compress_w     == 32'd0)     &&
                    (width_abs      != 32'd0)     &&
                    (height_abs     != 32'd0);
    wire size_comb = (width_abs  <= {16'd0, MAX_WIDTH})  &&
                     (height_abs <= {16'd0, MAX_HEIGHT});

    // -----------------------------------------------------------------------
    // current byte selection (combinational)
    // -----------------------------------------------------------------------
    always @* begin
        case (word_byte)
            3'd0:    cur_word_byte = cur_word[31:24];
            3'd1:    cur_word_byte = cur_word[23:16];
            3'd2:    cur_word_byte = cur_word[15:8];
            default: cur_word_byte = cur_word[7:0];
        endcase
    end

    // RGB565 conversion submodule (B/G latched, R = current byte)
    wire [15:0] rgb565_comb;
    rgb888_to_rgb565 u_rgb (
        .blue   (px_buf0),
        .green  (px_buf1),
        .red    (cur_word_byte),
        .rgb565 (rgb565_comb)
    );

    // -----------------------------------------------------------------------
    // sequential logic (single always block: FSM transitions + data path +
    // control outputs; no cross-block races)
    // -----------------------------------------------------------------------
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= ST_IDLE;
            start_d          <= 1'b0;
            convert_busy     <= 1'b0;
            convert_done     <= 1'b0;
            format_error     <= 1'b0;
            size_error       <= 1'b0;
            stream_cnt       <= 32'd0;
            for (i = 0; i < 54; i = i + 1) header_buf[i] <= 8'h00;
            pixel_offset_reg <= 32'd0;
            image_width_reg  <= 16'd0;
            image_height_reg <= 16'd0;
            total_pixels_reg <= 32'd0;
            pixel_bytes_per_row <= 16'd0;
            row_bytes        <= 16'd0;
            image_width      <= 16'd0;
            image_height     <= 16'd0;
            cur_word         <= 32'd0;
            word_byte        <= 3'd0;
            word_valid       <= 1'b0;
            row_pos          <= 16'd0;
            x_cnt            <= 16'd0;
            y_cnt            <= 16'd0;
            px_total         <= 32'd0;
            px_buf0          <= 8'd0;
            px_buf1          <= 8'd0;
            px_byte_cnt      <= 2'd0;
            pixel_out        <= 16'd0;
            pixel_valid      <= 1'b0;
            pixel_x          <= 13'd0;
            pixel_y          <= 12'd0;
        end else begin
            // -- defaults ----------------------------------------------------
            start_d      <= convert_start;
            convert_done <= 1'b0;
            pixel_valid  <= 1'b0;

            // -- FSM ---------------------------------------------------------
            case (state)
                // -----------------------------------------------------------
                ST_IDLE: begin
                    if (convert_start && !start_d) begin
                        state        <= ST_PARSE_HEADER;
                        convert_busy <= 1'b1;
                        format_error <= 1'b0;
                        size_error   <= 1'b0;
                        stream_cnt   <= 32'd0;
                    end
                end

                // -----------------------------------------------------------
                ST_PARSE_HEADER: begin
                    if (data_valid) begin
                        if (stream_cnt < 32'd52) begin
                            header_buf[stream_cnt + 0] <= data_in[31:24];
                            header_buf[stream_cnt + 1] <= data_in[23:16];
                            header_buf[stream_cnt + 2] <= data_in[15:8];
                            header_buf[stream_cnt + 3] <= data_in[7:0];
                            stream_cnt <= stream_cnt + 32'd4;
                        end else if (stream_cnt == 32'd52) begin
                            // 14th word: bytes 52..53 complete the 54-byte
                            // header; bytes 54..55 are already pixel payload
                            header_buf[52] <= data_in[31:24];
                            header_buf[53] <= data_in[23:16];
                            stream_cnt     <= 32'd54;
                        end
                    end
                    // one cycle after the 54-byte header is complete, move on
                    if (stream_cnt >= 32'd54)
                        state <= ST_VALIDATE;
                end

                // -----------------------------------------------------------
                ST_VALIDATE: begin
                    // lock parsed geometry (consumed by CONVERT_PIXELS)
                    pixel_offset_reg    <= pixel_offset_w;
                    image_width_reg     <= width_abs[15:0];
                    image_height_reg    <= height_abs[15:0];
                    image_width         <= width_abs[15:0];
                    image_height        <= height_abs[15:0];
                    total_pixels_reg    <= width_abs * height_abs;
                    pixel_bytes_per_row <= width_abs[15:0] * 16'd3;
                    row_bytes <= (((width_abs[15:0] * 16'd3) + 16'd3) >> 2) << 2;

                    // report errors (with convert_done, see ST_DONE)
                    format_error <= ~fmt_comb;
                    size_error   <= ~size_comb;

                    if (fmt_comb && size_comb)
                        state <= ST_WAIT_PIXEL_DATA;
                    else
                        state <= ST_DONE;
                end

                // -----------------------------------------------------------
                ST_WAIT_PIXEL_DATA: begin
                    if (data_valid) begin
                        stream_cnt <= stream_cnt + 32'd4;
                        if (stream_cnt + 32'd4 > pixel_offset_reg) begin
                            // this word contains the first payload bytes:
                            // initialize the pixel conversion data path
                            state        <= ST_CONVERT_PIXELS;
                            cur_word     <= data_in;
                            word_byte    <= (pixel_offset_reg > stream_cnt) ?
                                            (pixel_offset_reg - stream_cnt) :
                                            3'd0;   // skip 0..3 header bytes
                            word_valid   <= 1'b1;
                            row_pos      <= 16'd0;
                            x_cnt        <= 16'd0;
                            y_cnt        <= 16'd0;
                            px_total     <= 32'd0;
                            px_byte_cnt  <= 2'd0;
                        end
                    end
                end

                // -----------------------------------------------------------
                ST_CONVERT_PIXELS: begin
                    // NOTE: input words are spaced >= 4 cycles by the
                    // upstream block reader, so a new data_valid never
                    // overwrites an in-flight word.
                    if (data_valid) begin
                        cur_word  <= data_in;
                        word_byte <= 3'd0;
                        word_valid<= 1'b1;
                    end else if (word_valid) begin
                        // ---- process one byte of the latched word ----
                        if (row_pos < pixel_bytes_per_row) begin
                            // pixel payload byte: BGR triplet collection
                            if (px_byte_cnt == 2'd0) begin
                                px_buf0     <= cur_word_byte;      // B
                                px_byte_cnt <= 2'd1;
                            end else if (px_byte_cnt == 2'd1) begin
                                px_buf1     <= cur_word_byte;      // G
                                px_byte_cnt <= 2'd2;
                            end else begin
                                // R arrives: emit RGB565 (B/G latched)
                                pixel_valid <= 1'b1;
                                pixel_out   <= rgb565_comb;
                                pixel_x     <= x_cnt[12:0];
                                pixel_y     <= y_cnt[11:0];
                                px_byte_cnt <= 2'd0;
                                px_total    <= px_total + 32'd1;
                                // advance output coordinates
                                if (x_cnt == image_width_reg - 16'd1) begin
                                    x_cnt <= 16'd0;
                                    y_cnt <= y_cnt + 16'd1;
                                end else begin
                                    x_cnt <= x_cnt + 16'd1;
                                end
                            end
                        end
                        // else: row padding byte — skipped (no output)

                        // advance row byte position
                        if (row_pos == row_bytes - 16'd1) row_pos <= 16'd0;
                        else                              row_pos <= row_pos + 16'd1;

                        word_byte <= word_byte + 3'd1;
                        if (word_byte == 3'd3) word_valid <= 1'b0;
                    end

                    // all pixels emitted -> done
                    // (px_total is the count AFTER the last emission; the
                    // >= comparison fires one cycle later, which is fine)
                    if (px_total >= total_pixels_reg)
                        state <= ST_DONE;
                end

                // -----------------------------------------------------------
                ST_DONE: begin
                    convert_done <= 1'b1;
                    convert_busy <= 1'b0;
                    state        <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // explicit initial values (iverilog-friendly, per task quality rule)
    // -----------------------------------------------------------------------
    initial begin
        state            = ST_IDLE;
        start_d          = 1'b0;
        convert_busy     = 1'b0;
        convert_done     = 1'b0;
        format_error     = 1'b0;
        size_error       = 1'b0;
        stream_cnt       = 32'd0;
        for (i = 0; i < 54; i = i + 1) header_buf[i] = 8'h00;
        pixel_offset_reg = 32'd0;
        image_width_reg  = 16'd0;
        image_height_reg = 16'd0;
        total_pixels_reg = 32'd0;
        pixel_bytes_per_row = 16'd0;
        row_bytes        = 16'd0;
        image_width      = 16'd0;
        image_height     = 16'd0;
        cur_word         = 32'd0;
        word_byte        = 3'd0;
        word_valid       = 1'b0;
        row_pos          = 16'd0;
        x_cnt            = 16'd0;
        y_cnt            = 16'd0;
        px_total         = 32'd0;
        px_buf0          = 8'd0;
        px_buf1          = 8'd0;
        px_byte_cnt      = 2'd0;
        pixel_out        = 16'd0;
        pixel_valid      = 1'b0;
        pixel_x          = 13'd0;
        pixel_y          = 12'd0;
    end

endmodule
