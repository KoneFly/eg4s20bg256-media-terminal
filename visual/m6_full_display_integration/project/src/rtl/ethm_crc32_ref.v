`timescale 1 ns / 10 ps
//------------------------------------------------------------------------------
// CRC-32/ISO-HDLC —— 051 共同数据契约的应用层校验字段。
// poly 0xEDB88320(反射), init/xorout 0xFFFFFFFF, 每拍吞一个字节(字节低位先参与)。
//
// 状态方程是 byte-parallel 的一次性异或网络, 不是 8 步串行循环: 串行写法会拉出
// 8 级依赖链, 实测把 125MHz 的 tx 域 Fmax 压到 77MHz(WNS -4.9ns)。这里由符号模拟
// 8 步 LFSR 生成等价方程, 每位最多 14 个输入项, 两级 LUT 即可成形。
// 方程正确性由 tests/tb_crc32_selfcheck.v 的两个金标准向量自证:
//   "123456789" -> 0xCBF43926(规范 check value),  单字节 0x00 -> 0xD202EF8D。
//------------------------------------------------------------------------------
module ethm_crc32_ref (
    input  wire        clk,
    input  wire        rst,
    input  wire        load_init,
    input  wire        byte_valid,
    input  wire [7:0]  byte_in,
    output reg  [31:0] crc
);
    wire [31:0] c_next;

    assign c_next[ 0] = crc[2] ^ crc[8] ^ byte_in[2];
    assign c_next[ 1] = crc[0] ^ crc[3] ^ crc[9] ^ byte_in[0] ^ byte_in[3];
    assign c_next[ 2] = crc[0] ^ crc[1] ^ crc[4] ^ crc[10] ^ byte_in[0] ^ byte_in[1] ^ byte_in[4];
    assign c_next[ 3] = crc[1] ^ crc[2] ^ crc[5] ^ crc[11] ^ byte_in[1] ^ byte_in[2] ^ byte_in[5];
    assign c_next[ 4] = crc[0] ^ crc[2] ^ crc[3] ^ crc[6] ^ crc[12] ^ byte_in[0] ^ byte_in[2] ^ byte_in[3] ^ byte_in[6];
    assign c_next[ 5] = crc[1] ^ crc[3] ^ crc[4] ^ crc[7] ^ crc[13] ^ byte_in[1] ^ byte_in[3] ^ byte_in[4] ^ byte_in[7];
    assign c_next[ 6] = crc[4] ^ crc[5] ^ crc[14] ^ byte_in[4] ^ byte_in[5];
    assign c_next[ 7] = crc[0] ^ crc[5] ^ crc[6] ^ crc[15] ^ byte_in[0] ^ byte_in[5] ^ byte_in[6];
    assign c_next[ 8] = crc[1] ^ crc[6] ^ crc[7] ^ crc[16] ^ byte_in[1] ^ byte_in[6] ^ byte_in[7];
    assign c_next[ 9] = crc[7] ^ crc[17] ^ byte_in[7];
    assign c_next[10] = crc[2] ^ crc[18] ^ byte_in[2];
    assign c_next[11] = crc[3] ^ crc[19] ^ byte_in[3];
    assign c_next[12] = crc[0] ^ crc[4] ^ crc[20] ^ byte_in[0] ^ byte_in[4];
    assign c_next[13] = crc[0] ^ crc[1] ^ crc[5] ^ crc[21] ^ byte_in[0] ^ byte_in[1] ^ byte_in[5];
    assign c_next[14] = crc[1] ^ crc[2] ^ crc[6] ^ crc[22] ^ byte_in[1] ^ byte_in[2] ^ byte_in[6];
    assign c_next[15] = crc[2] ^ crc[3] ^ crc[7] ^ crc[23] ^ byte_in[2] ^ byte_in[3] ^ byte_in[7];
    assign c_next[16] = crc[0] ^ crc[2] ^ crc[3] ^ crc[4] ^ crc[24] ^ byte_in[0] ^ byte_in[2] ^ byte_in[3] ^ byte_in[4];
    assign c_next[17] = crc[0] ^ crc[1] ^ crc[3] ^ crc[4] ^ crc[5] ^ crc[25] ^ byte_in[0] ^ byte_in[1] ^ byte_in[3] ^ byte_in[4] ^ byte_in[5];
    assign c_next[18] = crc[0] ^ crc[1] ^ crc[2] ^ crc[4] ^ crc[5] ^ crc[6] ^ crc[26] ^ byte_in[0] ^ byte_in[1] ^ byte_in[2] ^ byte_in[4] ^ byte_in[5] ^ byte_in[6];
    assign c_next[19] = crc[1] ^ crc[2] ^ crc[3] ^ crc[5] ^ crc[6] ^ crc[7] ^ crc[27] ^ byte_in[1] ^ byte_in[2] ^ byte_in[3] ^ byte_in[5] ^ byte_in[6] ^ byte_in[7];
    assign c_next[20] = crc[3] ^ crc[4] ^ crc[6] ^ crc[7] ^ crc[28] ^ byte_in[3] ^ byte_in[4] ^ byte_in[6] ^ byte_in[7];
    assign c_next[21] = crc[2] ^ crc[4] ^ crc[5] ^ crc[7] ^ crc[29] ^ byte_in[2] ^ byte_in[4] ^ byte_in[5] ^ byte_in[7];
    assign c_next[22] = crc[2] ^ crc[3] ^ crc[5] ^ crc[6] ^ crc[30] ^ byte_in[2] ^ byte_in[3] ^ byte_in[5] ^ byte_in[6];
    assign c_next[23] = crc[3] ^ crc[4] ^ crc[6] ^ crc[7] ^ crc[31] ^ byte_in[3] ^ byte_in[4] ^ byte_in[6] ^ byte_in[7];
    assign c_next[24] = crc[0] ^ crc[2] ^ crc[4] ^ crc[5] ^ crc[7] ^ byte_in[0] ^ byte_in[2] ^ byte_in[4] ^ byte_in[5] ^ byte_in[7];
    assign c_next[25] = crc[0] ^ crc[1] ^ crc[2] ^ crc[3] ^ crc[5] ^ crc[6] ^ byte_in[0] ^ byte_in[1] ^ byte_in[2] ^ byte_in[3] ^ byte_in[5] ^ byte_in[6];
    assign c_next[26] = crc[0] ^ crc[1] ^ crc[2] ^ crc[3] ^ crc[4] ^ crc[6] ^ crc[7] ^ byte_in[0] ^ byte_in[1] ^ byte_in[2] ^ byte_in[3] ^ byte_in[4] ^ byte_in[6] ^ byte_in[7];
    assign c_next[27] = crc[1] ^ crc[3] ^ crc[4] ^ crc[5] ^ crc[7] ^ byte_in[1] ^ byte_in[3] ^ byte_in[4] ^ byte_in[5] ^ byte_in[7];
    assign c_next[28] = crc[0] ^ crc[4] ^ crc[5] ^ crc[6] ^ byte_in[0] ^ byte_in[4] ^ byte_in[5] ^ byte_in[6];
    assign c_next[29] = crc[0] ^ crc[1] ^ crc[5] ^ crc[6] ^ crc[7] ^ byte_in[0] ^ byte_in[1] ^ byte_in[5] ^ byte_in[6] ^ byte_in[7];
    assign c_next[30] = crc[0] ^ crc[1] ^ crc[6] ^ crc[7] ^ byte_in[0] ^ byte_in[1] ^ byte_in[6] ^ byte_in[7];
    assign c_next[31] = crc[1] ^ crc[7] ^ byte_in[1] ^ byte_in[7];

    always @(posedge clk or posedge rst) begin
        if (rst)
            crc <= 32'hFFFF_FFFF;
        else if (load_init)
            crc <= 32'hFFFF_FFFF;
        else if (byte_valid)
            crc <= c_next;
    end
endmodule
