<#
  Read back the first 128 MiB of the TF card for verification (M6-FDI 6B810152).
  MUST run in an ELEVATED PowerShell (Run as administrator).

  List disks first:
      & "<this file>" -List
  Then read back:
      & "<this file>" -DiskNumber 2
#>
param(
    [int]$DiskNumber = -1,
    [switch]$List,
    [string]$Out = "D:\readback.img"
)

$N = 134217728   # 128 MiB

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: NOT elevated. Close this window and open PowerShell as administrator (Win+X -> Terminal (Admin))." -ForegroundColor Red
    exit 1
}
Write-Host "Admin: OK" -ForegroundColor Green

if ($List -or $DiskNumber -lt 0) {
    Write-Host "==== Physical disks (find your TF card reader by size/model) ====" -ForegroundColor Cyan
    Get-Disk | Select-Object Number, FriendlyName, @{n='SizeGB';e={[math]::Round($_.Size/1GB,2)}}, BusType | Format-Table -AutoSize
    Write-Host "Re-run with:  -DiskNumber <number>" -ForegroundColor Yellow
    exit 0
}

$path = "\\.\PhysicalDrive$DiskNumber"
Write-Host "Reading first $N bytes from $path ..." -ForegroundColor Cyan

$fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
$buf = New-Object byte[] $N
$got = 0
while ($got -lt $N) {
    $r = $fs.Read($buf, $got, $N - $got)
    if ($r -le 0) { break }
    $got += $r
}
$fs.Close()

if ($got -ne $N) { Write-Host "ERROR: short read $got / $N" -ForegroundColor Red; exit 1 }

[IO.File]::WriteAllBytes($Out, $buf)
$sha = (Get-FileHash -Algorithm SHA256 -Path $Out).Hash.ToLower()
Write-Host "OK: wrote $Out ($got bytes)" -ForegroundColor Green
Write-Host "SHA256 = $sha"
Write-Host "NOTE: expected whole-image hash is db41b9c5... only if no 'System Volume Information' was added;"
Write-Host "      the label region and PCM region are what matter. Send the SHA above back for verification."
