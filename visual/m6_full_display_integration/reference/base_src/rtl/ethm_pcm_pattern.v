`timescale 1 ns / 10 ps
//------------------------------------------------------------------------------
// 测试载荷图形发生器: 样本值 = f(绝对样本序号, salt), 纯组合、可按序号直接寻址。
// 可按序号寻址 => 接收端出现序号缺口时无需"快进"状态机即可校验内容, 也不会在
// 复位/重连后残留上一会话的期望值。salt 取 epoch 的低 16 位, 使换 epoch 后
// 图形整体变化(旧数据被当作新数据接受的可能性下降)。
// 移位+异或构成 16bit 上的双射混合, 单 bit 序号变化平均翻转约一半码位。
//------------------------------------------------------------------------------
module ethm_pcm_pattern (
    input  wire [31:0] sample_index,
    input  wire [15:0] salt,
    output wire [15:0] value
);
    function [31:0] mix32;
        input [31:0] d;
        begin
            mix32 = d ^ (d >> 16);
            mix32 = mix32 ^ (mix32 << 7);
            mix32 = mix32 ^ (mix32 >> 9);
        end
    endfunction

    wire [31:0] mixed = mix32(sample_index ^ {salt, 16'h4D36});

    assign value = mixed[15:0] ^ mixed[31:16];
endmodule
