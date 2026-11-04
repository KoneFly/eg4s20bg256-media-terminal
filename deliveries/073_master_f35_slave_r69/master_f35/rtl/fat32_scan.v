`timescale 1ns / 1ps
// ============================================================================
// fat32_scan — FAT32 挂载 + 根目录按 8.3 名查找 + 簇链预走生成 extent 表
//
// 流程: LBA0(MBR 或 superfloppy BPB) -> BPB -> 根目录簇链逐扇区扫描 ->
//   找到文件 -> 按文件长度所需簇数走 FAT 链, 物理连续的簇合并为一个 extent。
// 读卡: 每次 1 块(st_count=1)。块池字读出后寄存, 再逐字节串行解析(每字 4 拍):
//   一条 8 位比较通路 + 32 位小端移位拼字寄存器, 在字段最后一个字节处锁存。
//   挂载与查找只在切换文件时发生, 串行解析每块约 900 拍, 远小于读卡本身。
//   FAT 扇区按字复制到本地 128 字缓存, 顺序文件每 128 簇只需读一次 FAT。
// 簇 -> 扇区换算只用一个共享移位器; 文件剩余量按字节计(每簇减簇字节数),
//   不做除法/右移求簇数。
// 输出: ext_* 读口(1 拍延迟) 给出 {lba, blocks}, 按文件偏移顺序; n_ext 项。
// extent 表分两个 bank(start 时由 bank 选写入哪个), 读口地址最高位选 bank:
//   图片与音乐两个文件可以同时打开、交替读取。
// 错误码 err_code: 1 无签名 2 非 FAT32/不支持的几何 3 未找到 4 簇链异常
//   5 extent 超限 6 文件为空/过大。
// 支持范围: 512B 扇区, 每簇 1..128 扇区(2 的幂), MBR 第一分区 0x0B/0x0C 或
//   无分区表; 不支持 LFN 名查找(只比 8.3 短名), 不进子目录。
// ============================================================================
module fat32_scan #(
    parameter integer EXT_AW = 7         // extent 表 2^EXT_AW 项
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    input  wire [87:0] name83,           // 11 字节, name83[87:80] 为第一个字符
    input  wire        bank,             // 本次查找结果写入的 extent bank
    output reg         busy,
    output reg         done,
    output reg  [2:0]  err_code,         // 0 = 成功
    output reg  [31:0] file_size,
    output reg  [EXT_AW:0] n_ext,

    input  wire [EXT_AW:0] ext_raddr,    // {bank, 序号}
    output reg  [31:0] ext_lba,
    output reg  [31:0] ext_blocks,

    // sd_host 读端口
    input  wire        init_done,
    output reg         st_start,
    output reg  [31:0] st_lba,
    output wire [15:0] st_count,
    input  wire        st_done,
    input  wire        st_err,
    input  wire [3:0]  pool_count,
    output reg  [6:0]  pool_raddr,
    input  wire [31:0] pool_rdata,
    output reg         pool_release
);
    assign st_count = 16'd1;

    localparam [2:0] E_SIG = 3'd1, E_FS = 3'd2, E_NF = 3'd3, E_CHAIN = 3'd4, E_EXT = 3'd5, E_SIZE = 3'd6;
    localparam [1:0] B_BOOT = 2'd0, B_BPB = 2'd1, B_DIR = 2'd2, B_FAT = 2'd3;

    localparam [3:0]
        S_IDLE = 4'd0, S_REQ = 4'd1, S_WAITB = 4'd2, S_STREAM = 4'd3, S_WAITD = 4'd4,
        S_POST = 4'd5, S_DIRNEXT = 4'd6, S_NEXTCL = 4'd7, S_LOOK = 4'd8, S_LOOK2 = 4'd9,
        S_WALK = 4'd10, S_EXTW = 4'd11, S_FIN = 4'd12, S_FAIL = 4'd13, S_LOOK3 = 4'd14;

    reg [3:0]  st;
    reg [1:0]  btype;
    reg        got_done, got_err;   // 读命令结束可能早于块被取完, 先锁存
    reg [31:0] cur_lba;

    // ---- 几何 ----
    reg [31:0] part_lba, fat_lba, data_lba;
    reg [2:0]  spc_sh;                   // log2(每簇扇区)
    reg [7:0]  spc;

    // ---- 块字段(按块类型解释) ----
    reg [15:0] f_sig, f_bps, f_rsvd;
    reg [7:0]  f_jmp, f_spc, f_nfats, f_ptype;
    reg [31:0] f_fatsz, f_root, f_plba;

    // 目录项
    reg        e_match;
    reg [7:0]  e_b0, e_attr;
    reg [15:0] e_chi, e_clo;
    reg        dir_found, dir_end;
    reg [31:0] found_clus, found_size;

    // ---- 串行读块: 发读 -> 2 拍块池延迟 -> 寄存字 -> 4 拍逐字节 ----
    reg [7:0]  ridx;                     // 下一个要读的字号(128 = 读完)
    reg [6:0]  widx;                     // 当前解析字号
    reg [2:0]  ph;                       // 0 发读 1/2 等待 3 取字 4..7 字节 0..3
    reg [31:0] wq;                       // 当前字(逐字节右移)
    reg [31:0] sr;                       // 小端拼字: 新字节进最高位
    wire [7:0] bt   = wq[7:0];
    wire [31:0] srn = {bt, sr[31:8]};
    wire [8:0] off  = {widx, ph[1:0]};   // 当前字节在块内的偏移
    wire       byte_ph = ph[2];

    // FAT 扇区缓存
    reg [31:0] fcache [0:127];
    reg [31:0] fc_sec;
    reg        fc_valid;
    reg [6:0]  fc_raddr;
    reg [31:0] fc_rdata;
    always @(posedge clk) begin
        if (st == S_STREAM && ph == 3'd3 && btype == B_FAT) fcache[widx] <= pool_rdata;
        fc_rdata <= fcache[fc_raddr];
    end

    // extent 表
    reg [63:0] etab [0:(2<<EXT_AW)-1];
    reg        et_we, wbank;
    reg [EXT_AW:0] et_wa;
    reg [63:0] et_wd;
    always @(posedge clk) begin
        if (et_we) etab[et_wa] <= et_wd;
        {ext_lba, ext_blocks} <= etab[ext_raddr];
    end

    // ---- 簇链走查 ----
    reg [31:0] dir_clus;                 // 当前目录簇
    reg [7:0]  dir_sec;                  // 簇内扇区序号
    reg [31:0] cur_clus, ext_start, ext_secs, bytes_left, next_clus;
    reg        look_dir;                 // 查 FAT 是为了目录(1)还是文件(0)

    // 共享簇号 -> 扇区换算(S_NEXTCL 用当前簇, S_EXTW 用 extent 首簇)
    wire [31:0] cl_in   = (st == S_NEXTCL) ? cur_clus : ext_start;
    wire [31:0] cl_lba  = data_lba + ((cl_in - 32'd2) << spc_sh);
    wire [16:0] cbytes  = {spc, 9'd0};
    wire        last_cl = (bytes_left <= {15'd0, cbytes});
    wire [31:0] fat_sec_of_cur = fat_lba + {7'd0, cur_clus[31:7]};

    // 8.3 名逐字节比较: 目录项内偏移 j(0..10) 对应 name83[87-8j -: 8]
    wire [3:0] eo4 = off[3:0];
    reg  [7:0] nb;
    always @(*) begin
        case (eo4)
        4'd0: nb = name83[87:80]; 4'd1: nb = name83[79:72]; 4'd2: nb = name83[71:64];
        4'd3: nb = name83[63:56]; 4'd4: nb = name83[55:48]; 4'd5: nb = name83[47:40];
        4'd6: nb = name83[39:32]; 4'd7: nb = name83[31:24]; 4'd8: nb = name83[23:16];
        4'd9: nb = name83[15:8];  default: nb = name83[7:0];
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; btype <= B_BOOT; cur_lba <= 32'd0; got_done <= 1'b0; got_err <= 1'b0;
            busy <= 1'b0; done <= 1'b0; err_code <= 3'd0; file_size <= 32'd0; n_ext <= 0;
            st_start <= 1'b0; st_lba <= 32'd0; pool_raddr <= 7'd0; pool_release <= 1'b0;
            part_lba <= 0; fat_lba <= 0; data_lba <= 0; spc_sh <= 0; spc <= 8'd1;
            f_sig <= 0; f_bps <= 0; f_rsvd <= 0; f_jmp <= 0; f_spc <= 0; f_nfats <= 0; f_ptype <= 0;
            f_fatsz <= 0; f_root <= 0; f_plba <= 0;
            e_match <= 1'b0; e_b0 <= 0; e_attr <= 0; e_chi <= 0; e_clo <= 0;
            dir_found <= 1'b0; dir_end <= 1'b0; found_clus <= 0; found_size <= 0;
            ridx <= 0; widx <= 0; ph <= 0; wq <= 0; sr <= 0;
            fc_sec <= 0; fc_valid <= 1'b0; fc_raddr <= 0;
            et_we <= 1'b0; et_wa <= 0; et_wd <= 0; wbank <= 1'b0;
            dir_clus <= 0; dir_sec <= 0; cur_clus <= 0; ext_start <= 0; ext_secs <= 0;
            bytes_left <= 0; next_clus <= 0; look_dir <= 1'b0;
        end else begin
            st_start <= 1'b0; pool_release <= 1'b0; done <= 1'b0; et_we <= 1'b0;
            if (st_done) begin got_done <= 1'b1; got_err <= st_err; end

            case (st)
            S_IDLE: if (start) begin
                busy <= 1'b1; err_code <= 3'd0; n_ext <= 0; fc_valid <= 1'b0; wbank <= bank;
                btype <= B_BOOT; cur_lba <= 32'd0; part_lba <= 32'd0;
                st <= init_done ? S_REQ : S_IDLE;
                if (!init_done) busy <= 1'b0;
            end
            S_REQ: begin
                st_start <= 1'b1; st_lba <= cur_lba; ridx <= 0; ph <= 3'd0; got_done <= 1'b0; got_err <= 1'b0;
                dir_found <= 1'b0; dir_end <= 1'b0;
                st <= S_WAITB;
            end
            S_WAITB: begin
                if (pool_count != 0) st <= S_STREAM;
                else if (got_done) st <= S_REQ;            // 未得到块(读错): 重试
            end
            S_STREAM: begin
                case (ph)
                3'd0: if (ridx == 8'd128) begin pool_release <= 1'b1; st <= S_WAITD; end
                      else begin pool_raddr <= ridx[6:0]; widx <= ridx[6:0]; ridx <= ridx + 8'd1; ph <= 3'd1; end
                3'd1, 3'd2: ph <= ph + 3'd1;
                3'd3: begin wq <= pool_rdata; ph <= 3'd4; end
                default: begin
                    // 逐字节解析(ph 4..7 对应字内字节 0..3)
                    wq <= {8'd0, wq[31:8]};
                    sr <= srn;
                    ph <= (ph == 3'd7) ? 3'd0 : ph + 3'd1;
                    if (btype == B_BOOT || btype == B_BPB) begin
                        case (off)
                        9'd0:   f_jmp   <= bt;
                        9'd12:  f_bps   <= srn[31:16];
                        9'd13:  f_spc   <= bt;
                        9'd15:  f_rsvd  <= srn[31:16];
                        9'd16:  f_nfats <= bt;
                        9'd39:  f_fatsz <= srn;
                        9'd47:  f_root  <= srn;
                        9'd450: f_ptype <= bt;
                        9'd457: f_plba  <= srn;
                        9'd511: f_sig   <= srn[31:16];
                        default: ;
                        endcase
                    end
                    // 目录项(32 字节): 0..10 名, 11 属性, 20..21 簇高, 26..27 簇低, 28..31 长度
                    if (btype == B_DIR && !dir_found && !dir_end) begin
                        if (off[4:0] <= 5'd10) e_match <= ((off[4:0] == 5'd0) || e_match) && (bt == nb);
                        if (off[4:0] == 5'd0)  e_b0   <= bt;
                        if (off[4:0] == 5'd11) e_attr <= bt;
                        if (off[4:0] == 5'd21) e_chi  <= srn[31:16];
                        if (off[4:0] == 5'd27) e_clo  <= srn[31:16];
                        if (off[4:0] == 5'd31) begin
                            if (e_b0 == 8'h00) dir_end <= 1'b1;
                            else if (e_match && e_b0 != 8'hE5 && e_attr != 8'h0F && (e_attr & 8'h18) == 8'h00) begin
                                dir_found  <= 1'b1;
                                found_clus <= {4'd0, e_chi[11:0], e_clo};
                                found_size <= srn;
                            end
                        end
                    end
                end
                endcase
            end
            // 块已取完, 等本次读命令完全结束
            S_WAITD: if (got_done || st_done) st <= S_POST;
            S_POST: begin
                case (btype)
                B_BOOT: begin
                    if (f_sig != 16'hAA55) begin err_code <= E_SIG; st <= S_FAIL; end
                    else if ((f_jmp == 8'hEB || f_jmp == 8'hE9) && f_bps == 16'd512 && f_fatsz != 0) begin
                        part_lba <= 32'd0; st <= S_DIRNEXT; btype <= B_BPB;   // superfloppy: 本块即 BPB
                    end else if (f_ptype == 8'h0B || f_ptype == 8'h0C) begin
                        part_lba <= f_plba; cur_lba <= f_plba; btype <= B_BPB; st <= S_REQ;
                    end else begin err_code <= E_FS; st <= S_FAIL; end
                end
                B_BPB: st <= S_DIRNEXT;
                B_DIR: begin
                    if (dir_found) begin
                        if (found_size == 0 || found_clus < 2) begin err_code <= E_SIZE; st <= S_FAIL; end
                        else begin
                            file_size <= found_size;
                            cur_clus  <= found_clus; ext_start <= found_clus; ext_secs <= {24'd0, spc};
                            bytes_left <= found_size;
                            st <= S_WALK;
                        end
                    end else if (dir_end) begin err_code <= E_NF; st <= S_FAIL; end
                    else begin
                        dir_sec <= dir_sec + 8'd1;
                        if (dir_sec + 8'd1 == spc) begin
                            cur_clus <= dir_clus; look_dir <= 1'b1; st <= S_LOOK;
                        end else begin
                            cur_lba <= cur_lba + 32'd1; st <= S_REQ;
                        end
                    end
                end
                B_FAT: begin
                    fc_valid <= 1'b1; fc_sec <= cur_lba; st <= S_LOOK;
                end
                endcase
            end
            // 解析 BPB(首次)并开始扫根目录首簇
            S_DIRNEXT: begin
                if (f_sig != 16'hAA55 || f_bps != 16'd512 || f_fatsz == 0 || f_nfats == 0 || f_nfats > 2 ||
                    !(f_spc == 1 || f_spc == 2 || f_spc == 4 || f_spc == 8 || f_spc == 16 ||
                      f_spc == 32 || f_spc == 64 || f_spc == 128)) begin
                    err_code <= E_FS; st <= S_FAIL;
                end else begin
                    spc    <= f_spc;
                    spc_sh <= {f_spc[7] | f_spc[6] | f_spc[5] | f_spc[4],
                               f_spc[7] | f_spc[6] | f_spc[3] | f_spc[2],
                               f_spc[7] | f_spc[5] | f_spc[3] | f_spc[1]};
                    fat_lba  <= part_lba + f_rsvd;
                    data_lba <= part_lba + f_rsvd + ((f_nfats == 2) ? (f_fatsz << 1) : f_fatsz);
                    dir_clus <= f_root; cur_clus <= f_root;
                    btype <= B_DIR;
                    st <= S_NEXTCL;
                end
            end
            // 定位当前目录簇首扇区
            S_NEXTCL: begin
                dir_sec <= 8'd0;
                cur_lba <= cl_lba;
                btype   <= B_DIR;
                st      <= S_REQ;
            end
            // 查 FAT[cur_clus]
            S_LOOK: begin
                if (fc_valid && fc_sec == fat_sec_of_cur) begin
                    fc_raddr <= cur_clus[6:0]; st <= S_LOOK2;
                end else begin
                    cur_lba <= fat_sec_of_cur; btype <= B_FAT; st <= S_REQ;
                end
            end
            S_LOOK2: st <= S_LOOK3;
            S_LOOK3: begin
                next_clus <= {4'd0, fc_rdata[27:0]};
                if (look_dir) begin
                    look_dir <= 1'b0;
                    if (fc_rdata[27:0] >= 28'h0FFFFF8) begin err_code <= E_NF; st <= S_FAIL; end
                    else if (fc_rdata[27:0] < 28'd2 || fc_rdata[27:0] >= 28'h0FFFFF0) begin err_code <= E_CHAIN; st <= S_FAIL; end
                    else begin dir_clus <= {4'd0, fc_rdata[27:0]}; cur_clus <= {4'd0, fc_rdata[27:0]}; st <= S_NEXTCL; end
                end else begin
                    if (fc_rdata[27:0] < 28'd2 || fc_rdata[27:0] >= 28'h0FFFFF0) begin err_code <= E_CHAIN; st <= S_FAIL; end
                    else if ({4'd0, fc_rdata[27:0]} == cur_clus + 32'd1) begin
                        ext_secs <= ext_secs + {24'd0, spc}; cur_clus <= cur_clus + 32'd1;
                        bytes_left <= bytes_left - {15'd0, cbytes}; st <= S_WALK;
                    end else begin
                        // 写出当前 extent, 新 extent 从 next 开始
                        st <= S_EXTW;
                    end
                end
            end
            S_WALK: begin
                if (last_cl) st <= S_EXTW;
                else st <= S_LOOK;
            end
            S_EXTW: begin
                if (n_ext == (1 << EXT_AW)) begin err_code <= E_EXT; st <= S_FAIL; end
                else begin
                    et_we <= 1'b1; et_wa <= {wbank, n_ext[EXT_AW-1:0]};
                    et_wd <= {cl_lba, ext_secs};
                    n_ext <= n_ext + 1'b1;
                    if (last_cl) st <= S_FIN;
                    else begin
                        ext_start <= next_clus; ext_secs <= {24'd0, spc}; cur_clus <= next_clus;
                        bytes_left <= bytes_left - {15'd0, cbytes}; st <= S_WALK;
                    end
                end
            end
            S_FIN:  begin busy <= 1'b0; done <= 1'b1; st <= S_IDLE; end
            S_FAIL: begin busy <= 1'b0; done <= 1'b1; st <= S_IDLE; end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule
