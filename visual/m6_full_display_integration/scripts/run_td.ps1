param([Parameter(Mandatory=$true)][ValidatePattern('^[a-zA-Z0-9_]+$')][string]$Tag,[ValidateSet('synth','route')][string]$Mode='synth')
$ErrorActionPreference='Stop'
$fdiTask=Split-Path -Parent $PSScriptRoot
$fdiOutput=Join-Path "$fdiTask" "td_run/$Tag"
$fdiStage=Join-Path ([IO.Path]::GetTempPath()) "fdi_${Tag}_$([DateTime]::Now.ToString('yyyyMMdd_HHmmss'))"
if(Test-Path -LiteralPath "$fdiOutput"){throw "Refuse overwrite: $fdiOutput"}
New-Item -ItemType Directory -Path "$fdiOutput","$fdiStage" | Out-Null
Copy-Item -LiteralPath "$fdiTask/project/src" -Destination "$fdiStage/src" -Recurse
Copy-Item -LiteralPath "$fdiTask/project/assets/rom_row_span.hex" -Destination "$fdiStage/rom_row_span.hex"
Copy-Item -LiteralPath "$fdiTask/project/src/vendor/fdi_stream/fdi_row_span_rom.vh" -Destination "$fdiStage/fdi_row_span_rom.vh"
& node "$PSScriptRoot/prepare_td.cjs" "$fdiStage" "$fdiOutput" "$Mode"
if($LASTEXITCODE -ne 0){throw 'Source preparation failed'}
Copy-Item -LiteralPath "$fdiOutput/run.tcl","$fdiOutput/SOURCE_MANIFEST.json" -Destination "$fdiStage"
$fdiTclArgument=$fdiStage.Replace('\','/')+'/run.tcl'
$fdiProcess=Start-Process -FilePath "D:/AnLu/bin/td_commands_prompt.exe" -ArgumentList @($fdiTclArgument) -WorkingDirectory "$fdiStage" -WindowStyle Hidden -PassThru -RedirectStandardOutput "$fdiStage/console.log" -RedirectStandardError "$fdiStage/stderr.log"
Write-Output "FDI TD running PID=$($fdiProcess.Id) STAGE=$fdiStage"
$fdiProcess.WaitForExit()
Get-ChildItem -LiteralPath "$fdiStage" -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination "$fdiOutput" }
Copy-Item -LiteralPath "$fdiStage/src" -Destination "$fdiOutput/src" -Recurse
& node "$PSScriptRoot/read_td.cjs" "$fdiOutput" "$Mode"
if($LASTEXITCODE -ne 0){throw 'TD gate failed; retained raw evidence, no bit generated'}
