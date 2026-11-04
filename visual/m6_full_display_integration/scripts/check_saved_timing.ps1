param([Parameter(Mandatory=$true)][string]$Stage,[Parameter(Mandatory=$true)][string]$Output)
$ErrorActionPreference='Stop'
if(!(Test-Path -LiteralPath "$Stage/gate.db")){throw 'Frozen gate.db missing'}
$fdiRoot=$Stage.Replace('\','/')
$fdiCheck=@"
import_db $fdiRoot/gate.db
clear_user_sdc
read_sdc $fdiRoot/src/constraints/eth_m6_master.sdc
update_timing
report_timing_status -file $fdiRoot/checked.ts
report_timing_summary -ep_num 40 -file $fdiRoot/checked.timing
report_timing_ignored -ep_num 2000 -file $fdiRoot/checked_ignored.timing
report_qor -step gate -file $fdiRoot/checked.qor
puts FDI_TIMING_CHECK_COMPLETE
exit
"@
[IO.File]::WriteAllText("$Stage/check_timing.tcl",$fdiCheck,[Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath "$Stage/check_timing.tcl" -Destination "$Output/check_timing.tcl"
$fdiProcess=Start-Process -FilePath "D:/AnLu/bin/td_commands_prompt.exe" -ArgumentList @("$fdiRoot/check_timing.tcl") -WorkingDirectory "$Stage" -WindowStyle Hidden -PassThru -RedirectStandardOutput "$Stage/checked_console.log" -RedirectStandardError "$Stage/checked_stderr.log"
Write-Output "Read-only saved-netlist timing check PID=$($fdiProcess.Id)"
$fdiProcess.WaitForExit()
Get-ChildItem -LiteralPath "$Stage" -File | Where-Object Name -Like 'checked*' | ForEach-Object {Copy-Item -LiteralPath $_.FullName -Destination "$Output"}
