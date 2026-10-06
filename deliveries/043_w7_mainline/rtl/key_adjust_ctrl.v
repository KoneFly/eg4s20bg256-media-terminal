`timescale 1ns/1ps
// 按键调节控制: 复用拨码消抖，ctrl域饱和档位，通过单事务快照交给pixel域。
module key_adjust_ctrl (
    input wire clk,
    input wire rst_n,
    input wire [1:0] switches,
    input wire key2_stable,
    input wire key3_stable,
    input wire key4_short,
    input wire blocked,
    input wire ack_toggle,
    output wire adjust_mode,
    output wire auto_enable,
    output reg request_toggle,
    output reg [3:0] gear_snapshot,
    output wire contrast_option
);
    wire mode_stable, auto_stable;
    key_press_debounce u_mode (
        .clk(clk), .rst_n(rst_n), .button_in(~switches[0]),
        .press_pulse(), .button_stable_out(mode_stable)
    );
    key_press_debounce u_auto (
        .clk(clk), .rst_n(rst_n), .button_in(~switches[1]),
        .press_pulse(), .button_stable_out(auto_stable)
    );
    assign adjust_mode = ~mode_stable;
    assign auto_enable = ~auto_stable;

    reg key2_d, key3_d;
    reg contrast_selected;
    assign contrast_option = contrast_selected;
    reg [1:0] brightness_pending, contrast_pending;
    (* async_reg = "true" *) reg [1:0] ack_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ack_sync <= 2'b00;
        end else begin
            ack_sync <= {ack_sync[0], ack_toggle};
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key2_d <= 1'b1;
            key3_d <= 1'b1;
            contrast_selected <= 1'b0;
            brightness_pending <= 2'd0;
            contrast_pending <= 2'd1;
            request_toggle <= 1'b0;
            gear_snapshot <= {2'd1, 2'd0};
        end else begin
            key2_d <= key2_stable;
            key3_d <= key3_stable;
            if (adjust_mode && !blocked) begin
                if (key4_short)
                    contrast_selected <= ~contrast_selected;
                if (!key2_stable && key2_d && key3_stable) begin
                    if (contrast_selected) begin
                        if (contrast_pending != 2'd3)
                            contrast_pending <= contrast_pending + 2'd1;
                    end else if (brightness_pending != 2'd3) begin
                        brightness_pending <= brightness_pending + 2'd1;
                    end
                end else if (!key3_stable && key3_d && key2_stable) begin
                    if (contrast_selected) begin
                        if (contrast_pending != 2'd0)
                            contrast_pending <= contrast_pending - 2'd1;
                    end else if (brightness_pending != 2'd0) begin
                        brightness_pending <= brightness_pending - 2'd1;
                    end
                end
            end
            // 已交付快照在ack返回前保持；期间的新档位只累积为下一份快照。
            if (ack_sync[1] == request_toggle &&
                gear_snapshot != {contrast_pending, brightness_pending}) begin
                gear_snapshot <= {contrast_pending, brightness_pending};
                request_toggle <= ~request_toggle;
            end
        end
    end
endmodule
