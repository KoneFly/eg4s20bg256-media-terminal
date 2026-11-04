`timescale 1ns/1ps
// 0..20对应0..100%；按样本启动21拍串行常数除法，保持负数向下取整，避免宽组合除法。
module wm_audio_gain(
    input wire clk,rst,sample_valid,
    input wire signed [15:0] sample,
    input wire [4:0] volume_steps,
    output reg valid,
    output reg signed [15:0] scaled,
    output wire busy
);
    reg working,negative;
    reg [20:0] numerator;
    reg [20:0] quotient;
    reg [5:0] remainder;
    reg [4:0] bit_index;
    wire [15:0] magnitude=sample[15] ? (~sample+16'd1) : sample;
    wire [20:0] product={5'd0,magnitude}*{16'd0,volume_steps};
    wire [5:0] step_rem={remainder[4:0],numerator[bit_index]};
    wire take=step_rem>=6'd20;
    wire [20:0] next_quotient={quotient[19:0],take};
    wire [5:0] next_rem=take ? step_rem-6'd20 : step_rem;
    wire [15:0] rounded=next_quotient[15:0]+(negative&&next_rem!=0 ? 16'd1 : 16'd0);
    assign busy=working;
    always @(posedge clk or posedge rst)begin
        if(rst)begin working<=0;negative<=0;numerator<=0;quotient<=0;remainder<=0;bit_index<=0;valid<=0;scaled<=0;end
        else begin
            valid<=0;
            if(sample_valid&&!working)begin
                numerator<=product;negative<=sample[15];quotient<=0;remainder<=0;bit_index<=20;working<=1;
            end else if(working)begin
                quotient<=next_quotient;remainder<=next_rem;
                if(bit_index==0)begin scaled<=negative ? -$signed(rounded) : $signed(rounded);valid<=1;working<=0;end
                else bit_index<=bit_index-5'd1;
            end
        end
    end
endmodule
