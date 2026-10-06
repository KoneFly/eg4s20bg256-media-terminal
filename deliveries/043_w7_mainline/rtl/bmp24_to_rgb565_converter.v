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
// * All 54 header bytes are consumed; only parsed fields are retained and
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
    // Parsed bytes only; omitted bytes have no readers.
    reg [7:0] hdr_b0;
    reg [7:0] hdr_b1;
    reg [7:0] hdr_b10;
    reg [7:0] hdr_b11;
    reg [7:0] hdr_b12;
    reg [7:0] hdr_b13;
    reg [7:0] hdr_b14;
    reg [7:0] hdr_b15;
    reg [7:0] hdr_b18;
    reg [7:0] hdr_b19;
    reg [7:0] hdr_b20;
    reg [7:0] hdr_b21;
    reg [7:0] hdr_b22;
    reg [7:0] hdr_b23;
    reg [7:0] hdr_b24;
    reg [7:0] hdr_b25;
    reg [7:0] hdr_b26;
    reg [7:0] hdr_b27;
    reg [7:0] hdr_b28;
    reg [7:0] hdr_b29;
    reg [7:0] hdr_b30;
    reg [7:0] hdr_b31;
    reg [7:0] hdr_b32;
    reg [7:0] hdr_b33;
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
    wire [15:0] file_signature = {hdr_b1,  hdr_b0};
    wire [31:0] pixel_offset_w = {hdr_b13, hdr_b12,
                                  hdr_b11, hdr_b10};
    wire [15:0] info_size_w    = {hdr_b15, hdr_b14};
    wire [31:0] width_raw      = {hdr_b21, hdr_b20,
                                  hdr_b19, hdr_b18};
    wire [31:0] height_raw     = {hdr_b25, hdr_b24,
                                  hdr_b23, hdr_b22};
    wire [15:0] planes_w       = {hdr_b27, hdr_b26};
    wire [15:0] bit_depth_w    = {hdr_b29, hdr_b28};
    wire [31:0] compress_w     = {hdr_b33, hdr_b32,
                                  hdr_b31, hdr_b30};

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
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= ST_IDLE;
            start_d          <= 1'b0;
            convert_busy     <= 1'b0;
            convert_done     <= 1'b0;
            format_error     <= 1'b0;
            size_error       <= 1'b0;
            stream_cnt       <= 32'd0;
            hdr_b0 <= 8'h00;
            hdr_b1 <= 8'h00;
            hdr_b10 <= 8'h00;
            hdr_b11 <= 8'h00;
            hdr_b12 <= 8'h00;
            hdr_b13 <= 8'h00;
            hdr_b14 <= 8'h00;
            hdr_b15 <= 8'h00;
            hdr_b18 <= 8'h00;
            hdr_b19 <= 8'h00;
            hdr_b20 <= 8'h00;
            hdr_b21 <= 8'h00;
            hdr_b22 <= 8'h00;
            hdr_b23 <= 8'h00;
            hdr_b24 <= 8'h00;
            hdr_b25 <= 8'h00;
            hdr_b26 <= 8'h00;
            hdr_b27 <= 8'h00;
            hdr_b28 <= 8'h00;
            hdr_b29 <= 8'h00;
            hdr_b30 <= 8'h00;
            hdr_b31 <= 8'h00;
            hdr_b32 <= 8'h00;
            hdr_b33 <= 8'h00;
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
                            // Header count starts at zero and advances by four.
                            case (stream_cnt[5:2])
                                4'd0: begin
                                    hdr_b0 <= data_in[31:24];
                                    hdr_b1 <= data_in[23:16];
                                end
                                4'd2: begin
                                    hdr_b10 <= data_in[15:8];
                                    hdr_b11 <= data_in[7:0];
                                end
                                4'd3: begin
                                    hdr_b12 <= data_in[31:24];
                                    hdr_b13 <= data_in[23:16];
                                    hdr_b14 <= data_in[15:8];
                                    hdr_b15 <= data_in[7:0];
                                end
                                4'd4: begin
                                    hdr_b18 <= data_in[15:8];
                                    hdr_b19 <= data_in[7:0];
                                end
                                4'd5: begin
                                    hdr_b20 <= data_in[31:24];
                                    hdr_b21 <= data_in[23:16];
                                    hdr_b22 <= data_in[15:8];
                                    hdr_b23 <= data_in[7:0];
                                end
                                4'd6: begin
                                    hdr_b24 <= data_in[31:24];
                                    hdr_b25 <= data_in[23:16];
                                    hdr_b26 <= data_in[15:8];
                                    hdr_b27 <= data_in[7:0];
                                end
                                4'd7: begin
                                    hdr_b28 <= data_in[31:24];
                                    hdr_b29 <= data_in[23:16];
                                    hdr_b30 <= data_in[15:8];
                                    hdr_b31 <= data_in[7:0];
                                end
                                4'd8: begin
                                    hdr_b32 <= data_in[31:24];
                                    hdr_b33 <= data_in[23:16];
                                end
                                default: ;
                            endcase
                            stream_cnt <= stream_cnt + 32'd4;
                        end else if (stream_cnt == 32'd52) begin
                            // 14th word: bytes 52..53 complete the 54-byte
                            // header; bytes 54..55 are already pixel payload
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
        hdr_b0 = 8'h00;
        hdr_b1 = 8'h00;
        hdr_b10 = 8'h00;
        hdr_b11 = 8'h00;
        hdr_b12 = 8'h00;
        hdr_b13 = 8'h00;
        hdr_b14 = 8'h00;
        hdr_b15 = 8'h00;
        hdr_b18 = 8'h00;
        hdr_b19 = 8'h00;
        hdr_b20 = 8'h00;
        hdr_b21 = 8'h00;
        hdr_b22 = 8'h00;
        hdr_b23 = 8'h00;
        hdr_b24 = 8'h00;
        hdr_b25 = 8'h00;
        hdr_b26 = 8'h00;
        hdr_b27 = 8'h00;
        hdr_b28 = 8'h00;
        hdr_b29 = 8'h00;
        hdr_b30 = 8'h00;
        hdr_b31 = 8'h00;
        hdr_b32 = 8'h00;
        hdr_b33 = 8'h00;
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
