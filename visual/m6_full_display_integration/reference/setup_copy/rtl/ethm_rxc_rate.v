`timescale 1 ns / 10 ps
//------------------------------------------------------------------------------
// RXC 速率/存在性测量。不经 MDIO 也回答"协商到什么速率": 接收时钟域每 4096 拍
// 翻转一次电平, 统计域在固定 8ms 窗口内数沿。
//   1G   -> rx_clk=125MHz -> 约 244 沿/8ms
//   100M -> rx_clk=25MHz  -> 约 49 沿/8ms
//   10M  -> rx_clk=2.5MHz -> 约 5 沿/8ms
//   无 RXC(链路未建立 / rx PLL 未锁) -> 0 沿
// 单 bit 跨域(2FF)最多少数一两个沿, 与分档阈值相差 4 倍以上, 判定稳健。
//
// clk 现在是 app_clk(25MHz): 分频翻转仍按 rx_clk 的拍数(量的是 RXC 本身), 窗口
// 由 25MHz 域的 ms_tick 给出, 8ms 窗口内的沿数不变 => 分档阈值不用改。
// tx_rst 端口名沿用, 实参已经是本窗口域(app)的复位。
//------------------------------------------------------------------------------
module ethm_rxc_rate (
    input  wire       rx_clk,
    input  wire       clk,
    input  wire       rx_rst,
    input  wire       tx_rst,
    input  wire       ms_tick,
    output reg  [3:0] rate_code
);
    reg  [11:0] div_cnt;
    reg         tgl;
    reg         tgl_s1;
    reg         tgl_s2;
    reg  [8:0]  edge_cnt;
    reg  [3:0]  ms_cnt;

    always @(posedge rx_clk) begin
        if (rx_rst) begin
            div_cnt <= 12'd0;
            tgl     <= 1'b0;
        end
        else if (div_cnt == 12'd4095) begin
            div_cnt <= 12'd0;
            tgl     <= ~tgl;
        end
        else begin
            div_cnt <= div_cnt + 12'd1;
        end
    end

    wire tgl_pulse = tgl_s2 ^ tgl_s1;

    always @(posedge clk) begin
        if (tx_rst) begin
            tgl_s1    <= 1'b0;
            tgl_s2    <= 1'b0;
            edge_cnt  <= 9'd0;
            ms_cnt    <= 4'd0;
            rate_code <= 4'd0;
        end
        else begin
            tgl_s1 <= tgl;
            tgl_s2 <= tgl_s1;
            if (tgl_pulse && (edge_cnt != 9'h1FF))
                edge_cnt <= edge_cnt + 9'd1;

            if (ms_tick) begin
                if (ms_cnt == 4'd7) begin
                    ms_cnt <= 4'd0;
                    if (edge_cnt >= 9'd120)     rate_code <= 4'd3;
                    else if (edge_cnt >= 9'd24) rate_code <= 4'd2;
                    else if (edge_cnt >= 9'd2)  rate_code <= 4'd1;
                    else                        rate_code <= 4'd0;
                    edge_cnt <= 9'd0;
                end
                else begin
                    ms_cnt <= ms_cnt + 4'd1;
                end
            end
        end
    end
endmodule
