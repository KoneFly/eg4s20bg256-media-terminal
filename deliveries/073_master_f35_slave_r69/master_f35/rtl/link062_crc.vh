// 062 应用 CRC；只覆盖应用块，038 的 CRC8 原件保持不变。
function automatic [15:0] crc16_byte(input [15:0] crc, input [7:0] data);
    reg [15:0] value;
    integer bit_number;
    begin
        value=crc^{data,8'd0};
        for(bit_number=0;bit_number<8;bit_number=bit_number+1)
            value=value[15] ? (value<<1)^16'h1021 : value<<1;
        crc16_byte=value;
    end
endfunction

function automatic [15:0] crc16_packet(input [15:0] crc, input [95:0] data);
    reg [15:0] value;
    integer byte_number;
    begin
        value=crc;
        for(byte_number=0;byte_number<12;byte_number=byte_number+1)
            value=crc16_byte(value,data[8*byte_number+:8]);
        crc16_packet=value;
    end
endfunction

function automatic [95:0] seed_transform(input [95:0] data, input [2:0] seed);
    integer slot;
    begin
        seed_transform=data;
        for(slot=0;slot<8;slot=slot+1) begin
            seed_transform[12*slot+:8]=data[12*slot+:8]^{5'd0,seed};
            if((slot%2)==0)
                seed_transform[12*slot+8+:4]=data[12*slot+8+:4]^{1'b0,seed};
        end
    end
endfunction
