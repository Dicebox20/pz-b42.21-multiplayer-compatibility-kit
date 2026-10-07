#requires -Version 5.1
[CmdletBinding()]
param(
    [int]$PollSeconds = 2,
    [int]$DurationSeconds = 0,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$startTime = Get-Date
$stamp = $startTime.ToString('yyyyMMdd-HHmmss')
$zomboid = Join-Path $env:USERPROFILE 'Zomboid'
$outRoot = Join-Path $zomboid 'LiveModuleDiagnostics'
$outDir = Join-Path $outRoot $stamp
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$modulePatterns = [ordered]@{
    'Papa_Chad'     = '(?i)(Papa_Chad|M163|M113|Fallout Hummer|FordExcursion|Military_Tool_Kit|86oshkoshP19A|67commando|83amgeneralM923|78amgeneralM35|M49A2C|M50A3|M62)'
    'KI5_DAMN'      = '(?i)(KI5campers|KI5CR|\bdamnlib\b|\bDAMN\b)'
    'TsarLib'       = '(?i)(\btsarslib\b|Tsar.?s Common Library|ATA2?|ata_truckbed|template_ata)'
    'GaelGunStore'  = '(?i)(GaelGunStore|\bGGS_)'
    'W900'          = '(?i)(\brSemiTruck\b|W900|SemiTruck)'
    'PZ42MPCompat'  = '(?i)(PZ42MPCompat|Multiplayer Compatibility Overlay)'
}

$issueRules = @(
    [pscustomobject]@{Severity='CRITICAL'; Code='CHECKSUM_MISMATCH'; Pattern='(?i)(checksum mismatch|doesn.t match the one on the server|File doesn.t exist on the (client|server))'},
    [pscustomobject]@{Severity='CRITICAL'; Code='GLOVEBOX_NPE'; Pattern='(?i)BaseVehicle\.add(Key|BuildingKey)ToGloveBox'},
    [pscustomobject]@{Severity='HIGH'; Code='NETCHECKSUM_NULLPATH'; Pattern='(?i)NetChecksum\$Checksummer\.addFile'},
    [pscustomobject]@{Severity='HIGH'; Code='GGS_REQUIRE'; Pattern='(?i)(GGS_FactoryPresets|GGS_LootMagazineRules).*failed'},
    [pscustomobject]@{Severity='HIGH'; Code='REQUIRE_FAILED'; Pattern='(?i)require\(.+\) failed'},
    [pscustomobject]@{Severity='HIGH'; Code='CLIENT_SERVER_COMMAND'; Pattern='(?i)((OnClientCommand|ClientCommand).*(ERROR|Exception)|(OnServerCommand|ServerCommand).*(ERROR|Exception))'},
    [pscustomobject]@{Severity='HIGH'; Code='LUA_ERROR'; Pattern='(?i)ERROR:\s+Lua'},
    [pscustomobject]@{Severity='HIGH'; Code='EXCEPTION'; Pattern='(?i)(Exception thrown|stack traceback|Callframe at:)'},
    [pscustomobject]@{Severity='MEDIUM'; Code='GENERAL_ERROR'; Pattern='(?i)ERROR:\s+General'},
    [pscustomobject]@{Severity='INFO'; Code='MODEL_WARNING'; Pattern='(?i)(ModelScript\.checkMesh|mesh.+not found|missing mesh)'}
)

$activityRules = [ordered]@{
    'ModuleLoad'     = '(?i)LOG\s+:\s+Mod.*loading\s+'
    'PlayerConnect'  = '(?i)(fully connected|connection accepted|player.+connect|login.+accepted)'
    'Vehicle'        = '(?i)(BaseVehicle|VehicleManager|vehicle.+spawn|addToWorld)'
    'Inventory'      = '(?i)(InventoryItem|ItemContainer|AddItem|container)'
    'Weapon'         = '(?i)(GGS_|firearm|reload|magazine|rack|ammo)'
    'NetworkCommand' = '(?i)(OnClientCommand|OnServerCommand|ClientCommand|ServerCommand|sendClientCommand|sendServerCommand)'
}

$moduleStats = @{}
foreach($name in $modulePatterns.Keys){
    $moduleStats[$name] = [ordered]@{Lines=0;Loads=0;Issues=0;ManualTested=$false;LastSeen=''}
}
$activityStats = @{}
foreach($name in $activityRules.Keys){$activityStats[$name]=0}
$issueStats = @{}
foreach($r in $issueRules){$issueStats[$r.Code]=0}

$issues = New-Object System.Collections.ArrayList
$sourceStats = @{}
$positions = @{}

function Get-CurrentLogFiles {
    $paths = @()
    foreach($p in @(
        (Join-Path $zomboid 'console.txt'),
        (Join-Path $zomboid 'coop-console.txt')
    )){
        if(Test-Path -LiteralPath $p){$paths += $p}
    }
    $logsDir = Join-Path $zomboid 'Logs'
    if(Test-Path -LiteralPath $logsDir){
        $server = Get-ChildItem -LiteralPath $logsDir -Recurse -File -Filter '*DebugLog-server.txt' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if($server){$paths += $server.FullName}
    }
    @($paths | Sort-Object -Unique)
}

function Add-Source([string]$Path,[bool]$StartAtEnd=$true){
    if($positions.ContainsKey($Path)){return}
    $len = (Get-Item -LiteralPath $Path).Length
    $positions[$Path] = $(if($StartAtEnd){[int64]$len}else{[int64]0})
    $sourceStats[$Path] = 0
    Write-Host ("Watching: " + $Path) -ForegroundColor DarkGray
}

function Read-NewLines([string]$Path){
    if(!(Test-Path -LiteralPath $Path)){return @()}
    $fs = New-Object System.IO.FileStream($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try{
        $pos=[int64]$positions[$Path]
        if($pos -gt $fs.Length){$pos=0}
        $remaining=[int64]($fs.Length-$pos)
        if($remaining -le 0){return @()}
        if($remaining -gt [int]::MaxValue){throw "Log append chunk is too large: $remaining bytes"}
        [void]$fs.Seek($pos,[IO.SeekOrigin]::Begin)
        $bytes=New-Object byte[] ([int]$remaining)
        $read=$fs.Read($bytes,0,$bytes.Length)
        $positions[$Path]=$pos+$read
    }finally{$fs.Dispose()}
    if($read -le 0){return @()}
    $text=[Text.Encoding]::UTF8.GetString($bytes,0,$read)
    if([string]::IsNullOrEmpty($text)){return @()}
    @($text -split "\r?\n" | Where-Object {$_ -ne ''})
}

function Classify-Line([string]$Source,[string]$Line){
    $sourceStats[$Source] = [int]$sourceStats[$Source] + 1

    $modsHit=@()
    foreach($name in $modulePatterns.Keys){
        if($Line -match $modulePatterns[$name]){
            $modsHit += $name
            $moduleStats[$name].Lines++
            $moduleStats[$name].LastSeen=(Get-Date).ToString('HH:mm:ss')
            if($Line -match $activityRules['ModuleLoad']){$moduleStats[$name].Loads++}
        }
    }

    foreach($name in $activityRules.Keys){
        if($Line -match $activityRules[$name]){$activityStats[$name]++}
    }

    foreach($rule in $issueRules){
        if($Line -match $rule.Pattern){
            $attributed=@($modsHit)
            if($rule.Code -eq 'GLOVEBOX_NPE' -and $attributed.Count -eq 0){$attributed=@('Papa_Chad','KI5_DAMN')}
            if($rule.Code -eq 'GGS_REQUIRE' -and $attributed.Count -eq 0){$attributed=@('GaelGunStore')}

            $severity=$rule.Severity
            if($attributed.Count -eq 0 -and $rule.Code -in @('LUA_ERROR','EXCEPTION','GENERAL_ERROR','REQUIRE_FAILED')){
                $severity='REVIEW'
            }

            $issueStats[$rule.Code]++
            foreach($m in $attributed){
                if($moduleStats.ContainsKey($m)){$moduleStats[$m].Issues++}
            }
            $entry=[pscustomobject]@{
                Time=(Get-Date).ToString('o')
                Severity=$severity
                Code=$rule.Code
                Source=$Source
                Modules=($attributed -join ',')
                Line=$Line
            }
            [void]$issues.Add($entry)
            if($severity -in @('CRITICAL','HIGH')){
                Write-Host ("[{0}] {1}: {2}" -f $severity,$rule.Code,$Line) -ForegroundColor Yellow
            }
        }
    }
}

function Write-Reports {
    $end=Get-Date
    $moduleRows=@()
    foreach($name in $modulePatterns.Keys){
        $s=$moduleStats[$name]
        $status = if($s.Issues -gt 0){'ISSUES OBSERVED'} elseif($s.ManualTested){'TESTED CLEAN'} elseif($s.Lines -gt 0){'ACTIVITY OBSERVED'} else {'NOT OBSERVED'}
        $moduleRows += [pscustomobject]@{
            Module=$name
            Status=$status
            ManualTested=[bool]$s.ManualTested
            Lines=[int]$s.Lines
            Loads=[int]$s.Loads
            Issues=[int]$s.Issues
            LastSeen=[string]$s.LastSeen
        }
    }

    $critical=@($issues | Where-Object {$_.Severity -eq 'CRITICAL'}).Count
    $high=@($issues | Where-Object {$_.Severity -eq 'HIGH'}).Count
    $medium=@($issues | Where-Object {$_.Severity -eq 'MEDIUM'}).Count
    $review=@($issues | Where-Object {$_.Severity -eq 'REVIEW'}).Count
    $info=@($issues | Where-Object {$_.Severity -eq 'INFO'}).Count

    $txt=New-Object System.Collections.Generic.List[string]
    $txt.Add('Project Zomboid B42.21 Live Module Diagnostic') | Out-Null
    $txt.Add(('Started:  '+$startTime.ToString('o'))) | Out-Null
    $txt.Add(('Finished: '+$end.ToString('o'))) | Out-Null
    $txt.Add(('Duration: '+[Math]::Round(($end-$startTime).TotalMinutes,2)+' minutes')) | Out-Null
    $txt.Add('') | Out-Null
    $txt.Add('MODULE STATUS') | Out-Null
    foreach($r in $moduleRows){
        $txt.Add(('{0,-14} {1,-18} tested={2} lines={3} loads={4} issues={5} last={6}' -f $r.Module,$r.Status,$r.ManualTested,$r.Lines,$r.Loads,$r.Issues,$r.LastSeen)) | Out-Null
    }
    $txt.Add('') | Out-Null
    $txt.Add('ACTIVITY COUNTS') | Out-Null
    foreach($k in $activityStats.Keys){$txt.Add(('{0,-16} {1}' -f $k,$activityStats[$k]))|Out-Null}
    $txt.Add('') | Out-Null
    $txt.Add(('ISSUES: CRITICAL={0} HIGH={1} MEDIUM={2} REVIEW={3} INFO={4}' -f $critical,$high,$medium,$review,$info)) | Out-Null
    foreach($k in $issueStats.Keys){if($issueStats[$k] -gt 0){$txt.Add(('  {0,-26} {1}' -f $k,$issueStats[$k]))|Out-Null}}
    $txt.Add('') | Out-Null
    $txt.Add('SOURCE LINES OBSERVED') | Out-Null
    foreach($k in $sourceStats.Keys){$txt.Add(('  {0}: {1}' -f $k,$sourceStats[$k]))|Out-Null}
    $txt.Add('') | Out-Null
    $txt.Add('INTERPRETATION') | Out-Null
    $txt.Add('- TESTED CLEAN means you manually marked that module after exercising it and no targeted issue was attributed to it.') | Out-Null
    $txt.Add('- ACTIVITY OBSERVED means the module appeared in new live-play log traffic without a targeted error.') | Out-Null
    $txt.Add('- NOT OBSERVED does not mean broken. It means the session did not generate identifiable log traffic for that module.') | Out-Null
    $txt.Add('- REVIEW entries are unrelated/unattributed runtime errors that should be inspected but do not automatically fail a module.') | Out-Null
    $txt.Add('- Any CRITICAL/HIGH issue should be investigated before calling that module multiplayer-clean.') | Out-Null
    if($issues.Count -gt 0){
        $txt.Add('')|Out-Null
        $txt.Add('ISSUE DETAILS')|Out-Null
        foreach($i in $issues){$txt.Add(('[{0}] {1} {2} [{3}] {4}' -f $i.Severity,$i.Time,$i.Code,$i.Modules,$i.Line))|Out-Null}
    }

    $txtPath=Join-Path $outDir 'Live-Module-Diagnostic.txt'
    $jsonPath=Join-Path $outDir 'Live-Module-Diagnostic.json'
    [IO.File]::WriteAllLines($txtPath,$txt,(New-Object Text.UTF8Encoding($false)))

    $obj=[ordered]@{
        Started=$startTime.ToString('o')
        Finished=$end.ToString('o')
        Modules=$moduleRows
        Activity=$activityStats
        IssueCounts=$issueStats
        Issues=@($issues.ToArray())
        Sources=$sourceStats
    }
    [IO.File]::WriteAllText($jsonPath,($obj|ConvertTo-Json -Depth 7),(New-Object Text.UTF8Encoding($false)))
    Write-Host ''
    Write-Host ("Report: "+$txtPath) -ForegroundColor Green
    Write-Host ("JSON:   "+$jsonPath) -ForegroundColor DarkGreen
}

foreach($p in Get-CurrentLogFiles){Add-Source $p $true}

Write-Host ''
Write-Host 'PZ B42.21 LIVE MODULE DIAGNOSTIC' -ForegroundColor Cyan
Write-Host 'Only log lines created after this watcher started will be counted.' -ForegroundColor Gray
if($DurationSeconds -gt 0){
    Write-Host ("Automatic stop after {0} seconds." -f $DurationSeconds) -ForegroundColor Gray
}else{
    Write-Host 'Play normally. After testing a module, press its number here:' -ForegroundColor Yellow
    Write-Host '  1 Papa_Chad   2 KI5/DAMN   3 TsarLib   4 GaelGunStore   5 W900   6 PZ42MPCompat' -ForegroundColor Yellow
    Write-Host 'Press Q when finished to write the report.' -ForegroundColor Yellow
}
Write-Host ''

$stopRequested=$false
try{
    while($true){
        foreach($p in Get-CurrentLogFiles){
            if(!$positions.ContainsKey($p)){Add-Source $p $false}
        }
        foreach($p in @($positions.Keys)){
            foreach($line in Read-NewLines $p){Classify-Line $p $line}
        }

        if($DurationSeconds -gt 0 -and ((Get-Date)-$startTime).TotalSeconds -ge $DurationSeconds){break}
        if($DurationSeconds -le 0 -and [Environment]::UserInteractive){
            try{
                if([Console]::KeyAvailable){
                    $key=[Console]::ReadKey($true)
                    $ch=[string]$key.KeyChar
                    $mark=$null
                    switch($ch){
                        '1' {$mark='Papa_Chad'}
                        '2' {$mark='KI5_DAMN'}
                        '3' {$mark='TsarLib'}
                        '4' {$mark='GaelGunStore'}
                        '5' {$mark='W900'}
                        '6' {$mark='PZ42MPCompat'}
                        'q' {$stopRequested=$true}
                        'Q' {$stopRequested=$true}
                    }
                    if($mark){
                        $moduleStats[$mark].ManualTested=$true
                        $moduleStats[$mark].LastSeen=(Get-Date).ToString('HH:mm:ss')
                        Write-Host ("Marked tested: "+$mark) -ForegroundColor Green
                    }
                }
            }catch{}
        }
        if($stopRequested){break}
        Start-Sleep -Seconds ([Math]::Max(1,$PollSeconds))
    }
}finally{
    Write-Reports
}

if(!$NoPause -and $DurationSeconds -le 0){
    Write-Host ''
    Write-Host 'Press Enter to close.' -ForegroundColor DarkGray
    [void](Read-Host)
}
