`timescale 1ns/1ps
// 32位大端文件字流 -> RIFF/WAVE PCM16小端单声道；严格限定48kHz。
// 不依赖扇区边界，按目录file_size截断最后字，不把文件填充当PCM。
// RIFF长度与块长度的越界检查放在收齐4字节后的独立一拍(CHKR/CHKC, 不消费字节),
// 让33位比较从寄存器出发, 不与字节移位/计数选择串在同一拍。
// 面积: fmt 16字节逐字节与期望常量比较(不存整块); fmt/跳过/数据三段共用一个剩余
//   计数; RIFF 只记剩余字节与越界标志; 文件剩余量用一个递减计数代替已收/总量两个。
module t072_wav_parser(
    input wire clk,rst_n,start,input wire [31:0] file_size,
    input wire in_valid,input wire[31:0] in_data,output wire in_ready,
    input wire stream_done,
    output wire pcm_valid,output wire signed[15:0] pcm,input wire pcm_ready,
    output reg header_valid,output wire eof,error,output reg[3:0] error_code,
    output reg[31:0] samples_total,output wire busy
);
    localparam [3:0] IDLE=0,RIFF=1,CHUNK_ID=2,CHUNK_SIZE=3,FMT=4,SKIP=5,DATA=6,DONE=7,ERROR=8,CHKR=9,CHKC=10;
    reg[3:0] state;
    reg[31:0] remain,riff_left,cnt,field,held;
    reg[31:0] file_size_q;            // RIFF 长度检查需要原始文件长度
    reg riff_over,is_fmt,is_data,fmt_pad,fmt_seen,fmt_bad,lo_pending,end_seen;
    reg[2:0] held_bytes;
    reg[1:0] field_index;
    reg[3:0] hdr_pos;
    reg[4:0] fmt_index;
    reg[7:0] lo;
    wire[7:0] byte_value=held[31:24];
    wire[31:0] field_next={byte_value,field[31:8]};
    wire active=state!=IDLE&&state!=DONE&&state!=ERROR;
    wire checking=state==CHKR||state==CHKC;
    assign busy=active;
    assign eof=state==DONE;
    assign error=state==ERROR;
    assign in_ready=!start&&(!active||held_bytes==0);
    assign pcm_valid=!start&&state==DATA&&held_bytes!=0&&lo_pending;
    assign pcm=$signed({byte_value,lo});
    wire consume=active&&!checking&&held_bytes!=0&&!(state==DATA&&lo_pending&&!pcm_ready);
    // PCM 格式块前 16 字节: 格式1 声道1 48000Hz 96000B/s 对齐2 16位(小端)
    reg[7:0] fmt_exp;
    always @(*)begin
        case(fmt_index[3:0])
        4'd0:fmt_exp=8'h01; 4'd2:fmt_exp=8'h01; 4'd4:fmt_exp=8'h80; 4'd5:fmt_exp=8'hBB;
        4'd9:fmt_exp=8'h77; 4'd10:fmt_exp=8'h01; 4'd12:fmt_exp=8'h02; 4'd14:fmt_exp=8'h10;
        default:fmt_exp=8'h00;
        endcase
    end
    wire fmt_fail=fmt_bad||(byte_value!=fmt_exp);
    wire[32:0] chunk_need={1'b0,field}+{32'd0,field[0]};
    task reject(input[3:0] code);
        begin state<=ERROR;error_code<=code;held_bytes<=0;lo_pending<=0;end
    endtask
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            state<=IDLE;remain<=0;file_size_q<=0;riff_left<=0;cnt<=0;field<=0;held<=0;
            riff_over<=0;is_fmt<=0;is_data<=0;fmt_pad<=0;fmt_seen<=0;fmt_bad<=0;lo_pending<=0;end_seen<=0;
            held_bytes<=0;field_index<=0;hdr_pos<=0;fmt_index<=0;lo<=0;
            header_valid<=0;error_code<=0;samples_total<=0;
        end else if(start)begin
            state<=file_size>=12 ? RIFF : ERROR;error_code<=file_size>=12 ? 0 : 1;
            remain<=file_size;file_size_q<=file_size;riff_left<=0;riff_over<=0;cnt<=0;field<=0;held_bytes<=0;
            field_index<=0;hdr_pos<=0;fmt_index<=0;fmt_seen<=0;fmt_bad<=0;
            lo_pending<=0;header_valid<=0;samples_total<=0;end_seen<=0;
        end else begin
            if(stream_done)end_seen<=1;
            if(in_valid&&in_ready&&active&&remain!=0)begin
                held<=in_data;held_bytes<=remain>=4 ? 3'd4 : remain[2:0];
                remain<=remain>=4 ? remain-4 : 32'd0;
            end
            if(state==CHKR)begin
                if(field<4||({1'b0,field}+33'd8)>{1'b0,file_size_q})reject(2);
                else begin riff_left<=field;state<=RIFF;end
            end else if(state==CHKC)begin
                field_index<=0;field<=0;
                if(riff_over||chunk_need>{1'b0,riff_left})reject(2);
                else if(is_fmt)begin
                    if(field<16||fmt_seen)reject(3);
                    else begin state<=FMT;fmt_index<=0;fmt_bad<=0;cnt<=field;fmt_pad<=field[0];end
                end else if(is_data)begin
                    if(!fmt_seen||field[0])reject(4);
                    else begin header_valid<=1;samples_total<=field>>1;cnt<=field;
                        lo_pending<=0;state<=field==0 ? DONE : DATA;end
                end else begin
                    cnt<=chunk_need[31:0];
                    state<=field==0 ? CHUNK_ID : SKIP;
                end
            end else if(consume)begin
                held<=held<<8;held_bytes<=held_bytes-1'b1;
                if(state!=RIFF||hdr_pos>=4'd8)begin
                    if(riff_left==0)riff_over<=1;
                    riff_left<=riff_left-1'b1;
                end
                case(state)
                RIFF:begin
                    field<=field_next;hdr_pos<=hdr_pos+1'b1;
                    if(hdr_pos==3&&field_next!=32'h46464952)reject(1);
                    else if(hdr_pos==7)state<=CHKR;
                    else if(hdr_pos==11)begin
                        if(field_next!=32'h45564157)reject(1);
                        else begin state<=CHUNK_ID;field_index<=0;field<=0;end
                    end
                end
                CHUNK_ID:begin
                    field<=field_next;
                    if(field_index==3)begin
                        is_fmt<=field_next==32'h20746d66;is_data<=field_next==32'h61746164;
                        field_index<=0;field<=0;state<=CHUNK_SIZE;
                    end else field_index<=field_index+1'b1;
                end
                CHUNK_SIZE:begin
                    field<=field_next;
                    if(field_index==3)state<=CHKC;
                    else field_index<=field_index+1'b1;
                end
                FMT:begin
                    cnt<=cnt-1'b1;
                    if(fmt_index<16)begin
                        fmt_index<=fmt_index+1'b1;fmt_bad<=fmt_fail;
                        if(fmt_index==15)begin
                            if(fmt_fail)reject(5);else fmt_seen<=1;
                        end
                    end
                    if(cnt==1)begin
                        if(fmt_pad)begin state<=SKIP;cnt<=1;end else state<=CHUNK_ID;
                        // format错误优先于同拍正常fmt收尾。
                        if(fmt_index==15&&fmt_fail)reject(5);
                    end
                end
                SKIP:begin cnt<=cnt-1'b1;if(cnt==1)begin state<=CHUNK_ID;field_index<=0;field<=0;end end
                DATA:begin
                    cnt<=cnt-1'b1;
                    if(!lo_pending)begin lo<=byte_value;lo_pending<=1;end else lo_pending<=0;
                    if(cnt==1)begin state<=DONE;held_bytes<=0;end
                end
                default:begin end
                endcase
            end else if(active&&held_bytes==0&&
                        ((remain==0)||(end_seen&&!in_valid)))reject(6);
        end
    end
endmodule
