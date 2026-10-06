`timescale 1ns/1ps
// ============================================================================
// fat32_volume_scanner — FAT32 卷扫描/资源槽定位 (task_026 scan-fix 版)
//
// 板上实证背景(2026-09-19, 详见 doc/run/run_report.md §7):
//   旧版只读根目录起始扇区的首 512 字节(16 项), 且要求属性字节恰为 0x20、
//   四个 PIC 槽齐全才认 mount 成功。真卡上 System Volume Information 的
//   LFN 项/卷标项/删除残留会把 PIC1..PIC4 的目录项挤出首扇区(落到扇区 2+),
//   或属性字节非纯 0x20, 导致文件齐全仍报 ERR_RESOURCE_MISSING(0x22,
//   顶层 LED 码 4)。本版在不改端口/不改对外握手协议的前提下修复。
//
// scan-fix 行为(对旧版的全部差异, 其余逐行保持):
//   1) 根目录跨扇区遍历: 自 root_lba(根簇首扇区)起逐扇区逐项扫描, 上限
//      16 扇区(FAT32 根簇典型 4KB 簇=8 扇区, 16 为任务规定的裕量上限);
//   2) 目录项首字节/属性分类处理, 一律不报错、不终止判定:
//        0x00      项跳过继续(保守允许提前结束——实现为"整扇区全 0 才提前
//                  结束", 以便容忍项间 0x00 洞之后仍有有效项的异常排布);
//        0xE5      删除残留, 跳过;
//        0x0F      LFN 长名项, 跳过(属性掩码天然排除);
//        0x08      卷标项, 跳过(属性掩码天然排除);
//        0x10      目录项, 跳过(属性掩码天然排除);
//   3) PIC/BMP 匹配条件放宽为 "名字精确匹配 && (attr & 8'h18)==0"
//      (排除卷标/目录位; 0x20/0x21/0x26/0x27 等常规文件属性均接受);
//      [032续轮2] **WAV 槽同规则对齐 PIC**：旧语义要求 attr 恰为 0x20，会造成
//      真实卡上**静默失效**——只读(0x21)、隐藏/系统(0x26/0x27)、或部分写入工具
//      留下的 0x00 都会让 WAVn 根本不进槽，长按换歌变成无任何提示、无任何错误码
//      的空操作，板上无从分辨"没实现"与"没识别"。LFN(0x0F)/卷标(0x08)/目录(0x10)
//      仍被 0x18 掩码排除，与 PIC 完全一致。
//   4) mount 成功条件放宽: 扫描结束后 resource_valid != 4'h0(至少一个
//      PIC 槽有效)即 fs_error=0; 全空才报 ERR_RESOURCE_MISSING(0x22)。
//      resource_valid/resourceN_cluster/resourceN_size 位图语义照旧输出。
//      WAV 任何情况都不影响 mount(旧版已如此, 保持)。
//   5) 提前结束条件(两者取先): 整扇区全 0(目录尾)或扫满 16 扇区。
//      去掉旧版"扫满一扇区即判"与"凑齐 4 槽提前退"两个短路径——后者会
//      丢失位于更后扇区的 WAV 槽信息。
//
// 已知边界(登记于 run_report, 本版不处理):
//   * 短名被系统改写(如 PIC1~1.BMP)仍匹配不到——固定名契约, 需 LFN 解析,
//     属后续任务;   * 根簇链只扫首簇连续 16 扇区, 不走 FAT 链;
//   * 扇区上限 16: >16 扇区才出现的项(如 32KB 簇的超大根目录尾)扫不到。
// ============================================================================

module fat32_volume_scanner (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        scan_start,
    output wire        scan_busy,
    output reg         scan_done,
    output reg  [7:0]  fs_error,
    output reg  [31:0] partition_lba,
    output reg  [7:0]  sectors_per_cluster,
    output reg  [31:0] fat_start_lba,
    output reg  [31:0] data_start_lba,
    output reg  [31:0] max_cluster,
    output reg  [3:0]  resource_valid,
    output reg  [31:0] resource0_cluster,
    output reg  [31:0] resource1_cluster,
    output reg  [31:0] resource2_cluster,
    output reg  [31:0] resource3_cluster,
    output reg  [31:0] resource0_size,
    output reg  [31:0] resource1_size,
    output reg  [31:0] resource2_size,
    output reg  [31:0] resource3_size,
    // WAV slots (ADOPT v3 4.5 extension, purely additive): WAV1.WAV~WAV4.WAV.
    // This task does NOT consume them (audio-integration reservation); the
    // mount criterion (ERR_RESOURCE_MISSING) still looks ONLY at
    // resource_valid (PIC slots) -- a missing WAV slot never fails mount.
    output reg  [3:0]  wav_valid,
    output reg  [31:0] wav0_first_cluster,
    output reg  [31:0] wav1_first_cluster,
    output reg  [31:0] wav2_first_cluster,
    output reg  [31:0] wav3_first_cluster,
    output reg  [31:0] wav0_size,
    output reg  [31:0] wav1_size,
    output reg  [31:0] wav2_size,
    output reg  [31:0] wav3_size,
    output reg         lrc_entry_valid,
    output wire [1:0]  lrc_entry_slot,
    output wire [31:0] lrc_entry_cluster,
    output wire [31:0] lrc_entry_size,
    output reg         sector_req,
    output reg  [31:0] sector_lba,
    input  wire        sector_busy,
    input  wire        sector_valid,
    input  wire [7:0]  sector_byte,
    input  wire [8:0]  sector_byte_index,
    input  wire        sector_done,
    input  wire [7:0]  sector_error
);

    localparam ERR_NONE            = 8'h00;
    localparam ERR_SECTOR          = 8'h10;
    localparam ERR_BOOT_SIGNATURE  = 8'h20;
    localparam ERR_UNSUPPORTED_BPB = 8'h21;
    localparam ERR_RESOURCE_MISSING= 8'h22;

    // scan-fix: 根目录扫描扇区窗口上限(自 root_lba 起)
    localparam ROOT_SCAN_SECTORS = 5'd16;

    localparam ST_IDLE       = 4'd0;
    localparam ST_READ0_REQ  = 4'd1;
    localparam ST_READ0_WAIT = 4'd2;
    localparam ST_BOOT_PARSE = 4'd3;
    localparam ST_BOOT_REQ   = 4'd4;
    localparam ST_BOOT_WAIT  = 4'd5;
    localparam ST_ROOT_REQ   = 4'd6;
    localparam ST_ROOT_WAIT  = 4'd7;
    localparam ST_DIR_SCAN   = 4'd8;
    localparam ST_FINISH     = 4'd9;
    localparam ST_BOOT_LAYOUT= 4'd10;
    localparam ST_BOOT_ROOT  = 4'd11;

    reg [3:0] state;
    reg [7:0] sector_buffer [0:511];
    reg [4:0] directory_entry_index;
    reg [4:0] root_sector_cnt;      // scan-fix: 根目录扫描扇区偏移 0..15
    reg       sector_all_zero;      // scan-fix: 当前扇区是否全 0(目录尾判据)
    reg [31:0] root_cluster;
    reg [31:0] total_sectors;
    reg [31:0] fat_sectors;
    reg [7:0] fat_count;
    reg [15:0] reserved_sectors;
    reg [31:0] root_lba;
    reg [31:0] data_sector_count;
    reg [31:0] fat_span;
    reg [2:0] sectors_per_cluster_shift;
    reg [7:0] dir_name0;
    reg [7:0] dir_name1;
    reg [7:0] dir_name2;
    reg [7:0] dir_name3;
    reg [7:0] dir_name4;
    reg [7:0] dir_name5;
    reg [7:0] dir_name6;
    reg [7:0] dir_name7;
    reg [7:0] dir_name8;
    reg [7:0] dir_name9;
    reg [7:0] dir_name10;
    reg       dir_entry_match;
    reg [1:0] dir_resource_index;
    reg lrc_entry_match;
    reg [1:0] lrc_index;
    reg       wav_entry_match;      // WAV slots (4.5 extension)
    reg [1:0] wav_resource_index;
    reg [15:0] dir_cluster_high;
    reg [15:0] dir_cluster_low;
    reg [31:0] dir_file_size;

    // 目录项属性判据：仅按 0x18 掩码排除卷标/目录/LFN 位（PIC 与 WAV 同规则）
    wire attr_is_plain = ((sector_byte & 8'h18) == 8'h00);

    assign scan_busy = (state != ST_IDLE);

    function [15:0] le16;
        input integer offset;
        begin
            le16 = {sector_buffer[offset+1], sector_buffer[offset]};
        end
    endfunction

    function [31:0] le32;
        input integer offset;
        begin
            le32 = {sector_buffer[offset+3], sector_buffer[offset+2],
                    sector_buffer[offset+1], sector_buffer[offset]};
        end
    endfunction

    function valid_spc;
        input [7:0] value;
        begin
            valid_spc = value != 0 && ((value & (value - 1'b1)) == 0);
        end
    endfunction

    function [2:0] spc_shift;
        input [7:0] value;
        begin
            case (value)
                8'd2:   spc_shift = 3'd1;
                8'd4:   spc_shift = 3'd2;
                8'd8:   spc_shift = 3'd3;
                8'd16:  spc_shift = 3'd4;
                8'd32:  spc_shift = 3'd5;
                8'd64:  spc_shift = 3'd6;
                8'd128: spc_shift = 3'd7;
                default: spc_shift = 3'd0;
            endcase
        end
    endfunction

    task finish_with_error;
        input [7:0] code;
        begin
            fs_error <= code;
            state <= ST_FINISH;
        end
    endtask

    assign lrc_entry_slot=lrc_index;
    assign lrc_entry_cluster={dir_cluster_high,dir_cluster_low};
    assign lrc_entry_size=dir_file_size;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lrc_entry_valid<=1'b0;lrc_index<=2'd0;
            state <= ST_IDLE;
            scan_done <= 1'b0;
            fs_error <= ERR_NONE;
            partition_lba <= 32'd0;
            sectors_per_cluster <= 8'd0;
            fat_start_lba <= 32'd0;
            data_start_lba <= 32'd0;
            max_cluster <= 32'd0;
            resource_valid <= 4'd0;
            resource0_cluster <= 32'd0;
            resource1_cluster <= 32'd0;
            resource2_cluster <= 32'd0;
            resource3_cluster <= 32'd0;
            resource0_size <= 32'd0;
            resource1_size <= 32'd0;
            resource2_size <= 32'd0;
            resource3_size <= 32'd0;
            wav_valid <= 4'd0;
            wav0_first_cluster <= 32'd0;
            wav1_first_cluster <= 32'd0;
            wav2_first_cluster <= 32'd0;
            wav3_first_cluster <= 32'd0;
            wav0_size <= 32'd0;
            wav1_size <= 32'd0;
            wav2_size <= 32'd0;
            wav3_size <= 32'd0;
            sector_req <= 1'b0;
            sector_lba <= 32'd0;
            directory_entry_index <= 5'd0;
            root_sector_cnt <= 5'd0;
            sector_all_zero <= 1'b1;
            root_cluster <= 32'd0;
            total_sectors <= 32'd0;
            fat_sectors <= 32'd0;
            fat_count <= 8'd0;
            reserved_sectors <= 16'd0;
            root_lba <= 32'd0;
            data_sector_count <= 32'd0;
            fat_span <= 32'd0;
            sectors_per_cluster_shift <= 3'd0;
            dir_name0 <= 8'd0;
            dir_name1 <= 8'd0;
            dir_name2 <= 8'd0;
            dir_name3 <= 8'd0;
            dir_name4 <= 8'd0;
            dir_name5 <= 8'd0;
            dir_name6 <= 8'd0;
            dir_name7 <= 8'd0;
            dir_name8 <= 8'd0;
            dir_name9 <= 8'd0;
            dir_name10 <= 8'd0;
            dir_entry_match <= 1'b0;
            dir_resource_index <= 2'd3;
            wav_entry_match <= 1'b0;
            lrc_entry_match <= 1'b0;
            wav_resource_index <= 2'd3;
            dir_cluster_high <= 16'd0;
            dir_cluster_low <= 16'd0;
            dir_file_size <= 32'd0;
        end else begin
            lrc_entry_valid<=1'b0;
            scan_done <= 1'b0;
            sector_req <= 1'b0;
            if (sector_valid && state != ST_ROOT_WAIT)
                sector_buffer[sector_byte_index] <= sector_byte;

            // ----------------------------------------------------------
            // 根目录扇区流式目录项匹配(scan-fix): 逐字节, 32B/项。
            // 首字节 0x00/0xE5 与 LFN/卷标/目录项不满足下述名字+属性条件,
            // 自然跳过且不报错; 属性条件排除卷标(0x08)/目录(0x10)/LFN(0x0F)。
            // ----------------------------------------------------------
            if (sector_valid && state == ST_ROOT_WAIT) begin
                // 全 0 扇区跟踪: 发扇区请求时置 1, 任一非 0 字节清 0
                // (不按项边界重置——"整扇区全 0"才是目录尾判据)
                if (sector_byte != 8'd00)
                    sector_all_zero <= 1'b0;

                case (sector_byte_index[4:0])
                    5'd0: begin
                        dir_name0 <= sector_byte;
                        dir_entry_match <= 1'b0;
                        wav_entry_match <= 1'b0;
                        lrc_entry_match <= 1'b0;
                    end
                    5'd1:  dir_name1 <= sector_byte;
                    5'd2:  dir_name2 <= sector_byte;
                    5'd3:  dir_name3 <= sector_byte;
                    5'd4:  dir_name4 <= sector_byte;
                    5'd5:  dir_name5 <= sector_byte;
                    5'd6:  dir_name6 <= sector_byte;
                    5'd7:  dir_name7 <= sector_byte;
                    5'd8:  dir_name8 <= sector_byte;
                    5'd9:  dir_name9 <= sector_byte;
                    5'd10: dir_name10 <= sector_byte;
                    5'd11: begin
                        // scan-fix: PIC 放宽为 (attr & 0x18)==0(排除卷标/
                        // 目录/LFN 位, 档案位与隐藏/系统/只读位不再强制);
                        // WAV 与 PIC 同规则(见文件头 §3): 只按 0x18 掩码排除
                        // 卷标/目录/LFN, 其余属性位一律接受。
                        if (attr_is_plain &&
                            dir_name0 == "P" && dir_name1 == "I" &&
                            dir_name2 == "C" && dir_name3 >= "1" &&
                            dir_name3 <= "4" && dir_name4 == " " &&
                            dir_name5 == " " && dir_name6 == " " &&
                            dir_name7 == " " && dir_name8 == "B" &&
                            dir_name9 == "M" && dir_name10 == "P") begin
                            dir_entry_match <= 1'b1;
                            dir_resource_index <= dir_name3 - "1";
                        end
                        if (attr_is_plain &&
                            dir_name0 == "W" && dir_name1 == "A" &&
                            dir_name2 == "V" && dir_name3 >= "1" &&
                            dir_name3 <= "4" && dir_name4 == " " &&
                            dir_name5 == " " && dir_name6 == " " &&
                            dir_name7 == " " && dir_name8 == "W" &&
                            dir_name9 == "A" && dir_name10 == "V") begin
                            wav_entry_match <= 1'b1;
                            wav_resource_index <= dir_name3 - "1";
                        end
                        if(attr_is_plain && dir_name0=="W" && dir_name1=="A" && dir_name2=="V" &&
                           dir_name3>="1" && dir_name3<="4" && dir_name4==" " && dir_name5==" " && dir_name6==" " && dir_name7==" " &&
                           dir_name8=="L" && dir_name9=="R" && dir_name10=="C")begin
                            lrc_entry_match<=1'b1;lrc_index<=dir_name3[1:0]-2'd1;
                        end
                    end
                    5'd20: dir_cluster_high[7:0] <= sector_byte;
                    5'd21: dir_cluster_high[15:8] <= sector_byte;
                    5'd26: dir_cluster_low[7:0] <= sector_byte;
                    5'd27: dir_cluster_low[15:8] <= sector_byte;
                    5'd28: dir_file_size[7:0] <= sector_byte;
                    5'd29: dir_file_size[15:8] <= sector_byte;
                    5'd30: dir_file_size[23:16] <= sector_byte;
                    5'd31: begin
                        dir_file_size[31:24] <= sector_byte;
                        if(lrc_entry_match)lrc_entry_valid<=1'b1;
                        if (wav_entry_match) begin
                            case (wav_resource_index)
                                2'd0: begin
                                    wav0_first_cluster <= {dir_cluster_high, dir_cluster_low};
                                    wav0_size <= {sector_byte, dir_file_size[23:0]};
                                    wav_valid[0] <= 1'b1;
                                end
                                2'd1: begin
                                    wav1_first_cluster <= {dir_cluster_high, dir_cluster_low};
                                    wav1_size <= {sector_byte, dir_file_size[23:0]};
                                    wav_valid[1] <= 1'b1;
                                end
                                2'd2: begin
                                    wav2_first_cluster <= {dir_cluster_high, dir_cluster_low};
                                    wav2_size <= {sector_byte, dir_file_size[23:0]};
                                    wav_valid[2] <= 1'b1;
                                end
                                default: begin
                                    wav3_first_cluster <= {dir_cluster_high, dir_cluster_low};
                                    wav3_size <= {sector_byte, dir_file_size[23:0]};
                                    wav_valid[3] <= 1'b1;
                                end
                            endcase
                        end
                        if (dir_entry_match) begin
                            case (dir_resource_index)
                                2'd0: begin
                                    resource0_cluster <= {dir_cluster_high, dir_cluster_low};
                                    resource0_size <= {sector_byte, dir_file_size[23:0]};
                                    resource_valid[0] <= 1'b1;
                                end
                                2'd1: begin
                                    resource1_cluster <= {dir_cluster_high, dir_cluster_low};
                                    resource1_size <= {sector_byte, dir_file_size[23:0]};
                                    resource_valid[1] <= 1'b1;
                                end
                                2'd2: begin
                                    resource2_cluster <= {dir_cluster_high, dir_cluster_low};
                                    resource2_size <= {sector_byte, dir_file_size[23:0]};
                                    resource_valid[2] <= 1'b1;
                                end
                                default: begin
                                    resource3_cluster <= {dir_cluster_high, dir_cluster_low};
                                    resource3_size <= {sector_byte, dir_file_size[23:0]};
                                    resource_valid[3] <= 1'b1;
                                end
                            endcase
                        end
                    end
                    default: begin end
                endcase
            end

            case (state)
                ST_IDLE: if (scan_start) begin
                    fs_error <= ERR_NONE;
                    partition_lba <= 32'd0;
                    resource_valid <= 4'd0;
                    wav_valid <= 4'd0;
                    state <= ST_READ0_REQ;
                end
                ST_READ0_REQ: if (!sector_busy) begin
                    sector_lba <= 32'd0;
                    sector_req <= 1'b1;
                    state <= ST_READ0_WAIT;
                end
                ST_READ0_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else if (sector_buffer[510] != 8'h55 || sector_buffer[511] != 8'haa)
                        finish_with_error(ERR_BOOT_SIGNATURE);
                    else if (sector_buffer[0] == 8'heb || sector_buffer[0] == 8'he9) begin
                        partition_lba <= 32'd0;
                        state <= ST_BOOT_PARSE;
                    end else if (sector_buffer[450] == 8'h0b || sector_buffer[450] == 8'h0c) begin
                        partition_lba <= le32(454);
                        sector_lba <= le32(454);
                        state <= ST_BOOT_REQ;
                    end else begin
                        finish_with_error(ERR_UNSUPPORTED_BPB);
                    end
                end
                ST_BOOT_REQ: if (!sector_busy) begin
                    sector_req <= 1'b1;
                    state <= ST_BOOT_WAIT;
                end
                ST_BOOT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else if (sector_buffer[510] != 8'h55 || sector_buffer[511] != 8'haa)
                        finish_with_error(ERR_BOOT_SIGNATURE);
                    else
                        state <= ST_BOOT_PARSE;
                end
                ST_BOOT_PARSE: begin
                    if (le16(11) != 16'd512 || !valid_spc(sector_buffer[13]) ||
                        le16(14) == 0 || (sector_buffer[16] != 1 && sector_buffer[16] != 2) ||
                        le16(17) != 0 || le16(22) != 0 || le32(32) == 0 ||
                        le32(36) == 0 || le32(44) < 2) begin
                        finish_with_error(ERR_UNSUPPORTED_BPB);
                    end else begin
                        sectors_per_cluster <= sector_buffer[13];
                        reserved_sectors <= le16(14);
                        fat_count <= sector_buffer[16];
                        total_sectors <= le32(32);
                        fat_sectors <= le32(36);
                        root_cluster <= le32(44);
                        sectors_per_cluster_shift <= spc_shift(sector_buffer[13]);
                        fat_span <= sector_buffer[16] == 2 ? (le32(36) << 1) : le32(36);
                        fat_start_lba <= partition_lba + le16(14);
                        state <= ST_BOOT_LAYOUT;
                    end
                end
                ST_BOOT_LAYOUT: begin
                    data_start_lba <= partition_lba + reserved_sectors + fat_span;
                    data_sector_count <= total_sectors - reserved_sectors - fat_span;
                    state <= ST_BOOT_ROOT;
                end
                ST_BOOT_ROOT: begin
                    max_cluster <= (data_sector_count >> sectors_per_cluster_shift) + 1'b1;
                    root_lba <= data_start_lba
                                + ((root_cluster - 2) << sectors_per_cluster_shift);
                    sector_lba <= data_start_lba
                                  + ((root_cluster - 2) << sectors_per_cluster_shift);
                    root_sector_cnt <= 5'd0;        // scan-fix
                    resource_valid <= 4'd0;
                    wav_valid <= 4'd0;
                    state <= ST_ROOT_REQ;
                end
                // scan-fix: 每扇区一发; 首扇区前清槽(仅一次, 防止跨扇区丢已命中槽)
                ST_ROOT_REQ: if (!sector_busy) begin
                    if (root_sector_cnt == 5'd0) begin
                        resource_valid <= 4'd0;
                        wav_valid <= 4'd0;
                    end
                    dir_entry_match <= 1'b0;
                    wav_entry_match <= 1'b0;
                    sector_all_zero <= 1'b1;    // 本扇区全 0 判据复位
                    sector_lba <= root_lba + {27'd0, root_sector_cnt};
                    sector_req <= 1'b1;
                    state <= ST_ROOT_WAIT;
                end
                ST_ROOT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else begin
                        directory_entry_index <= 5'd0;
                        state <= ST_DIR_SCAN;
                    end
                end
                // scan-fix: 每扇区判一次——整扇区全 0(目录尾, 保守提前结束,
                // 不报错)或扫满 16 扇区则收口; 收口判据 = 至少一个 PIC 槽。
                ST_DIR_SCAN: begin
                    if (sector_all_zero || root_sector_cnt == ROOT_SCAN_SECTORS - 5'd1) begin
                        if (resource_valid != 4'h0)
                            state <= ST_FINISH;
                        else
                            finish_with_error(ERR_RESOURCE_MISSING);
                    end else begin
                        root_sector_cnt <= root_sector_cnt + 5'd1;
                        state <= ST_ROOT_REQ;
                    end
                end
                ST_FINISH: begin
                    scan_done <= 1'b1;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
