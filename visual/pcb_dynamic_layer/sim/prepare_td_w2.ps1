param([Parameter(Mandatory = $true)][ValidatePattern("^[a-zA-Z0-9_]+$")][string]$Revision)
$ErrorActionPreference = "Stop"
$taskRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$target = [IO.Path]::GetFullPath((Join-Path $taskRoot "td_run/w2_mc/$Revision"))
$allowed = [IO.Path]::GetFullPath((Join-Path $taskRoot "td_run/w2_mc")) + [IO.Path]::DirectorySeparatorChar
if (-not $target.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw "TD 目标超出任务目录" }
if (Test-Path -LiteralPath $target) { throw "TD 归档已存在，拒绝覆盖：$Revision" }
$null = New-Item -ItemType Directory -Path $target
foreach ($name in @("pcb_frame_updater.v", "pcb_ram_2k16.v", "pcb_dynamic_roms_w2.vh")) {
    Copy-Item -LiteralPath (Join-Path $taskRoot "rtl/$name") -Destination (Join-Path $target $name)
}
Copy-Item -LiteralPath (Join-Path $taskRoot "archive/v2/td_run/v2/w2/clock.sdc") -Destination (Join-Path $target "clock.sdc")
$tdScript = @'
import_device eagle_s20.db -package EG4S20BG256
set_param flow qor_monitor on
read_hdl -file {pcb_frame_updater.v pcb_ram_2k16.v} -top pcb_frame_updater
optimize_rtl
report_area -file rtl.area
read_sdc clock.sdc
optimize_gate
update_timing
report_area -io_info -file area.txt
report_timing_summary -file timing.txt
report_qor -step gate -file resource.qor
puts "W2_MC_TD_COMPLETE"
exit
'@
[IO.File]::WriteAllText((Join-Path $target "run.tcl"), $tdScript + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
$hashes = [ordered]@{}
foreach ($name in @("pcb_frame_updater.v", "pcb_ram_2k16.v", "pcb_dynamic_roms_w2.vh", "clock.sdc", "run.tcl")) {
    $hashes[$name] = (Get-FileHash -LiteralPath (Join-Path $target $name) -Algorithm SHA256).Hash.ToLowerInvariant()
}
$hashes | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $target "input_manifest.json") -Encoding utf8
Write-Output "TD 输入已冻结：$Revision；沿用 V2 原始 clock.sdc。"
