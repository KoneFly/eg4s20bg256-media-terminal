$ErrorActionPreference = 'Stop'
$fdiHelpers = Split-Path -Parent $PSScriptRoot
foreach ($f in Get-ChildItem -LiteralPath "$fdiHelpers" -File -Filter '*.v') {
 $s = [IO.File]::ReadAllText($f.FullName)
 switch ($f.Name) {
 'fdi_sdram_cmd_engine.v' {
  $s=$s.Replace('BL_MINUS_1 = BURST_LEN - 1',"BL_MINUS_1 = BURST_LEN[3:0] - 4'd1")
  foreach($n in @('T_INIT','T_RP','T_RFC','T_MRD','T_RCD','T_WR')) {
   $s=$s.Replace("cnt == $n-1","cnt == $n[14:0]-15'd1")
  }
  $s=$s.Replace('cnt == CAS_LAT-3+DQ_LAT',"cnt == CAS_LAT[14:0]-15'd3+DQ_LAT[14:0]")
  $s=[regex]::Replace($s,'(?m)^\s*wire \[10:0\] op_row = op_addr\[18:8\];\s*\r?\n','')
 }
 'fdi_sdram_refresh_timer.v' {
  $s=$s.Replace('cnt >= REF_INTERVAL_CYCLES - 1',"cnt >= REF_INTERVAL_CYCLES[12:0] - 13'd1")
 }
 'fdi_sd_spi_byte_engine.v' {
  $s=$s.Replace('half_cnt == half_period_m1',"half_cnt == {1'b0, half_period_m1}")
 }
 'fdi_sd_cmd_transactor.v' {
  $s=$s.Replace("{div_latched, 4'd0} + 5'd15","{1'b0, div_latched, 4'd0} + {{BYTE_DIV_WIDTH{1'b0}}, 5'd15}")
  $s=$s.Replace('wire                       byte_busy;',"/* verilator lint_off UNUSEDSIGNAL */`n    wire                       byte_busy;")
  $s=$s.Replace('wire                       byte_done;',"/* verilator lint_on UNUSEDSIGNAL */`n    wire                       byte_done;")
 }
 'fdi_fat32_file_streamer.v' {
  $s=[regex]::Replace($s,'(?m)^\s*(reg \[31:0\] next_cluster;|next_cluster <=.*;)\s*\r?\n','')
  $s=$s.Replace('reg [7:0] fat_byte0, fat_byte1, fat_byte2, fat_byte3;',"reg [7:0] fat_byte0, fat_byte1, fat_byte2;`n    reg [3:0] fat_byte3;")
  $s=$s.Replace("fat_byte3 <= 8'd0;","fat_byte3 <= 4'd0;").Replace('fat_byte3 <= sector_byte;','fat_byte3 <= sector_byte[3:0];')
  $s=$s.Replace("fat_entry_offset + 2'd2","fat_entry_offset + 9'd2").Replace("fat_entry_offset + 2'd3","fat_entry_offset + 9'd3")
  $s=$s.Replace('chain_count >= MAX_VISITED_CLUSTERS','chain_count >= MAX_VISITED_CLUSTERS[CHAIN_COUNT_WIDTH-1:0]')
 }
 'fdi_mx_byte_engine.v' {
  $s=$s.Replace('reg [1:0] state;',"localparam [DIV_BITS-1:0] DIV_LIMIT = CLK_DIV[DIV_BITS-1:0]-1'b1;`n    reg [1:0] state;")
  $s=$s.Replace('div_count == CLK_DIV-1','div_count == DIV_LIMIT').Replace('reg [7:0] rx_shift;','reg [6:0] rx_shift;')
  $s=$s.Replace("rx_shift  <= 8'h00;","rx_shift  <= 7'h00;").Replace("rx_shift <= {rx_shift[6:0], miso};","rx_shift <= {rx_shift[5:0], miso};")
 }
 }
 [IO.File]::WriteAllText($f.FullName,$s.TrimEnd()+"`n",[Text.UTF8Encoding]::new($false))
}
