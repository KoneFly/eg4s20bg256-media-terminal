`timescale 1ns/1ps
// Three-channel signed microphone mean. Two registered stages separate the
// sign-extended sum from the constant multiply; valid latency is exactly 1 clock.
module mic_three_mean_t16 (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_valid_in,
    input  wire signed [15:0] pcm1,
    input  wire signed [15:0] pcm2,
    input  wire signed [15:0] pcm3,
    output wire               sample_valid_out,
    output wire               sample_pending,
    output wire signed [15:0] sample_out
);
    wire signed [17:0] pcm1_ext = {{2{pcm1[15]}}, pcm1};
    wire signed [17:0] pcm2_ext = {{2{pcm2[15]}}, pcm2};
    wire signed [17:0] pcm3_ext = {{2{pcm3[15]}}, pcm3};
    wire signed [17:0] sum_next = pcm1_ext + pcm2_ext + pcm3_ext;

    reg signed [17:0] sum_stage;
    reg               valid_stage0;
    reg signed [33:0] product_stage;
    reg               valid_stage1;

    // 18-bit sum * positive 15-bit 21846 needs up to 33 signed bits;
    // retain 34 bits explicitly so the negative full-scale case cannot wrap.
    wire signed [33:0] product_next = $signed(sum_stage) * 34'sd21846;
    wire signed [33:0] scaled_value = product_stage >>> 16;

    assign sample_valid_out = valid_stage1;
    assign sample_pending = valid_stage0 | valid_stage1;
    assign sample_out = (scaled_value > 34'sd32767) ? 16'sd32767 :
                        (scaled_value < -34'sd32768) ? -16'sd32768 :
                        scaled_value[15:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_stage <= 18'sd0;
            valid_stage0 <= 1'b0;
            product_stage <= 34'sd0;
            valid_stage1 <= 1'b0;
        end else begin
            valid_stage0 <= sample_valid_in;
            if (sample_valid_in)
                sum_stage <= sum_next;

            valid_stage1 <= valid_stage0;
            if (valid_stage0)
                product_stage <= product_next;
        end
    end
endmodule
