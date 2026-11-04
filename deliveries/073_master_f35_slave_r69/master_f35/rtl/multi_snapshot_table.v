`timescale 1ns/1ps
// bundled toggle发布：元数据保持至ack；前台仅帧边界切换。两域alive重会合后开放写入。
module multi_snapshot_table(
    input wire ctrl_clk,pixel_clk,ctrl_rst_n,pixel_rst_n,frame_boundary,
    input wire write_valid,input wire [8:0] write_address,input wire [7:0] write_data,
    input wire publish,input wire [1:0] publish_paths,input wire [31:0] publish_epoch,publish_end,
    output wire bank_free,output wire bank_reset,
    input wire [8:0] read_address,output reg [7:0] read_data,
    input wire [8:0] render_address,output reg [7:0] render_data,
    output reg [8:0] render_address_q,
    output reg render_bank_q,render_valid_q,
    input wire [8:0] render_address_b,output reg [7:0] render_data_b,
    output reg [8:0] render_address_b_q,
    output reg render_bank_b_q,render_valid_b_q,
    output reg [1:0] display_paths,
    output reg display_valid,output reg [31:0] display_epoch,display_end,output reg display_bank
);
    (* ram_style="bram" *) reg [7:0] memory[0:1023];
    (* ram_style="bram" *) reg [7:0] render_memory[0:1023];
    // 观察器仍独占 memory；第二绘制口使用独立同写镜像。
    (* ram_style="bram" *) reg [7:0] render_memory_b[0:1023];
    reg back_bank,request,ack;
    reg [67:0] bundle;
    reg ctrl_alive,pixel_alive;
    (* preserve="true" *) reg [1:0] ack_sync,req_sync,pa_sync,ca_sync;
    reg [1:0] ctrl_state,pixel_state;
    reg [3:0] ctrl_boot,pixel_boot;
    reg seen_ctrl_low;
    reg [3:0] age_frames;
    assign bank_free=ctrl_state==2&&ctrl_alive&&pa_sync[1]&&ack_sync[1]==request;
    assign bank_reset=ctrl_state!=2||!pa_sync[1];
    always @(posedge ctrl_clk) if(write_valid&&bank_free&&write_address<9'd384) begin
        memory[{back_bank,write_address}]<=write_data;
        render_memory[{back_bank,write_address}]<=write_data;
        render_memory_b[{back_bank,write_address}]<=write_data;
    end
    always @(posedge pixel_clk) begin
        read_data<=memory[{display_bank,read_address}];
        render_data<=render_memory[{display_bank,render_address}];
        render_data_b<=render_memory_b[{display_bank,render_address_b}];
    end
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if(!pixel_rst_n) begin
            render_address_q<=0;render_bank_q<=0;render_valid_q<=0;
            render_address_b_q<=0;render_bank_b_q<=0;render_valid_b_q<=0;
        end
        else begin
            render_address_q<=render_address;render_bank_q<=display_bank;
            render_valid_q<=display_valid&&!frame_boundary&&
                ({1'b0,render_address} < {1'b0,display_paths,7'd0});
            render_address_b_q<=render_address_b;render_bank_b_q<=display_bank;
            render_valid_b_q<=display_valid&&!frame_boundary&&
                ({1'b0,render_address_b} < {1'b0,display_paths,7'd0});
        end
    end
    always @(posedge ctrl_clk or negedge ctrl_rst_n) begin
        if(!ctrl_rst_n) begin
            back_bank<=1;request<=0;bundle<=0;ctrl_alive<=0;ctrl_state<=0;ctrl_boot<=0;ack_sync<=0;pa_sync<=0;
        end else begin
            ack_sync<={ack_sync[0],ack};pa_sync<={pa_sync[0],pixel_alive};
            case(ctrl_state)
                0:if(ctrl_boot==4'd8) begin ctrl_alive<=1;ctrl_state<=1;end else ctrl_boot<=ctrl_boot+4'd1;
                1:if(pa_sync[1]) ctrl_state<=2;
                2:if(!pa_sync[1]) begin
                    ctrl_state<=0;ctrl_boot<=0;ctrl_alive<=0;request<=0;bundle<=0;back_bank<=1;
                end else if(publish&&bank_free&&publish_paths!=2'd0) begin bundle<={publish_paths,1'b1,back_bank,publish_epoch,publish_end};request<=~request;end
                default:ctrl_state<=0;
            endcase
            // 完成ack时按实际已发布bank确定后台。
            if(ctrl_state==2&&pa_sync[1]&&ack_sync[1]==request) back_bank<=~bundle[64];
        end
    end
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if(!pixel_rst_n) begin
            ack<=0;req_sync<=0;ca_sync<=0;pixel_alive<=0;pixel_state<=0;pixel_boot<=0;seen_ctrl_low<=0;
            display_paths<=0;display_valid<=0;display_epoch<=0;display_end<=0;display_bank<=0;age_frames<=0;
        end else begin
            req_sync<={req_sync[0],request};ca_sync<={ca_sync[0],ctrl_alive};
            if(!ca_sync[1]) seen_ctrl_low<=1;
            case(pixel_state)
                0:if(pixel_boot==4'd8&&seen_ctrl_low&&ca_sync[1]) pixel_state<=1;else if(pixel_boot!=4'd8) pixel_boot<=pixel_boot+4'd1;
                1:if(frame_boundary&&ca_sync[1]) begin
                    ack<=0;display_bank<=0;display_paths<=0;display_valid<=0;age_frames<=0;pixel_alive<=1;pixel_state<=2;
                end
                2:if(!ca_sync[1]) begin pixel_alive<=0;pixel_state<=1;end
                  else if(frame_boundary) begin
                    if(req_sync[1]!=ack) begin
                        {display_paths,display_valid,display_bank,display_epoch,display_end}<=bundle;age_frames<=0;ack<=req_sync[1];
                    end else if(display_valid) begin
                        if(age_frames==4'd12) display_valid<=0;else age_frames<=age_frames+4'd1;
                    end
                  end
                default:pixel_state<=0;
            endcase
        end
    end
endmodule
