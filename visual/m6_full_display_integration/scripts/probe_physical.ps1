param([Parameter(Mandatory=$true)][ValidatePattern('^[a-zA-Z0-9_]+$')][string]$Tag,[Parameter(Mandatory=$true)][string]$InputRun,[ValidateSet('place','route')][string]$Mode='place')
$ErrorActionPreference='Stop'
$fdiTask=Split-Path -Parent $PSScriptRoot
$fdiOutput=Join-Path "$fdiTask" "td_run/$Tag"
$fdiStage=Join-Path ([IO.Path]::GetTempPath()) "fdi_${Tag}_$([DateTime]::Now.ToString('yyyyMMdd_HHmmss'))"
$fdiInputDb=Join-Path "$InputRun" $(if($Mode -eq 'place'){'gate.db'}else{'place.db'})
if(Test-Path -LiteralPath "$fdiOutput"){throw "Refuse overwrite: $fdiOutput"}
if(!(Test-Path -LiteralPath "$fdiInputDb")){throw 'Prior frozen database missing'}
New-Item -ItemType Directory -Path "$fdiOutput","$fdiStage" | Out-Null
Copy-Item -LiteralPath "$fdiTask/project/src" -Destination "$fdiStage/src" -Recurse
Copy-Item -LiteralPath "$fdiInputDb" -Destination "$fdiStage/input.db"
& node "$PSScriptRoot/prepare_physical.cjs" "$fdiStage" "$fdiOutput" "$InputRun" "$Mode"
if($LASTEXITCODE -ne 0){throw 'Frozen source or prior resource gate failed'}
Copy-Item -LiteralPath "$fdiOutput/run.tcl","$fdiOutput/SOURCE_MANIFEST.json" -Destination "$fdiStage"
$fdiTclArgument=$fdiStage.Replace('\','/')+'/run.tcl'
$fdiProcess=Start-Process -FilePath "D:/AnLu/bin/td_commands_prompt.exe" -ArgumentList @($fdiTclArgument) -WorkingDirectory "$fdiStage" -WindowStyle Hidden -PassThru -RedirectStandardOutput "$fdiStage/console.log" -RedirectStandardError "$fdiStage/stderr.log"
Write-Output "Fixed RTL physical probe PID=$($fdiProcess.Id) STAGE=$fdiStage MODE=$Mode"
$fdiProcess.WaitForExit()
Get-ChildItem -LiteralPath "$fdiStage" -File | ForEach-Object {Copy-Item -LiteralPath $_.FullName -Destination "$fdiOutput"}
Copy-Item -LiteralPath "$fdiStage/src" -Destination "$fdiOutput/src" -Recurse
& node "$PSScriptRoot/read_td.cjs" "$fdiOutput" "$Mode"
if($LASTEXITCODE -ne 0){Write-Output 'Physical result HOLD; raw evidence retained, no bit generated'}
