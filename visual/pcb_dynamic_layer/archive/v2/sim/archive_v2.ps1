# V2 完整保留；只在校验副本之后移除本轮出列的活动文件。
$ErrorActionPreference = "Stop"
$taskRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$archiveRoot = [IO.Path]::GetFullPath((Join-Path $taskRoot "archive/v2"))
$taskPrefix = $taskRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
function Checked-TaskPath([string]$relative) {
    $resolved = [IO.Path]::GetFullPath((Join-Path $taskRoot $relative))
    if (-not $resolved.StartsWith($taskPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "目标超出任务目录：$resolved"
    }
    return $resolved
}
if (Test-Path -LiteralPath $archiveRoot) { throw "归档已存在，拒绝覆盖：$archiveRoot" }
$null = New-Item -ItemType Directory -Path $archiveRoot
foreach ($name in @("rtl", "tb", "reference", "doc", "sim", "td_run")) {
    $source = Checked-TaskPath $name
    $destination = Checked-TaskPath "archive/v2/$name"
    Copy-Item -LiteralPath $source -Destination $destination -Recurse
}
$manifest = [ordered]@{}
foreach ($name in @("rtl", "tb", "reference", "doc", "sim", "td_run")) {
    foreach ($source in Get-ChildItem -LiteralPath (Checked-TaskPath $name) -File -Recurse) {
        $relative = [IO.Path]::GetRelativePath($taskRoot, $source.FullName)
        $copy = Checked-TaskPath (Join-Path "archive/v2" $relative)
        $beforeHash = (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash
        $copyHash = (Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash
        if ($beforeHash -ne $copyHash) { throw "归档校验失败：$relative" }
        $manifest[$relative.Replace("\", "/")] = $copyHash.ToLowerInvariant()
    }
}
@{ archived_at = (Get-Date).ToString("o"); files = $manifest } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Checked-TaskPath "archive/v2/archive_manifest.json") -Encoding utf8
$retired = @(
    "rtl/pcb_particle_overlay.v", "rtl/pcb_span_ram.v", "rtl/pcb_dynamic_roms.vh", "rtl/pcb_dynamic_roms_v2.vh",
    "tb/tb_w1.cpp", "reference/gen_overlay_vectors.cjs",
    "reference/_smoke_overlay2", "reference/_smoke_overlay3", "reference/_smoke_vectors2", "reference/_smoke_vectors3",
    "sim/run_w1.sh", "sim/collect_w1_results.py", "sim/gen_w1_tb_vectors.cjs",
    "sim/w1_result_v2.json", "sim/w1_compile_manifest_v2.json", "sim/vectors/v2/w1",
    "sim/archive_v2_result.cjs", "sim/archive_gate_result.cjs", "sim/audit_startup.cjs",
    "sim/startup_audit", "sim/startup_audit_rev1", "sim/vectors/w2",
    "td_run/v2", "td_run/w1_v2.tcl", "td_run/w1_v2.sdc", "td_run/w1_v2.log",
    "td_run/w1_v2_gate.area", "td_run/w1_v2_gate.qor", "td_run/w1_v2_gate.timing", "td_run/w1_v2_paths.timing"
)
foreach ($relative in $retired) {
    $target = Checked-TaskPath $relative
    if (Test-Path -LiteralPath $target) {
        $copy = Checked-TaskPath (Join-Path "archive/v2" $relative)
        if (-not (Test-Path -LiteralPath $copy)) { throw "归档缺失，不能出列：$relative" }
        # 实际解析路径已确认位于 taskRoot 内，且完整复制和哈希校验已完成。
        Remove-Item -LiteralPath $target -Recurse -Force
    }
}
Write-Output "V2 归档已校验：$($manifest.Count) 个文件；W1 活动实现/用例已出列。"
