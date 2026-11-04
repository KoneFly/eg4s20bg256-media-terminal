`timescale 1 ns / 10 ps
//------------------------------------------------------------------------------
// 字节中继异步 FIFO: 把"应用侧(25MHz app_clk)"与"MAC 侧(125MHz)"隔开。
// 字宽 10bit = {kind[1:0], data[7:0]}:
//   2'b00 帧内数据字节
//   2'b01 帧内最后一个数据字节(帧边界由这个标记给出, 不再靠 dv 落沿去猜)
//   2'b10 元数据字(只有 RX FIFO 用): data[7:0] = {mac_crc_bad, 6'b0, truncated}
//
// 结构沿用本包 ethm_rec_fifo 已上板验证的灰码指针做法: 二进制+回绕位指针、
// 灰码跨域、2FF 同步器、读出口寄存。差别只有两处:
//   1) 位宽 10, 深度 512;
//   2) 读侧不给出"请求即取"的裸 rd_en 语义, 而是给 rd_vld/rd_kind/rd_last
//      (与 rd_data 同拍的组合) + rd_en(= 消费本拍这个字)。
//
// 为什么读侧要这样配对(后人必须看懂): rd_data 是寄存输出, 请求与数据差一拍。
// 若消费者把 rd_empty 当"有数据"来判, 就会重复消费同一个字或吃掉一个陈旧字。
// 本模块把这条记账收在内部, rd_en 的含义是"本拍处理掉槽里那个字; 槽空时就是取字":
//   取到新字(rd_fire)                => 下一拍槽里有一个未消费的字
//   没取到新字但本拍消费掉了(ack)     => 下一拍槽是空的
//   其余(既没取也没消费)              => 槽里的字原地不动
// 消费者必须让取字请求组合依赖 rd_vld(字一到就自动收回请求), 否则字一到就被
// 第二次 rd_en 悄悄吃掉 —— 本包三个消费者都按这条写。
// 消费与取新字落在同一拍 => 帧内可以每拍一个字节不留空隙(发送排空机的硬约束)。
//
// 深度 512 的依据(两侧共用, 各自的最坏突发都算过):
//   * 一帧应用字节 306 个。RX 侧: 写侧每拍 1 字节(8ns), 读侧每拍 1 字节(40ns),
//     单帧突发最坏积压 306 + 元数据 => 256 装不下一帧, 512 留一倍余量。
//     平均速率毫无压力: 375 包/s x 306B = 114,750 字节/s, 读侧能力 25M 字节/s,
//     相差约 220 倍; 排空一帧 306 字只要 12.2us, 而包间隔是 2.67ms。
//   * TX 侧: 发包机一次写满 306 字, 靠 wr_space(整帧装得下)门控启动, 启动后
//     只做写入不回头, 所以启动那拍余量 >=320 就不会碰满。
//   * 因此"写但满"只可能是结构性 bug —— 本模块把它寄存成 wr_ovf 脉冲输出,
//     统计域累计, 绝对不允许静默丢字(VERIFICATION_CONTRACT: 溢出必须可见)。
//
// 存储体的物理形态(v6e 起, 依 §6.4 探针结论):
//   mem 由 TD 推断进 **1 块 BRAM9K**(512×10, 见探针第 5 轮 prb_c5: SYN-1026 +
//   分层行 lut=65 ripple=17 seq=62 bram=1; 改动前是 lut≈619 + 0 bram 的分布式 RAM)。
//   代价只有一处: 读出口寄存器不能带复位(见下面 rd_data_r 的注释)。
//   读延迟仍是**恰好 1 拍**、读使能仍由 rd_fire 门控、不读即保持 —— 由网表参数
//   EG_PHY_BRAM.REGMODE_B="NOREG" 且 dob 直连 rd_data(没有多出一级 FF)实测确认,
//   不是推测。⇒ 满空释放延迟、SPACE_MIN 整帧预存门、rd_usedw 水位口径全部不变。
//------------------------------------------------------------------------------
module ethm_bafifo #(
    parameter integer DEPTH     = 512,   // 必须是 2^AW
    parameter integer AW        = 9,     // log2(DEPTH)
    // wr_space 的门限: "至少还能装 SPACE_MIN 个字"。默认 8(近满门);
    // TX 实例取 320 = 306 字整帧 + 14 余量, 使"起帧"即保证整帧装得下。
    parameter integer SPACE_MIN = 8
)(
    // ---------------- 写域 ----------------
    input  wire        wr_clk,
    input  wire        wr_rst,
    input  wire        wr_en,
    input  wire [9:0]  wr_data,
    output wire        wr_full,
    output wire        wr_space,
    output reg         wr_ovf,      // 寄存脉冲: 本拍想写但满(不得静默)

    // ---------------- 读域 ----------------
    input  wire        rd_clk,
    input  wire        rd_rst,
    input  wire        rd_en,       // = 消费本拍 rd_data 的那个字
    output wire [9:0]  rd_data,
    output reg         rd_vld,      // 与 rd_data 同拍: 槽里是一个未消费的新字
    output wire [1:0]  rd_kind,
    output wire        rd_last,     // = (rd_kind == 2'b01)
    output wire        rd_empty,
    output wire [9:0]  rd_usedw
);
    localparam [AW:0] DEPTH_EXT = {1'b1, {AW{1'b0}}};
    localparam integer PW       = AW + 1;   // 指针/占用的位宽

    wire [AW:0] wr_gray;
    wire [AW:0] rd_gray;

    function [AW:0] f_bin2gray;
        input [AW:0] b;
        begin
            f_bin2gray = b ^ (b >> 1);
        end
    endfunction

    function [AW:0] f_gray2bin;
        input [AW:0] g;
        reg   [AW:0] b;
        integer j;
        begin
            b[AW] = g[AW];
            for (j = AW - 1; j >= 0; j = j - 1)
                b[j] = b[j + 1] ^ g[j];
            f_gray2bin = b;
        end
    endfunction

    // ---------------- 写域 ----------------
    reg  [AW:0] wr_bin;
    assign wr_gray = f_bin2gray(wr_bin);

    reg  [AW:0] rd_gray_w1;
    reg  [AW:0] rd_gray_w2;
    always @(posedge wr_clk) begin
        if (wr_rst) begin
            rd_gray_w1 <= {(AW + 1){1'b0}};
            rd_gray_w2 <= {(AW + 1){1'b0}};
        end
        else begin
            rd_gray_w1 <= rd_gray;
            rd_gray_w2 <= rd_gray_w1;
        end
    end

    // 满标志用**灰码直接比较**, 不在写域做"灰码->二进制"解码:
    // 2 的幂深度下 full <=> 写灰码 == {读灰码高两位取反, 其余同}, 只有两级异或。
    // 之前先解码再相减再比较, 那 10 级行波解码在接收域(125MHz)里被 TD 塞进了
    // RAM 读控制, 179 个端点 -0.954ns; 而写侧真正需要的只有"满"和(仅 TX 实例用到的)
    // "余量", 后者本来就在 25MHz 应用域, 慢慢解码即可。
    wire [AW:0] rd_gray_w2_inv = {~rd_gray_w2[AW:AW-1], rd_gray_w2[AW-2:0]};
    assign wr_full     = (wr_gray == rd_gray_w2_inv);

    wire [AW:0] rd_bin_w = f_gray2bin(rd_gray_w2);
    // 同步来的读指针只会"落后", 所以 occ_w 只会偏大 => wr_space 偏保守
    wire [AW:0] occ_w    = wr_bin - rd_bin_w;

    // 余量在 32 位常量域里算: 占用与深度都零扩展后再相减, 免得把 integer 型的
    // SPACE_MIN 参数硬塞进 AW+1 位的 localparam 而产生截断。
    wire [31:0] depth32 = {{(32-PW){1'b0}}, DEPTH_EXT};
    wire [31:0] occ32   = {{(32-PW){1'b0}}, occ_w};

    assign wr_space    = ((depth32 - occ32) >= SPACE_MIN);
    wire               wr_fire = wr_en && !wr_full;

    reg [9:0] mem [0:DEPTH-1];
    always @(posedge wr_clk) begin
        if (wr_fire)
            mem[wr_bin[AW-1:0]] <= wr_data;
    end

    always @(posedge wr_clk) begin
        if (wr_rst) begin
            wr_bin  <= {(AW + 1){1'b0}};
            wr_ovf  <= 1'b0;
        end
        else begin
            wr_ovf  <= wr_en && wr_full;
            if (wr_fire)
                wr_bin <= wr_bin + {{AW{1'b0}}, 1'b1};
        end
    end

    // ---------------- 读域 ----------------
    reg  [AW:0] rd_bin;
    assign rd_gray = f_bin2gray(rd_bin);

    reg  [AW:0] wr_gray_r1;
    reg  [AW:0] wr_gray_r2;
    always @(posedge rd_clk) begin
        if (rd_rst) begin
            wr_gray_r1 <= {(AW + 1){1'b0}};
            wr_gray_r2 <= {(AW + 1){1'b0}};
        end
        else begin
            wr_gray_r1 <= wr_gray;
            wr_gray_r2 <= wr_gray_r1;
        end
    end

    wire [AW:0] wr_bin_r = f_gray2bin(wr_gray_r2);
    wire [AW:0] used_ext = wr_bin_r - rd_bin;
    assign rd_usedw = used_ext;
    // v6d: 空标志改在**灰码域**比较(与 wr_full 同一手法, 已在 v5 签核过)。
    // 灰码是双射 => 灰码相等 <=> 二进制相等, 判据一字不差; wr_gray_r2 是 2FF 的第二级,
    // 已同步, 不是裸写指针。原来的写法把 10 级行波异或解码坐在 125MHz 的 rd_bin 使能
    // 路径上(v6c 实测 -0.028ns / 2 端点)。解码只留给 rd_usedw 读数, 那条路在 app 域。
    assign rd_empty = (rd_gray == wr_gray_r2);
    wire            rd_fire       = rd_en && !rd_empty;   // 本拍真的从内存取到一个字
    wire            slot_consume  = rd_en && rd_vld;      // 本拍把槽里未消费的字处理掉

    reg [9:0] rd_data_r;
    always @(posedge rd_clk) begin
        if (rd_rst) begin
            rd_bin    <= {(AW + 1){1'b0}};
            // rd_data_r 故意**不在**复位清单里: 带复位的读出口寄存器是 TD 不肯把 mem
            // 推进 BRAM9K 的唯一原因(§6.4 探针第 4/5 轮实测: 只删掉这一行即
            // SYN-1027 DRAM → SYN-1026 BRAM, 其余写法一字不改; 灰码满空、一槽交接、
            // 水位解码都保留)。块 RAM 的读出口没有同步复位, 所以这行留着就只能是 LUT-RAM。
            // 安全性: rd_data 只有在 rd_vld=1 时才允许被消费, 而 rd_vld 仍在本清单里复位,
            // 复位/冲刷之后到第一次取到字之前 rd_vld 恒 0 ⇒ 陈旧字节不可能被当成数据
            // (三个消费者 ethm_tx_drain / ethm_rx_pack 的呈现与消费条件全部含 rd_vld)。
            rd_vld    <= 1'b0;
        end
        else begin
            // 槽位交接记账: 取到新字 => 槽里有一个未消费的字; 本拍消费掉且没补上 => 空
            rd_vld <= rd_fire ? 1'b1 : (rd_vld && !slot_consume);
            if (rd_fire) begin
                rd_bin    <= rd_bin + {{AW{1'b0}}, 1'b1};
                rd_data_r <= mem[rd_bin[AW-1:0]];
            end
        end
    end

    assign rd_data = rd_data_r;
    assign rd_kind = rd_data_r[9:8];
    assign rd_last = (rd_data_r[9:8] == 2'b01);
endmodule
