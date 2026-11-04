param([Parameter(Mandatory=$true)][ValidatePattern('^[a-zA-Z0-9_]+$')][string]$Tag,[ValidateSet('synth','check','pcheck','place','route','hold','prehold','bit')][string]$Mode='synth',[string]$InputTag,[ValidateSet('buffer','clock','miso','miso_clock')][string]$HoldStrategy='buffer',[ValidateSet('normal','high')][string]$RouteEffort='normal',[int]$PlaceSeed=0,[ValidateSet('normal','incremental','repair')][string]$RouteStrategy='normal',[ValidateSet('auto','1')][string]$FlowThreads='auto')
$ErrorActionPreference='Stop'
$fdiTask=Split-Path -Parent $PSScriptRoot
$fdiOutput=Join-Path "$fdiTask" "td_run/$Tag"
$fdiStage=Join-Path ([IO.Path]::GetTempPath()) "fdi_${Tag}_$([DateTime]::Now.ToString('yyyyMMdd_HHmmss'))"
if(Test-Path -LiteralPath "$fdiOutput"){throw "Refuse overwrite: $fdiOutput"}
New-Item -ItemType Directory -Path "$fdiOutput","$fdiStage" | Out-Null
Copy-Item -LiteralPath "$fdiTask/project/src" -Destination "$fdiStage/src" -Recurse
Copy-Item -LiteralPath "$fdiTask/project/assets/rom_row_span.hex" -Destination "$fdiStage/rom_row_span.hex"
Copy-Item -LiteralPath "$fdiTask/project/src/vendor/fdi_stream/fdi_row_span_rom.vh" -Destination "$fdiStage/fdi_row_span_rom.vh"
Copy-Item -LiteralPath "$fdiTask/project/src/constraints/eth_m6_master.sdc" -Destination "$fdiStage/production.sdc"
$fdiInput=Join-Path "$fdiTask" "td_run/$InputTag"
if($Mode -ne 'synth'){
 $fdiDbName=if($Mode -eq 'route' -and $RouteStrategy -eq 'repair'){'failed_route.db'}elseif($Mode -in @('hold','prehold','bit')){'route.db'}elseif($Mode -in @('pcheck','route')){'place.db'}else{'gate.db'}
 Copy-Item -LiteralPath "$fdiInput/$fdiDbName" -Destination "$fdiStage/input.db"
 if($Mode -in @('pcheck','route','hold','prehold','bit')){
  if($Mode -eq 'route' -and $RouteStrategy -eq 'repair'){
   Copy-Item -LiteralPath "$fdiInput/production.sdc" -Destination "$fdiStage/production.sdc"
   Copy-Item -LiteralPath "$fdiInput/ACTIVE_SDC_EXPECTED.json" -Destination "$fdiStage/ACTIVE_SDC_EXPECTED.json"
  }else{
   Copy-Item -LiteralPath "$fdiInput/physical.sdc" -Destination "$fdiStage/production.sdc"
   Copy-Item -LiteralPath "$fdiInput/PHYSICAL_SDC_EXPECTED.json" -Destination "$fdiStage/ACTIVE_SDC_EXPECTED.json"
  }
 }
}
& node "$PSScriptRoot/prepare_round2.cjs" "$fdiStage" "$fdiOutput" "$Mode" "$fdiInput" "$HoldStrategy" "$RouteEffort" "$PlaceSeed" "$RouteStrategy" "$FlowThreads"
if($LASTEXITCODE -ne 0){throw 'Round2 source preparation failed'}
Copy-Item -LiteralPath "$fdiOutput/run.tcl","$fdiOutput/SOURCE_MANIFEST.json" -Destination "$fdiStage"
$fdiProcess=Start-Process -FilePath "D:/AnLu/bin/td_commands_prompt.exe" -ArgumentList @($fdiStage.Replace('\','/')+'/run.tcl') -WorkingDirectory "$fdiStage" -WindowStyle Hidden -PassThru -RedirectStandardOutput "$fdiStage/console.log" -RedirectStandardError "$fdiStage/stderr.log"
@{pid=$fdiProcess.Id;started_utc=$fdiProcess.StartTime.ToUniversalTime().ToString('o');stage=$fdiStage;mode=$Mode} | ConvertTo-Json | Set-Content -LiteralPath "$fdiOutput/RUN_IDENTITY.json" -Encoding UTF8
Write-Output "FDI R2 TD PID=$($fdiProcess.Id) STAGE=$fdiStage MODE=$Mode"
$fdiProcess.WaitForExit()
Get-ChildItem -LiteralPath "$fdiStage" -File | ForEach-Object {Copy-Item -LiteralPath $_.FullName -Destination "$fdiOutput"}
Copy-Item -LiteralPath "$fdiStage/src" -Destination "$fdiOutput/src" -Recurse
& node "$PSScriptRoot/read_round2.cjs" "$fdiOutput" "$Mode"
if($LASTEXITCODE -ne 0){throw 'Round2 stage gate failed; raw evidence retained'}
