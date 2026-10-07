#requires -Version 5.1
[CmdletBinding()] param()
$ErrorActionPreference='Continue'
$here=Split-Path -Parent $MyInvocation.MyCommand.Path
$core=Join-Path $here 'PZ-B42.21-Multiplayer-Patch.ps1'
$overlay=Join-Path $here 'PZ-B42.21-MP-Overlay.ps1'
Write-Host '=== Static multiplayer audit ===' -ForegroundColor Cyan
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $core -Mode Audit -TargetVersion 42.21
$coreRC=$LASTEXITCODE
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $overlay -Mode Audit -TargetVersion 42.21
$overlayRC=$LASTEXITCODE
Write-Host ''
Write-Host ('Core audit exit: '+$coreRC)
Write-Host ('Overlay audit exit: '+$overlayRC)
$log=Join-Path $env:USERPROFILE 'Zomboid\coop-console.txt'
if(Test-Path -LiteralPath $log){
  Write-Host ''
  Write-Host '=== Latest hosted multiplayer log ===' -ForegroundColor Cyan
  $lines=Get-Content -LiteralPath $log -ErrorAction SilentlyContinue
  $start=0
  for($i=$lines.Count-1;$i -ge 0;$i--){ if($lines[$i] -match 'version=42\.21'){ $start=$i; break } }
  if($lines.Count -gt 0){ $seg=$lines[$start..($lines.Count-1)] } else { $seg=@() }
  $checks=[ordered]@{
    'NetChecksum null-path exceptions'=@($seg|Where-Object{$_ -match 'NetChecksum\$Checksummer\.addFile'}).Count
    'Missing client/server files'=@($seg|Where-Object{$_ -match 'File doesn.t exist on the (client|server)'}).Count
    'Checksum mismatches'=@($seg|Where-Object{$_ -match '(?i)(checksum mismatch|doesn.t match the one on the server)'}).Count
    'GloveBox key-spawn exceptions'=@($seg|Where-Object{$_ -match 'BaseVehicle\.add(Key|BuildingKey)ToGloveBox'}).Count
    'Gael factory/loot require warnings'=@($seg|Where-Object{$_ -match 'GGS_(FactoryPresets|LootMagazineRules)'}).Count
    'Lua/server error lines'=@($seg|Where-Object{$_ -match ' ERROR:'}).Count
    'Exception/stack lines'=@($seg|Where-Object{$_ -match '(?i)(Exception thrown|stack traceback|Callframe at:)'}).Count
  }
  foreach($k in $checks.Keys){ Write-Host ($k+': '+$checks[$k]) }
} else {
  Write-Host 'No coop-console.txt yet. Static audits are complete; host/join once, then rerun Verify for runtime evidence.' -ForegroundColor Yellow
}
Write-Host ''
if($coreRC -eq 0 -and $overlayRC -eq 0){ Write-Host 'STATIC PORT STATUS: CLEAN' -ForegroundColor Green } else { Write-Host 'STATIC PORT STATUS: NEEDS APPLY/REVIEW' -ForegroundColor Yellow }