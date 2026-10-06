`timescale 1ns/1ps
// 时间来源和显示精度保持，共用一个BCD进秒器；稀疏UP/消费事件优先于总时长换算。
module dashboard_time #(
    parameter [24:0] CLK_SECOND = 25'd25200000
)(
    input wire clk,input wire rst,input wire [31:0] samples_consumed,input wire audio_active,
    input wire [31:0] file_bytes,input wire file_present,input wire file_update,input wire time_set,input wire [23:0] time_set_bcd,
    output reg [23:0] played_bcd,output wire played_valid,
    output reg [23:0] total_bcd,output reg total_valid,
    output reg [23:0] up_bcd,output wire second_tick
);
    function [23:0] next_second;
        input [23:0] value;
        reg [23:0] result;
        begin
            result=value;
            if (value!=24'h995959) begin
                if (value[3:0]!=4'd9) result[3:0]=value[3:0]+4'd1;
                else begin
                    result[3:0]=4'd0;
                    if(value[7:4]!=4'd5) result[7:4]=value[7:4]+4'd1;
                    else begin
                        result[7:4]=4'd0;
                        if(value[11:8]!=4'd9) result[11:8]=value[11:8]+4'd1;
                        else begin
                            result[11:8]=4'd0;
                            if(value[15:12]!=4'd5) result[15:12]=value[15:12]+4'd1;
                            else begin
                                result[15:12]=4'd0;
                                if(value[19:16]!=4'd9) result[19:16]=value[19:16]+4'd1;
                                else begin result[19:16]=4'd0;result[23:20]=value[23:20]+4'd1;end
                            end
                        end
                    end
                end
            end
            next_second=result;
        end
    endfunction
    (* async_reg = "true" *) reg [1:0] active_sync;
    reg previous_sample_lsb;
    reg [15:0] sample_remainder;
    reg sample_started,played_pending;
    reg [24:0] up_fraction;
    reg [31:0] bytes_left;
    reg calculating;
    wire up_tick=!time_set && (up_fraction==CLK_SECOND-25'd1);
    assign second_tick=up_tick;
    wire [23:0] increment_input=up_tick ? up_bcd : played_pending ? played_bcd : total_bcd;
    wire [23:0] incremented=next_second(increment_input);
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            active_sync<=2'b00;previous_sample_lsb<=1'b0;sample_remainder<=16'd0;
            played_bcd<=24'd0;sample_started<=1'b0;played_pending<=1'b0;
        end else begin
            active_sync<={active_sync[0],audio_active};previous_sample_lsb<=samples_consumed[0];
            if(!active_sync[1] || samples_consumed==32'd0) begin
                sample_remainder<=16'd0;played_bcd<=24'd0;sample_started<=1'b0;played_pending<=1'b0;
            end else begin
                if(played_pending && !up_tick) begin
                    played_bcd<=incremented;played_pending<=1'b0;
                end
                if(samples_consumed[0]!=previous_sample_lsb) begin
                    sample_started<=1'b1;
                    if(sample_remainder==16'd47999) begin
                        sample_remainder<=16'd0;played_pending<=1'b1;
                    end else sample_remainder<=sample_remainder+16'd1;
                end
            end
        end
    end
    assign played_valid=active_sync[1] && sample_started;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            total_bcd<=24'd0;bytes_left<=32'd0;total_valid<=1'b0;calculating<=1'b0;
        end else if(!file_present) begin
            total_bcd<=24'd0;bytes_left<=32'd0;total_valid<=1'b0;calculating<=1'b0;
        end else if(file_update) begin
            bytes_left<=file_bytes;total_bcd<=24'd0;total_valid<=1'b0;calculating<=1'b1;
        end else if(calculating && !up_tick && !played_pending) begin
            if(bytes_left>=32'd96000) begin
                bytes_left<=bytes_left-32'd96000;total_bcd<=incremented;
            end else begin calculating<=1'b0;total_valid<=1'b1;end
        end
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin up_fraction<=25'd0;up_bcd<=24'd0;end
        else if(time_set) begin up_fraction<=25'd0;up_bcd<=time_set_bcd;end
        else if(up_tick) begin up_fraction<=25'd0;up_bcd<=incremented;end
        else up_fraction<=up_fraction+25'd1;
    end
endmodule
