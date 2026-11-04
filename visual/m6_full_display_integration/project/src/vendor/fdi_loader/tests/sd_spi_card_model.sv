`timescale 1ns/1ps
// ============================================================================
// sd_spi_card_model — SPI 级 SD 假卡模型 (task_022 新写, M02/M03 级替身)
//
// 与 009 的接口级替身(sd_block_reader_model)不同, 本模型挂在真实 SPI 引脚上,
// 按 SCK 边沿逐位服务(不绑定任何上层任务的内端口), 因此能验证 M02/M03 的
// 真实命令序列/CS 帧界/SCK 频率, 而不是接口级旁路。
//
// SPI Mode 0 时序(CPOL=0/CPHA=0, 与 001 sd_spi_byte_engine 配对):
//   * 主机在 SCK 下降沿更新 MOSI; 模型在 SCK 上升沿采样 MOSI(逐位移位);
//   * 模型在 SCK 下降沿更新 MISO, 主机在上升沿采样;
//   * CS=1 时 MISO 恒 1(空闲), 收发状态在 CS 下降沿重同步(逐命令帧界)。
//
// 应答语义(VERIFICATION_CONTRACT M02 要求):
//   CMD0  -> R1=0x01
//   CMD8  -> R1=0x01 + 尾随 4B(00 00 01 AA)(主机继续给时钟才续发;
//            003 只读 R1 首字节后释放 CS, 尾字作废 — 契约"不流失"语义)
//   CMD55 -> R1=0x01(并置 app_cmd 标志)
//   ACMD41(前趋 CMD55) -> 前 cfg_acmd41_idle 次回 R1=0x01(空闲, 轮询),
//            之后回 R1=0x00 + OCR 4B(0xC0FF8000, CCS=1)
//   CMD17 -> R1=0x00 + cfg_data_filler 个 0xFF + 0xFE + 512B 扇区数据
//            + CRC16(CCITT, 初值 0, 表格法 — 与 004 位递推结构不同,
//            上电自检 check("123456789")==0x31C3 标准向量)
//   其他  -> R1=0x05(idle+illegal)
//   数据阶段(0xFE 起的 517 字节时钟内)忽略 MOSI 输入(真卡语义:
//   主机在此期间发的是 0xFF 哑元, 不得被收进命令缓冲)。
//
// 错误注入(TB 层级写配置寄存器, 单次/定点消费):
//   cfg_dead       = 1: 永不应答(MISO 恒 1) → 主机 Ncr 超时 (M08a)
//   cfg_crc_bad_lba: 对该 LBA 的 CMD17 数据 CRC16 取反 → 004 crc_error (M08e)
//   cfg_framing_mute: 不用 — 帧错误自动计数 framing_err 供 TB 检查
//
// 观测(TB 层级引用, 供黄金比对):
//   tr_cmd[i]/tr_arg[i]/tr_time[i]/tr_cnt : 命令 trace(帧完成拍记录)
//   csf_time[i]/csf_cnt, csr_time[i]/csr_cnt : CS 沿记录(交接毛刺检查)
//   framing_err : 非法命令帧字节(byte0[7:6]!=01)计数
//   data_tok_cnt: 已完成的 CMD17 数据流个数
// ============================================================================
module sd_spi_card_model #(
    parameter IMG_SECTORS  = 4096,
    parameter TRACE_DEPTH  = 16384,
    parameter CS_TRACE     = 512
)(
    input  wire spi_cs_n,
    input  wire spi_sck,
    input  wire spi_mosi,
    output wire spi_miso
);

    // ------------------------------------------------------------------
    // 整盘镜像(大端字; 字节 j = img[j/4] >> (8*(3 - j%4)))
    // ------------------------------------------------------------------
    reg [31:0] img [0:IMG_SECTORS*128-1];
    initial $readmemh("label_image.memh", img);

    // ------------------------------------------------------------------
    // 配置(TB 层级写入)
    // ------------------------------------------------------------------
    reg        cfg_dead        = 1'b0;
    integer    cfg_acmd41_idle = 2;
    integer    cfg_data_filler = 2;
    reg [31:0] cfg_crc_bad_lba = 32'hFFFF_FFFF;

    // ------------------------------------------------------------------
    // 观测记录
    // ------------------------------------------------------------------
    reg  [5:0]  tr_cmd   [0:TRACE_DEPTH-1];
    reg  [31:0] tr_arg   [0:TRACE_DEPTH-1];
    integer     tr_time  [0:TRACE_DEPTH-1];
    integer     tr_cnt   = 0;
    integer     csf_time [0:CS_TRACE-1];
    integer     csf_cnt  = 0;
    integer     csr_cnt  = 0;
    integer     framing_err = 0;
    integer     data_tok_cnt = 0;

    // ------------------------------------------------------------------
    // CRC16-CCITT(表格法, 与 RTL 位递推结构不同; 上电对标准向量自检)
    // ------------------------------------------------------------------
    reg [15:0] crc_tab [0:255];
    integer ci, cb;
    reg [15:0] cch;
    reg [3:0]  cbit;
    initial begin
        for (ci = 0; ci < 256; ci = ci + 1) begin
            cch = ci[15:0] << 8;
            for (cbit = 0; cbit < 8; cbit = cbit + 1)
                cch = cch[15] ? ((cch << 1) ^ 16'h1021) : (cch << 1);
            crc_tab[ci] = cch;
        end
        // LESSON-001: 对标外部权威向量(CRC-16/XMODEM check value)
        cch = crc16_stream(72'h31_32_33_34_35_36_37_38_39, 9); // "123456789"
        if (cch !== 16'h31C3)
            $display("CARDMODEL-INTERNAL-ERROR: crc16 self-check %h != 31C3", cch);
    end

    function [15:0] crc16_byte_upd;
        input [15:0] crc;
        input [7:0]  d;
        begin
            crc16_byte_upd = (crc << 8) ^ crc_tab[((crc >> 8) ^ d) & 8'hFF];
        end
    endfunction

    function [15:0] crc16_stream;
        input [8*9-1:0] str;   // 9 字节测试向量(iverilog 字符串传参兼容性)
        input integer  len;
        integer k;
        reg [15:0] c;
        begin
            c = 16'h0000;
            for (k = 0; k < len; k = k + 1)
                c = crc16_byte_upd(c, str[(len-k)*8-1 -: 8]);
            crc16_stream = c;
        end
    endfunction

    // ------------------------------------------------------------------
    // 应答队列(CMD17 最长 = R1 + filler + 令牌 + 512 + CRC16; 容量取 640
    // 覆盖 filler=120, 修复原 520 容量在 filler>4 时溢出丢 CRC 的模型缺陷)
    // ------------------------------------------------------------------
    reg  [7:0] q_mem [0:639];
    integer    q_head = 0, q_tail = 0, q_cnt = 0;

    task q_push;
        input [7:0] b;
        begin
            if (q_cnt < 640) begin
                q_mem[q_tail] = b;
                q_tail = (q_tail + 1) % 640;
                q_cnt  = q_cnt + 1;
            end
        end
    endtask

    task q_push_sector_crc;   // 计算 LBA 扇区 CRC16(可注入坏 CRC)并入队
        input [31:0] lba;
        reg [15:0] crc;
        integer k;
        reg [7:0] b;
        begin
            crc = 16'h0000;
            for (k = 0; k < 512; k = k + 1) begin
                b = img[lba*128 + k/4] >> (8*(3 - (k % 4)));
                crc = crc16_byte_upd(crc, b);
            end
            if (lba == cfg_crc_bad_lba)
                crc = ~crc;
            q_push(crc[15:8]);
            q_push(crc[7:0]);
        end
    endtask

    // ------------------------------------------------------------------
    // 命令接收与数据阶段状态
    // ------------------------------------------------------------------
    reg [7:0]  sh_reg = 8'hFF;
    reg [2:0]  bit_cnt = 0;
    reg [2:0]  byte_cnt = 0;
    reg [7:0]  cbuf [0:5];
    reg        in_data = 1'b0;       // CMD17 数据阶段(忽略 MOSI)
    reg        app_cmd = 1'b0;       // CMD55 前趋标志
    integer    acmd_polls = 0;

    // MISO 输出寄存(tx_bit 从 7 数到 0)
    reg [7:0] tx_byte = 8'hFF;
    reg [2:0] tx_bit  = 3'd7;

    // MOSI 采样 + 命令分发(SCK 上升沿)
    always @(posedge spi_sck) begin
        if (!spi_cs_n && !cfg_dead && !in_data) begin
            sh_reg  = {sh_reg[6:0], spi_mosi};
            if (bit_cnt == 3'd7) begin
                bit_cnt = 3'd0;
                if (byte_cnt == 3'd5) begin
                    // 第6字节 = CRC(不进缓冲); 命令字节0在 cbuf[0]
                    byte_cnt = 3'd0;
                    handle_cmd(cbuf[0]);
                end else begin
                    cbuf[byte_cnt] = sh_reg; // 阻塞采样适配后sh_reg已包含本拍位，不能再移一次
                    byte_cnt = byte_cnt + 3'd1;
                end
            end else begin
                bit_cnt = bit_cnt + 3'd1;
            end
        end
    end

    task handle_cmd;
        input [7:0] b0;
        reg [5:0]  cidx;
        reg [31:0] arg;
        begin
            cidx = b0[5:0];
            if (b0[7:6] !== 2'b01) begin
                framing_err = framing_err + 1;
            end
            arg = {cbuf[1], cbuf[2], cbuf[3], cbuf[4]};
            // trace 记录(帧完成拍): 仅记数据读命令 CMD17/18 ——
            // TB 的 check_load_was 语义 = "read_start 快照后的第一条 trace 即首数据块",
            // 若把 CMD0/9/16/55 等也记入, 快照索引会被非读命令越过导致 wait 永假(032 实测死锁)。
            if ((cidx == 6'd17 || cidx == 6'd18) && tr_cnt < TRACE_DEPTH) begin
                tr_cmd[tr_cnt]  = cidx;
                tr_arg[tr_cnt]  = arg;
                tr_time[tr_cnt] = $time;
            end
            if (cidx == 6'd17 || cidx == 6'd18)
                tr_cnt = tr_cnt + 1;
            // 命令分发
            case (cidx)
                6'd0: begin                       // CMD0 GO_IDLE
                    app_cmd   = 1'b0;
                    q_push(8'h01);
                end
                6'd8: begin                       // CMD8 SEND_IF_COND
                    app_cmd = 1'b0;
                    q_push(8'h01);
                    q_push(8'h00); q_push(8'h00); q_push(8'h01); q_push(8'hAA);
                end
                6'd55: begin                      // CMD55 APP_CMD
                    app_cmd = 1'b1;
                    q_push(8'h01);
                end
                6'd41: begin                      // ACMD41(需 CMD55 前趋)
                    if (app_cmd) begin
                        app_cmd = 1'b0;
                        if (acmd_polls < cfg_acmd41_idle) begin
                            acmd_polls = acmd_polls + 1;
                            q_push(8'h01);        // 仍空闲, 继续轮询
                        end else begin
                            q_push(8'h00);        // 就绪
                            q_push(8'hC0); q_push(8'hFF);   // OCR, CCS=1
                            q_push(8'h80); q_push(8'h00);
                        end
                    end else begin
                        q_push(8'h05);            // 无前趋: illegal
                    end
                end
                6'd17: begin                      // CMD17 READ_SINGLE_BLOCK
                    app_cmd = 1'b0;
                    q_push(8'h00);                // R1=0x00
                    in_data = 1'b1;               // 进入数据阶段(忽略 MOSI)
                    data_tok_cnt = data_tok_cnt + 1;
                    begin : fill_data
                        integer i;
                        reg [7:0] db;
                        for (i = 0; i < cfg_data_filler; i = i + 1)
                            q_push(8'hFF);
                        q_push(8'hFE);            // 起始令牌
                        for (i = 0; i < 512; i = i + 1) begin
                            db = img[arg*128 + i/4] >> (8*(3 - (i % 4)));
                            q_push(db);
                        end
                    end
                    q_push_sector_crc(arg);
                end
                default: q_push(8'h05);           // 未识别命令
            endcase
        end
    endtask

    // MISO 逐位输出 + 数据阶段字节计数(SCK 下降沿)
    always @(negedge spi_sck) begin
        if (!spi_cs_n) begin
            if (tx_bit == 3'd0) begin
                if (q_cnt > 0) begin
                    tx_byte = q_mem[q_head];
                    q_head  = (q_head + 1) % 640;
                    q_cnt   = q_cnt - 1;
                end else begin
                    tx_byte = 8'hFF;
                    if (in_data) begin
                        in_data = 1'b0;       // 数据流消费完毕, 回命令态
                    end
                end
                tx_bit = 3'd7;
            end else begin
                tx_bit = tx_bit - 3'd1;
            end
        end
    end

    assign spi_miso = spi_cs_n ? 1'b1 :
                      cfg_dead ? 1'b1 : tx_byte[tx_bit];

    // CS 沿处理: 下降沿重同步收发; 上升沿清队列/退出数据态(真卡中止语义)
    reg cs_active_seen = 1'b0;   // 复位期 CS 的 X→1 不是真实会话, 不计数
    always @(negedge spi_cs_n) begin
        cs_active_seen = 1'b1;
        sh_reg   = 8'hFF;
        bit_cnt  = 3'd0;
        byte_cnt = 3'd0;
        tx_byte  = 8'hFF;
        tx_bit   = 3'd7;
        in_data  = 1'b0;
        q_head   = 0;
        q_tail   = 0;
        q_cnt    = 0;
        if (csf_cnt < CS_TRACE) begin
            csf_time[csf_cnt] = $time;
            csf_cnt = csf_cnt + 1;
        end
    end
    always @(posedge spi_cs_n) begin
        q_head  = 0;
        q_tail  = 0;
        q_cnt   = 0;
        in_data = 1'b0;
        if (cs_active_seen)
            csr_cnt = csr_cnt + 1;
    end

endmodule
