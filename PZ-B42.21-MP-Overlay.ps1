#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Audit','Apply','Restore')]
    [string]$Mode = 'Audit',
    [string]$TargetVersion = '42.21',
    [string]$BackupSet = ''
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$OverlayId = 'PZ42MPCompat'
$OverlayName = 'PZ 42.21 Multiplayer Compatibility Overlay'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$MapPath = Join-Path $Here 'PZ-B42.21-MP-OverlayMap.json'
$AliasPath = Join-Path $Here 'PZ42MPCompat_aliases.txt'
$UserZomboid = Join-Path $env:USERPROFILE 'Zomboid'
$OverlayBase = Join-Path $UserZomboid ('mods\' + $OverlayId)
$OverlayRoot = Join-Path $OverlayBase $TargetVersion
$BackupRoot = Join-Path $UserZomboid 'PZ42MPOverlayBackup'

if (!(Test-Path -LiteralPath $MapPath)) { throw "Missing overlay map: $MapPath" }
if (!(Test-Path -LiteralPath $AliasPath)) { throw "Missing custom alias file: $AliasPath" }

function Write-S([string]$Text,[ConsoleColor]$Color=[ConsoleColor]::Gray){ Write-Host $Text -ForegroundColor $Color }

function Get-SteamRoot {
    $roots = @()
    foreach($k in @('HKCU:\Software\Valve\Steam','HKLM:\SOFTWARE\WOW6432Node\Valve\Steam','HKLM:\SOFTWARE\Valve\Steam')){
        try{
            $p=Get-ItemProperty $k -ErrorAction Stop
            if($p.SteamPath){$roots += [string]$p.SteamPath}
            if($p.InstallPath){$roots += [string]$p.InstallPath}
        }catch{}
    }
    $pf86=[Environment]::GetFolderPath('ProgramFilesX86')
    if($pf86){$roots += (Join-Path $pf86 'Steam')}
    $roots | Where-Object { Test-Path -LiteralPath $_ } | Sort-Object -Unique | Select-Object -First 1
}

$SteamRoot = Get-SteamRoot
if(!$SteamRoot){throw 'Steam root not found.'}
$WorkshopRoot = Join-Path $SteamRoot 'steamapps\workshop\content\108600'
if(!(Test-Path -LiteralPath $WorkshopRoot)){throw "Project Zomboid Workshop root not found: $WorkshopRoot"}

$Map = Get-Content -LiteralPath $MapPath -Raw | ConvertFrom-Json
if($Map.Count -ne 48){throw "Expected 48 overlay source mappings, found $($Map.Count)."}

function Get-SourcePath($Entry){
    Join-Path $WorkshopRoot (Join-Path ([string]$Entry.WorkshopId) (Join-Path 'mods' (Join-Path ([string]$Entry.ModFolder) (Join-Path ([string]$Entry.LoadRoot) ([string]$Entry.Relative)))))
}

function Get-ServerProfiles {
    $serverDir = Join-Path $UserZomboid 'Server'
    if(!(Test-Path -LiteralPath $serverDir)){return @()}
    $profiles = @()
    foreach($ini in Get-ChildItem -LiteralPath $serverDir -File -Filter '*.ini' -ErrorAction SilentlyContinue){
        if($ini.BaseName -match '^(MPPortTest42|MPVanillaTest42|MPProbe|PZMPPortTest)'){continue}
        $raw=[IO.File]::ReadAllText($ini.FullName)
        $m=[regex]::Match($raw,'(?im)^Mods=(?<v>[^\r\n]*)')
        if(!$m.Success){continue}
        $ids=@($m.Groups['v'].Value -split ';' | Where-Object {$_})
        $known=@('damnlib','tsarslib','GaelGunStore_B42','KI5campers','FordExcursion2005PapaChad','Military_Tool_Kit','67commando','86oshkoshP19A','U.S.M113_APC_by_Papa_Chad','Fallout Hummer by Papa_Chad','U.S. M163 VADS by Papa_Chad by Papa_Chad')
        $relevant=@($ids | Where-Object { $_ -in $known }).Count -gt 0
        if($relevant){$profiles += $ini.FullName}
    }
    @($profiles | Sort-Object -Unique)
}

$Sources = @()
$Missing = @()
foreach($e in $Map){
    $src=Get-SourcePath $e
    if(Test-Path -LiteralPath $src){
        $Sources += [pscustomobject]@{Entry=$e;Source=$src;Destination=(Join-Path $OverlayRoot ([string]$e.Relative))}
    }else{
        $Missing += $src
    }
}
$Profiles = @(Get-ServerProfiles)

Write-S ''
Write-S "PZ B42.21 multiplayer overlay - $Mode" Cyan
Write-S "Workshop root: $WorkshopRoot"
Write-S ("Mapped source files: {0}/48" -f $Sources.Count)
Write-S ("Relevant server profiles: {0}" -f $Profiles.Count)
Write-S ("Overlay target: {0}" -f $OverlayRoot)
if($Missing.Count){
    Write-S ("Missing source files: {0}" -f $Missing.Count) Red
    foreach($p in $Missing){Write-Host "  MISSING $p"}
}

function Test-Overlay {
    if(!(Test-Path -LiteralPath $OverlayRoot)){return $false}
    $files=@(Get-ChildItem -LiteralPath $OverlayRoot -Recurse -File -ErrorAction SilentlyContinue)
    if($files.Count -ne 50){return $false}
    $info=Join-Path $OverlayRoot 'mod.info'
    $alias=Join-Path $OverlayRoot 'media\scripts\PZ42MPCompat_aliases.txt'
    if(!(Test-Path $info) -or !(Test-Path $alias)){return $false}
    foreach($s in $Sources){
        $dst=$s.Destination
        if(!(Test-Path -LiteralPath $dst)){return $false}
        if((Get-FileHash -LiteralPath $s.Source -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash){return $false}
    }
    if((Get-FileHash -LiteralPath $AliasPath -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $alias -Algorithm SHA256).Hash){return $false}
    $true
}

function Test-Profiles {
    foreach($p in $Profiles){
        $raw=[IO.File]::ReadAllText($p)
        $m=[regex]::Match($raw,'(?im)^Mods=(?<v>[^\r\n]*)')
        if(!$m.Success){return $false}
        $ids=@($m.Groups['v'].Value -split ';' | Where-Object {$_})
        if($ids -notcontains $OverlayId){return $false}
        if($ids[-1] -ne $OverlayId){return $false}
        if($raw -notmatch '(?im)^DoLuaChecksum=true(?:\r?$)'){return $false}
    }
    $true
}

if($Mode -eq 'Audit'){
    if($Missing.Count){exit 2}
    $overlayOk=Test-Overlay
    $profilesOk=Test-Profiles
    Write-S ("Overlay content current: {0}" -f $overlayOk) $(if($overlayOk){'Green'}else{'Yellow'})
    Write-S ("Server profiles current: {0}" -f $profilesOk) $(if($profilesOk){'Green'}else{'Yellow'})
    if($overlayOk -and $profilesOk){
        Write-S 'Audit complete. No overlay changes are needed.' Green
        exit 0
    }
    Write-S 'Audit complete. Apply is needed.' Yellow
    exit 1
}

function Get-LatestBackup {
    if(!(Test-Path -LiteralPath $BackupRoot)){return $null}
    Get-ChildItem -LiteralPath $BackupRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
}

if($Mode -eq 'Restore'){
    $dir=$BackupSet
    if(!$dir){$b=Get-LatestBackup;if($b){$dir=$b.FullName}}
    if(!$dir){throw 'No overlay backup set found.'}
    $manifestPath=Join-Path $dir 'manifest.json'
    if(!(Test-Path -LiteralPath $manifestPath)){throw "Missing manifest: $manifestPath"}
    $m=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

    if(Test-Path -LiteralPath $OverlayBase){Remove-Item -LiteralPath $OverlayBase -Recurse -Force}
    if($m.OverlayExistedBefore -and (Test-Path -LiteralPath $m.OverlayBackup)){
        Copy-Item -LiteralPath $m.OverlayBackup -Destination $OverlayBase -Recurse -Force
        Write-S "Restored prior overlay: $OverlayBase" Yellow
    }else{
        Write-S "Removed generated overlay: $OverlayBase" Yellow
    }

    foreach($p in @($m.Profiles)){
        if(Test-Path -LiteralPath $p.BackupPath){
            Copy-Item -LiteralPath $p.BackupPath -Destination $p.OriginalPath -Force
            Write-S "Restored server profile: $($p.OriginalPath)" Yellow
        }
    }
    Write-S "Overlay restore complete: $dir" Green
    exit 0
}

if(Get-Process -ErrorAction SilentlyContinue | Where-Object {$_.ProcessName -like 'ProjectZomboid*'}){
    throw 'Project Zomboid is running. Close the game/server before applying the multiplayer overlay.'
}
if($Missing.Count){throw 'Required Workshop source files are missing. Run the core multiplayer patch Audit and confirm all subscriptions first.'}

$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$backup=Join-Path $BackupRoot $stamp
New-Item -ItemType Directory -Path $backup -Force | Out-Null

$overlayExisted=Test-Path -LiteralPath $OverlayBase
$overlayBak=Join-Path $backup 'overlay-before'
if($overlayExisted){Copy-Item -LiteralPath $OverlayBase -Destination $overlayBak -Recurse -Force}

$profileBackups=@()
$i=0
foreach($p in $Profiles){
    $i++
    $bak=Join-Path $backup ("profile-{0:D2}.ini" -f $i)
    Copy-Item -LiteralPath $p -Destination $bak -Force
    $profileBackups += [pscustomobject]@{OriginalPath=$p;BackupPath=$bak}
}

if(Test-Path -LiteralPath $OverlayBase){Remove-Item -LiteralPath $OverlayBase -Recurse -Force}
New-Item -ItemType Directory -Path $OverlayRoot -Force | Out-Null

foreach($s in $Sources){
    $parent=Split-Path $s.Destination -Parent
    if(!(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Path $parent -Force | Out-Null}
    Copy-Item -LiteralPath $s.Source -Destination $s.Destination -Force
}

$aliasDest=Join-Path $OverlayRoot 'media\scripts\PZ42MPCompat_aliases.txt'
$aliasParent=Split-Path $aliasDest -Parent
if(!(Test-Path -LiteralPath $aliasParent)){New-Item -ItemType Directory -Path $aliasParent -Force | Out-Null}
Copy-Item -LiteralPath $AliasPath -Destination $aliasDest -Force

$info=@(
"name=$OverlayName",
"id=$OverlayId",
'description=Generated compatibility overrides for the tested B42.21 multiplayer mod stack.',
"versionMin=$TargetVersion",
'modversion=1.0.0'
) -join "`r`n"
[IO.File]::WriteAllText((Join-Path $OverlayRoot 'mod.info'),$info+"`r`n",$Utf8NoBom)

foreach($p in $Profiles){
    $raw=[IO.File]::ReadAllText($p)
    $m=[regex]::Match($raw,'(?im)^Mods=(?<v>[^\r\n]*)')
    if(!$m.Success){continue}
    $ids=@($m.Groups['v'].Value -split ';' | Where-Object {$_ -and $_ -ne $OverlayId})
    $ids += $OverlayId
    $newLine='Mods='+($ids -join ';')
    $new=$raw.Substring(0,$m.Index)+$newLine+$raw.Substring($m.Index+$m.Length)
    if($new -match '(?im)^DoLuaChecksum\s*='){
        $new=[regex]::Replace($new,'(?im)^DoLuaChecksum\s*=[^\r\n]*','DoLuaChecksum=true')
    }else{
        $new=$new.TrimEnd()+"`r`nDoLuaChecksum=true`r`n"
    }
    [IO.File]::WriteAllText($p,$new,$Utf8NoBom)
    Write-S "Updated server profile: $p" Green
}

$manifest=[ordered]@{
    Created=(Get-Date).ToString('o')
    TargetVersion=$TargetVersion
    OverlayExistedBefore=$overlayExisted
    OverlayBackup=$(if($overlayExisted){$overlayBak}else{''})
    Profiles=$profileBackups
}
[IO.File]::WriteAllText((Join-Path $backup 'manifest.json'),($manifest|ConvertTo-Json -Depth 5),$Utf8NoBom)

if(!(Test-Overlay)){throw 'Overlay verification failed after Apply.'}
if(!(Test-Profiles)){throw 'Server-profile verification failed after Apply.'}
Write-S ''
Write-S "Overlay apply complete. Backup: $backup" Green
Write-S 'Run Audit again. It should report no changes needed.' Cyan
