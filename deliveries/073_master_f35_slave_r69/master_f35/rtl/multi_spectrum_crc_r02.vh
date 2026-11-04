// CRC-16/CCITT-FALSE；与冻结062应用层参数一致。
function automatic [15:0] crc16_byte(input [15:0] crc,input [7:0] data);
    reg [15:0] value;
    integer bit_number;
    begin
        value=crc^{data,8'd0};
        for(bit_number=0;bit_number<8;bit_number=bit_number+1)
            value=value[15] ? (value<<1)^16'h1021 : value<<1;
        crc16_byte=value;
    end
endfunction
