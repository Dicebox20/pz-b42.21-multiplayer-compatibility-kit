#requires -Version 5.1
<#
Project Zomboid Build 42.21 multiplayer compatibility patcher
Targets the tested multiplayer mod stack without redistributing Workshop assets.
Patches both the normal Steam subscription cache and the hosted-server Workshop cache when present.

Modes:
  Audit   - report planned changes only
  Apply   - create a backup set and apply reversible compatibility changes
  Restore - restore the latest backup set (or -BackupSet path)
#>
[CmdletBinding()]
param(
    [ValidateSet('Audit','Apply','Restore')]
    [string]$Mode = 'Audit',
    [string]$TargetVersion = '42.21',
    [string]$BackupSet = ''
)

$ErrorActionPreference = 'Stop'
$AppId = '108600'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# The patcher reads actual assets from the user's own Workshop subscriptions.
$TranslationWorkshopIds = @(
    '3624436943', # 1969 Dodge Charger
    '2799152995', # AM General M35 series
    '2811383142', # AM General M923
    '2566953935', # Oshkosh P19A
    '3658100636', # Fallout Hummer
    '3588624649', # Ford Excursion
    '3670064951', # KI5 Campers
    '3598575779', # M163 VADS
    '3608725379', # M41 Walker Bulldog
    '3554424111', # M998 Humvee
    '2705655822'  # M113 APC
)
$ItemTypeWorkshopIds = @(
    '3402491515', # Tsar's Common Library
    '3171167894'  # that DAMN Library
)
$GaelWorkshopId = '3616176188'
$ModInfoWorkshopIds = @(
    '3409472393' # W900 Semi-Truck: B41 version= -> B42 modversion=
)

# Merucia/tested multiplayer Workshop set. This is also used to bound MP-specific
# vehicle scans so unrelated subscribed mods are never modified.
$MultiplayerWorkshopIds = @(
    '3739363702','3171167894','3608725379','3598575779','2705655822',
    '3658100636','3670064951','3409472393','3402491515','3588624649',
    '2705406713','3616176188','3624436943','2811383142','2478247379',
    '2566953935','2618213077','2799152995','3634569678','3659823175'
)
$MeruciaWorkshopItems = ($MultiplayerWorkshopIds -join ';')

$RuntimeTextPatches = @(
    [pscustomobject]@{
        WorkshopId='2705406713'
        RelativePath='media\scripts\Papa_Chad_Template_Common.txt'
        Pattern='(?m)^(?<indent>[ \t]*)template vehicle Antenna[ \t]*\r?$'
        Replacement='${indent}template vehicle Antenna {'
        Description='Military Tool Kit: add the missing opening brace to the Antenna vehicle template.'
    },
    [pscustomobject]@{
        WorkshopId='2566953935'
        RelativePath='media\scripts\vehicles\86oshkoshFRTR55.txt'
        Pattern='(?m)^[ \t]*template[ \t]*=[ \t]*P19ABigTrunkCompartment2,[ \t]*\r?\n?'
        Replacement=''
        Description='P19A: remove obsolete second trunk template reference; current B42 primary template already includes both trunk sides.'
    },
    [pscustomobject]@{
        WorkshopId='2566953935'
        RelativePath='media\scripts\vehicles\86oshkoshKYFD.txt'
        Pattern='(?m)^[ \t]*template[ \t]*=[ \t]*P19ABigTrunkCompartment2,[ \t]*\r?\n?'
        Replacement=''
        Description='P19A: remove obsolete second trunk template reference; current B42 primary template already includes both trunk sides.'
    },
    [pscustomobject]@{
        WorkshopId='2566953935'
        RelativePath='media\scripts\vehicles\86oshkoshUSMC.txt'
        Pattern='(?m)^[ \t]*template[ \t]*=[ \t]*P19ABigTrunkCompartment2,[ \t]*\r?\n?'
        Replacement=''
        Description='P19A: remove obsolete second trunk template reference; current B42 primary template already includes both trunk sides.'
    },
    [pscustomobject]@{
        WorkshopId='2478247379'
        RelativePath='media\scripts\vehicles\67commando.txt'
        Pattern='(?m)^[ \t]*template[ \t]*=[ \t]*DAMN67commando,[ \t]*\r?\n?'
        Replacement=''
        Description='67 Commando: remove obsolete empty DAMN67commando marker-template reference.'
    },
    [pscustomobject]@{
        WorkshopId='2478247379'
        RelativePath='media\scripts\vehicles\67commandoPolice.txt'
        Pattern='(?m)^[ \t]*template[ \t]*=[ \t]*DAMN67commandoPolice,[ \t]*\r?\n?'
        Replacement=''
        Description='67 Commando: remove obsolete empty DAMN67commandoPolice marker-template reference.'
    },
    [pscustomobject]@{
        WorkshopId='2478247379'
        RelativePath='media\scripts\vehicles\67commandoT50.txt'
        Pattern='(?m)^[ \t]*template[ \t]*=[ \t]*DAMN67commandoT50,[ \t]*\r?\n?'
        Replacement=''
        Description='67 Commando: remove obsolete empty DAMN67commandoT50 marker-template reference.'
    }
)

function Write-Status([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray) {
    Write-Host $Text -ForegroundColor $Color
}

function Convert-PzVersion([string]$Text) {
    if ($Text -notmatch '^(?<a>\d+)(?:\.(?<b>\d+))?(?:\.(?<c>\d+))?$') { return $null }
    $a=[int]$Matches.a
    $b=if($Matches.b){[int]$Matches.b}else{0}
    $c=if($Matches.c){[int]$Matches.c}else{0}
    [pscustomobject]@{ Text=$Text; Score=($a*1000000+$b*1000+$c) }
}

$Target = Convert-PzVersion $TargetVersion
if (-not $Target -or $TargetVersion -notlike '42*') {
    throw 'TargetVersion must be a Build 42 version such as 42.21.'
}

function Get-SteamLibraries {
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($key in @(
        'HKCU:\Software\Valve\Steam',
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam'
    )) {
        try {
            $p = Get-ItemProperty -Path $key -ErrorAction Stop
            foreach ($name in @('SteamPath','InstallPath')) {
                if ($p.$name) { $roots.Add([string]$p.$name) | Out-Null }
            }
        } catch {}
    }
    $pf86 = [Environment]::GetFolderPath('ProgramFilesX86')
    if ($pf86) { $roots.Add((Join-Path $pf86 'Steam')) | Out-Null }

    $all = New-Object System.Collections.Generic.List[string]
    foreach ($root in ($roots | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $all.Add($root) | Out-Null
        $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($line in Get-Content -LiteralPath $vdf -ErrorAction SilentlyContinue) {
                if ($line -match '"path"\s+"(?<p>[^"]+)"') {
                    $p = $Matches.p -replace '\\\\','\'
                    if (Test-Path -LiteralPath $p) { $all.Add($p) | Out-Null }
                }
            }
        }
    }
    @($all | Sort-Object -Unique)
}

$SteamLibraries = @(Get-SteamLibraries)
$GameInstalls = @()
$WorkshopRoots = @()
foreach ($lib in $SteamLibraries) {
    $g = Join-Path $lib 'steamapps\common\ProjectZomboid'
    $w = Join-Path $lib "steamapps\workshop\content\$AppId"
    if (Test-Path -LiteralPath $g) { $GameInstalls += $g }
    if (Test-Path -LiteralPath $w) { $WorkshopRoots += $w }
}
$GameInstalls = @($GameInstalls | Sort-Object -Unique)
$PrimaryWorkshopRoots = @($WorkshopRoots | Sort-Object -Unique)
$HostedWorkshopRoots = @()
foreach ($g in $GameInstalls) {
    $hostWorkshop = Join-Path $g "steamapps\workshop\content\$AppId"
    if (Test-Path -LiteralPath $hostWorkshop) { $HostedWorkshopRoots += $hostWorkshop }
}
$HostedWorkshopRoots = @($HostedWorkshopRoots | Sort-Object -Unique)
$WorkshopRoots = @($PrimaryWorkshopRoots + $HostedWorkshopRoots | Sort-Object -Unique)
if ($PrimaryWorkshopRoots.Count -eq 0) { throw 'No Project Zomboid Steam Workshop subscription directory was found.' }

function Get-WorkshopItemRoots([string]$WorkshopId) {
    $out = @()
    foreach ($wr in $WorkshopRoots) {
        $p = Join-Path $wr $WorkshopId
        if (Test-Path -LiteralPath $p) { $out += $p }
    }
    @($out | Sort-Object -Unique)
}

function Get-ModRootsForWorkshop([string]$WorkshopId) {
    $out = @()
    foreach ($item in Get-WorkshopItemRoots $WorkshopId) {
        $mods = Join-Path $item 'mods'
        if (-not (Test-Path -LiteralPath $mods)) { continue }
        foreach ($m in Get-ChildItem -LiteralPath $mods -Directory -ErrorAction SilentlyContinue) {
            $out += [pscustomobject]@{ WorkshopId=$WorkshopId; ItemRoot=$item; ModRoot=$m.FullName }
        }
    }
    @($out)
}

function Get-B42LoadRoots([string]$ModRoot) {
    $roots = New-Object System.Collections.Generic.List[string]
    $common = Join-Path $ModRoot 'common'
    if (Test-Path -LiteralPath $common) { $roots.Add($common) | Out-Null }

    $versions = @()
    foreach ($d in Get-ChildItem -LiteralPath $ModRoot -Directory -ErrorAction SilentlyContinue) {
        $v = Convert-PzVersion $d.Name
        if ($v -and $v.Text -like '42*' -and $v.Score -le $Target.Score) {
            $versions += [pscustomobject]@{ Path=$d.FullName; Version=$v }
        }
    }
    $selected = $versions | Sort-Object { $_.Version.Score } -Descending | Select-Object -First 1
    if ($selected) { $roots.Add($selected.Path) | Out-Null }
    @($roots | Sort-Object -Unique)
}

function Get-CategoryAndLanguage([System.IO.FileInfo]$File) {
    $lang = Split-Path $File.DirectoryName -Leaf
    $base = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
    $suffix = "_$lang"
    if ($base.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase)) {
        $category = $base.Substring(0, $base.Length - $suffix.Length)
        return [pscustomobject]@{ Category=$category; Language=$lang }
    }
    $null
}

function Unescape-LuaString([string]$Value) {
    $sb = New-Object System.Text.StringBuilder
    for ($i=0; $i -lt $Value.Length; $i++) {
        $ch = $Value[$i]
        if ($ch -ne '\' -or $i+1 -ge $Value.Length) {
            [void]$sb.Append($ch)
            continue
        }
        $i++
        $n = $Value[$i]
        switch ($n) {
            'n' { [void]$sb.Append("`n") }
            'r' { [void]$sb.Append("`r") }
            't' { [void]$sb.Append("`t") }
            '"' { [void]$sb.Append('"') }
            '\' { [void]$sb.Append('\') }
            default { [void]$sb.Append('\'); [void]$sb.Append($n) }
        }
    }
    $sb.ToString()
}

function Transform-TranslationKey([string]$Category, [string]$Key) {
    switch ($Category.ToLowerInvariant()) {
        'recipes' {
            if ($Key.StartsWith('Recipe_', [StringComparison]::Ordinal)) { return $Key.Substring(7) }
        }
        'itemname' {
            if ($Key.StartsWith('ItemName_', [StringComparison]::Ordinal)) { return $Key.Substring(9) }
        }
        'evolvedrecipename' {
            if ($Key.StartsWith('EvolvedRecipeName_', [StringComparison]::Ordinal)) { return $Key.Substring(18) }
            if ($Key.StartsWith('ItemName_', [StringComparison]::Ordinal)) { return $Key.Substring(9) }
        }
    }
    $Key
}

function Get-TranslationConversion([string]$Path) {
    $file = Get-Item -LiteralPath $Path
    $info = Get-CategoryAndLanguage $file
    if (-not $info) { return [pscustomobject]@{Ok=$false;Reason='Filename has no _LANG suffix';Source=$Path} }

    $dest = Join-Path $file.DirectoryName ($info.Category + '.json')
    if (Test-Path -LiteralPath $dest) {
        return [pscustomobject]@{Ok=$false;Reason='JSON already exists';Source=$Path;Destination=$dest}
    }

    $pairs = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $bad = New-Object System.Collections.Generic.List[string]
    $duplicates = New-Object System.Collections.Generic.List[string]
    $lineNo = 0

    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $lineNo++
        $t = $line.Trim()
        if (-not $t -or $t -match '^(--|//)' -or $t -match '^\}\s*,?\s*$') { continue }
        if ($t -match '^[A-Za-z0-9_]+\s*(?:=\s*)?\{\s*$') { continue }

        $m = [regex]::Match($line, '^\s*(?<key>[^=]+?)\s*=\s*"(?<val>(?:\\.|[^"])*)"\s*,?\s*$')
        if (-not $m.Success) {
            $bad.Add("$lineNo`: $t") | Out-Null
            continue
        }

        $key = Transform-TranslationKey $info.Category $m.Groups['key'].Value.Trim()
        $value = Unescape-LuaString $m.Groups['val'].Value
        if (-not $seen.Add($key)) {
            $duplicates.Add($key) | Out-Null
            continue
        }
        $pairs.Add([pscustomobject]@{Key=$key;Value=$value}) | Out-Null
    }

    if ($bad.Count -gt 0 -or $pairs.Count -eq 0) {
        return [pscustomobject]@{Ok=$false;Reason='Unparsed or empty translation file';Source=$Path;Destination=$dest;BadLines=@($bad);DuplicateKeys=@($duplicates);PairCount=$pairs.Count}
    }

    $jsonLines = New-Object System.Collections.Generic.List[string]
    $jsonLines.Add('{') | Out-Null
    for ($i=0; $i -lt $pairs.Count; $i++) {
        $p = $pairs[$i]
        $k = ConvertTo-Json -Compress -InputObject ([string]$p.Key)
        $v = ConvertTo-Json -Compress -InputObject ([string]$p.Value)
        $comma = if ($i -lt $pairs.Count-1) { ',' } else { '' }
        $jsonLines.Add("    $k`: $v$comma") | Out-Null
    }
    $jsonLines.Add('}') | Out-Null
    [pscustomobject]@{Ok=$true;Source=$Path;Destination=$dest;Category=$info.Category;Language=$info.Language;Content=($jsonLines -join "`r`n")+"`r`n";PairCount=$pairs.Count;DuplicateKeys=@($duplicates)}
}

function Get-ModInfoPatch([string]$Path) {
    $raw = [System.IO.File]::ReadAllText($Path)
    if ($raw -match '(?im)^\s*modversion\s*=') {
        return [pscustomobject]@{Changed=$false;Path=$Path;Content=$raw}
    }
    $m = [regex]::Match($raw, '(?im)^(?<indent>\s*)version\s*=\s*(?<value>[^\r\n]+)\s*$')
    if (-not $m.Success) {
        return [pscustomobject]@{Changed=$false;Path=$Path;Content=$raw}
    }
    $replacement = $m.Groups['indent'].Value + 'modversion=' + $m.Groups['value'].Value.Trim()
    $new = $raw.Substring(0,$m.Index) + $replacement + $raw.Substring($m.Index + $m.Length)
    [pscustomobject]@{Changed=$true;Path=$Path;Content=$new}
}

function Get-BraceBlock([string]$Raw, [int]$Start) {
    $open = $Raw.IndexOf('{',$Start)
    if ($open -lt 0) { return $null }
    $depth = 0
    for ($i=$open; $i -lt $Raw.Length; $i++) {
        if ($Raw[$i] -eq '{') { $depth++ }
        elseif ($Raw[$i] -eq '}') {
            $depth--
            if ($depth -eq 0) {
                return [pscustomobject]@{Start=$Start;End=$i;Text=$Raw.Substring($Start,$i-$Start+1)}
            }
        }
    }
    $null
}

function Get-GloveBoxPatch([string]$Path) {
    $raw = [System.IO.File]::ReadAllText($Path)
    $count = 0

    $typos = [regex]::Matches($raw,'(?im)^\s*contanier\s*$')
    if ($typos.Count -gt 0) {
        $raw = [regex]::Replace($raw, '(?im)^(?<indent>\s*)contanier\s*$', '${indent}container')
        $count += $typos.Count
    }

    # Two current KI5 camper definitions still reference a retired stabilizer
    # template. Fold this into the same vehicle transform so it cannot overwrite
    # or be overwritten by the GloveBox repair.
    $staleStabilizers = [regex]::Matches($raw,'(?im)^(?<indent>\s*)template\s*=\s*KI5CRStabilizerB16,\s*$')
    if ($staleStabilizers.Count -gt 0) {
        $raw = [regex]::Replace($raw,'(?im)^(?<indent>\s*)template\s*=\s*KI5CRStabilizerB16,\s*$','${indent}template = KI5CRStabilizer,')
        $count += $staleStabilizers.Count
    }

    $matches = @([regex]::Matches($raw,'(?im)^\s*part\s+GloveBox\b'))
    $insertions = @()
    foreach ($m in $matches) {
        $b = Get-BraceBlock $raw $m.Index
        if (-not $b) { continue }
        if ($b.Text -match '(?im)^\s*container\s*\{') { continue }
        $anchor = [regex]::Match($b.Text,'(?im)^(?<indent>\s*)mechanicRequireKey\s*=\s*true\s*,?\s*$')
        if ($anchor.Success) {
            $indent = $anchor.Groups['indent'].Value
            $nl = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
            $text = $nl + $nl + $indent + 'container' + $nl + $indent + '{' + $nl +
                    $indent + '    capacity = 5,' + $nl +
                    $indent + '    test = Vehicles.ContainerAccess.GloveBox,' + $nl +
                    $indent + '}'
            $insertions += [pscustomobject]@{Position=($b.Start+$anchor.Index+$anchor.Length);Text=$text}
            continue
        }
        $lua = [regex]::Match($b.Text,'(?im)^(?<indent>\s*)lua\s*$')
        if ($lua.Success) {
            $indent = $lua.Groups['indent'].Value
            $nl = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
            $text = $indent + 'container' + $nl + $indent + '{' + $nl +
                    $indent + '    capacity = 5,' + $nl +
                    $indent + '    test = Vehicles.ContainerAccess.GloveBox,' + $nl +
                    $indent + '}' + $nl + $nl
            $insertions += [pscustomobject]@{Position=($b.Start+$lua.Index);Text=$text}
        }
    }
    foreach ($i in $insertions | Sort-Object Position -Descending) {
        $raw = $raw.Substring(0,$i.Position) + $i.Text + $raw.Substring($i.Position)
    }
    $count += $insertions.Count
    [pscustomobject]@{Changed=($count -gt 0);Path=$Path;Count=$count;Content=$raw}
}

function Get-GaelRequirePatch([string]$Path) {
    $raw = [System.IO.File]::ReadAllText($Path)
    $new = $raw.Replace('require("GGS_FactoryPresets")','require("item/GGS_FactoryPresets")')
    $new = $new.Replace('require("GGS_LootMagazineRules")','require("item/GGS_LootMagazineRules")')
    [pscustomobject]@{Changed=($new -ne $raw);Path=$Path;Count=$(if($new -ne $raw){1}else{0});Content=$new}
}

function Get-ItemTypePatch([string]$Path) {
    $raw = [System.IO.File]::ReadAllText($Path)
    $nl = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    $blocks = [regex]::Matches($raw, '(?ms)^\s*item\s+[^\s\{]+\s*(?:\r?\n\s*)?\{(?<body>.*?)(?=^\s*\})')
    $insertions = New-Object System.Collections.Generic.List[object]

    foreach ($b in $blocks) {
        $body = $b.Groups['body'].Value
        if ($body -match '(?im)^\s*ItemType\s*=') { continue }
        $tm = [regex]::Match($b.Value, '(?im)^(?<indent>\s*)Type\s*=\s*Normal\s*,?\s*$')
        if (-not $tm.Success) { continue }
        $insertions.Add([pscustomobject]@{Position=($b.Index+$tm.Index+$tm.Length);Text=($nl+$tm.Groups['indent'].Value+'ItemType = base:normal,')}) | Out-Null
    }

    if ($insertions.Count -eq 0) { return [pscustomobject]@{Changed=$false;Path=$Path;Count=0;Content=$raw} }
    $new = $raw
    foreach ($i in $insertions | Sort-Object Position -Descending) {
        $new = $new.Substring(0,$i.Position) + $i.Text + $new.Substring($i.Position)
    }
    [pscustomobject]@{Changed=$true;Path=$Path;Count=$insertions.Count;Content=$new}
}

$BackupRoot = Join-Path $env:USERPROFILE 'Zomboid\PZ42MultiplayerCompatBackup'
$script:Manifest = New-Object System.Collections.Generic.List[object]
$script:BackupDir = $null

function Ensure-BackupDirectory {
    if ($script:BackupDir) { return }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:BackupDir = Join-Path $BackupRoot $stamp
    New-Item -ItemType Directory -Path (Join-Path $script:BackupDir 'files') -Force | Out-Null
}

function Backup-ForChange([string]$Path, [string]$Kind, [bool]$ExistsBefore) {
    Ensure-BackupDirectory
    $entry = [ordered]@{OriginalPath=$Path;Kind=$Kind;ExistedBefore=$ExistsBefore;BackupPath=''}
    if ($ExistsBefore) {
        $n = $script:Manifest.Count + 1
        $backup = Join-Path $script:BackupDir ("files\{0:D4}.bak" -f $n)
        Copy-Item -LiteralPath $Path -Destination $backup -Force
        $entry.BackupPath = $backup
    }
    $script:Manifest.Add([pscustomobject]$entry) | Out-Null
    # Persist immediately so an interrupted Apply is still fully restorable.
    Save-Manifest
}

function Save-Manifest {
    if (-not $script:BackupDir) { return }
    $obj = [ordered]@{Created=(Get-Date).ToString('o');TargetVersion=$TargetVersion;Changes=$script:Manifest.ToArray()}
    $json = $obj | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText((Join-Path $script:BackupDir 'manifest.json'), $json, $Utf8NoBom)
}

function Restore-Backup {
    $dir = $BackupSet
    if (-not $dir) {
        if (-not (Test-Path -LiteralPath $BackupRoot)) { throw 'No compatibility backup directory exists.' }
        $dir = Get-ChildItem -LiteralPath $BackupRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $dir) { throw 'No backup set was found.' }
    $manifestPath = Join-Path $dir 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw "No manifest.json found in $dir" }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $changes = @($manifest.Changes)
    [array]::Reverse($changes)
    foreach ($c in $changes) {
        if ($c.ExistedBefore) {
            if (-not (Test-Path -LiteralPath $c.BackupPath)) { throw "Missing backup file: $($c.BackupPath)" }
            $parent = Split-Path $c.OriginalPath -Parent
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            Copy-Item -LiteralPath $c.BackupPath -Destination $c.OriginalPath -Force
            Write-Status "Restored: $($c.OriginalPath)" Yellow
        } else {
            if (Test-Path -LiteralPath $c.OriginalPath) {
                Remove-Item -LiteralPath $c.OriginalPath -Force
                Write-Status "Removed created file: $($c.OriginalPath)" Yellow
            }
        }
    }
    Write-Status "Restore complete from $dir" Green
}

if ($Mode -eq 'Restore') { Restore-Backup; exit 0 }

if ($Mode -eq 'Apply') {
    $pzRunning = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'ProjectZomboid*' }
    $serverRunning = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -eq 'java.exe' -and $_.CommandLine -match 'zombie\.network\.GameServer'
    }
    if ($pzRunning -or $serverRunning) {
        throw 'Project Zomboid or a Project Zomboid server is currently running. Close it before applying this patch.'
    }
}

$plans = New-Object System.Collections.Generic.List[object]

# Multiplayer vehicle schema repair. B42.21 server key-spawn code expects every
# part named GloveBox to have a real container object.
foreach ($wid in $MultiplayerWorkshopIds) {
    foreach ($mod in Get-ModRootsForWorkshop $wid) {
        foreach ($root in Get-B42LoadRoots $mod.ModRoot) {
            foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.txt' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '[\\/]media[\\/]scripts[\\/]' }) {
                $patch = Get-GloveBoxPatch $file.FullName
                if ($patch.Changed) {
                    $plans.Add([pscustomobject]@{Kind='GloveBox';WorkshopId=$wid;Path=$file.FullName;Count=$patch.Count;Content=$patch.Content;Source='';Description='Repair B42.21 GloveBox container schema.'}) | Out-Null
                }
            }
        }
    }
}

# GaelGunStore ships these modules under shared/item. Bare requires fail on the
# B42 multiplayer/server search path, so use their real module path.
foreach ($mod in Get-ModRootsForWorkshop $GaelWorkshopId) {
    foreach ($root in Get-B42LoadRoots $mod.ModRoot) {
        foreach ($rel in @(
            'media\lua\shared\item\GGS_WeaponUpgradeSystem.lua',
            'media\lua\server\item\GGS_FoundAmmo.lua'
        )) {
            $path = Join-Path $root $rel
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $patch = Get-GaelRequirePatch $path
            if ($patch.Changed) {
                $plans.Add([pscustomobject]@{Kind='GaelRequire';WorkshopId=$GaelWorkshopId;Path=$path;Count=$patch.Count;Content=$patch.Content;Source='';Description='Correct GaelGunStore shared/item require path.'}) | Out-Null
            }
        }
    }
}

# Clean the known Merucia server profile when present. Client-only installs
# simply skip this.
$meruciaIni = Join-Path $env:USERPROFILE 'Zomboid\Server\Merucia.ini'
if (Test-Path -LiteralPath $meruciaIni) {
    $raw = [System.IO.File]::ReadAllText($meruciaIni)
    $new = $raw
    $line = [regex]::Match($new,'(?im)^WorkshopItems=[^\r\n]*')
    $replacement = 'WorkshopItems=' + $MeruciaWorkshopItems
    if ($line.Success) {
        if ($line.Value -ne $replacement) {
            $new = $new.Substring(0,$line.Index) + $replacement + $new.Substring($line.Index+$line.Length)
        }
    } else {
        $new = $new.TrimEnd() + "`r`n" + $replacement + "`r`n"
    }
    if ($new -match '(?im)^DoLuaChecksum\s*=') {
        $new = [regex]::Replace($new,'(?im)^DoLuaChecksum\s*=[^\r\n]*','DoLuaChecksum=true')
    } else {
        $new = $new.TrimEnd() + "`r`nDoLuaChecksum=true`r`n"
    }
    if ($new -ne $raw) {
        $plans.Add([pscustomobject]@{Kind='ServerProfile';WorkshopId='';Path=$meruciaIni;Count=1;Content=$new;Source='';Description='Synchronize Merucia WorkshopItems and keep DoLuaChecksum enabled.'}) | Out-Null
    }
}

foreach ($rule in $RuntimeTextPatches) {
    foreach ($mod in Get-ModRootsForWorkshop $rule.WorkshopId) {
        foreach ($root in Get-B42LoadRoots $mod.ModRoot) {
            $path = Join-Path $root $rule.RelativePath
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $raw = [System.IO.File]::ReadAllText($path)
            $matches = [regex]::Matches($raw, $rule.Pattern)
            if ($matches.Count -eq 0) { continue }
            if ($matches.Count -ne 1) {
                Write-Warning ("Skipped ambiguous runtime patch ({0} matches): {1}" -f $matches.Count,$path)
                continue
            }
            $new = [regex]::Replace($raw, $rule.Pattern, [string]$rule.Replacement, 1)
            if ($new -ne $raw) {
                $plans.Add([pscustomobject]@{Kind='RuntimeText';WorkshopId=$rule.WorkshopId;Path=$path;Count=1;Content=$new;Source='';Description=$rule.Description}) | Out-Null
            }
        }
    }
}
foreach ($wid in $ModInfoWorkshopIds) {
    foreach ($mod in Get-ModRootsForWorkshop $wid) {
        foreach ($root in Get-B42LoadRoots $mod.ModRoot) {
            $info = Join-Path $root 'mod.info'
            if (-not (Test-Path -LiteralPath $info)) { continue }
            $patch = Get-ModInfoPatch $info
            if ($patch.Changed) {
                $plans.Add([pscustomobject]@{Kind='ModInfo';WorkshopId=$wid;Path=$info;Count=1;Content=$patch.Content;Source=''}) | Out-Null
            }
        }
    }
}

foreach ($wid in $ItemTypeWorkshopIds) {
    foreach ($mod in Get-ModRootsForWorkshop $wid) {
        foreach ($root in Get-B42LoadRoots $mod.ModRoot) {
            foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.txt' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '[\\/]media[\\/]scripts[\\/]' }) {
                $patch = Get-ItemTypePatch $file.FullName
                if ($patch.Changed) {
                    $plans.Add([pscustomobject]@{Kind='ItemType';WorkshopId=$wid;Path=$file.FullName;Count=$patch.Count;Content=$patch.Content;Source=''}) | Out-Null
                }
            }
        }
    }
}

foreach ($wid in $TranslationWorkshopIds) {
    foreach ($mod in Get-ModRootsForWorkshop $wid) {
        foreach ($root in Get-B42LoadRoots $mod.ModRoot) {
            foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.txt' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '[\\/]media[\\/]lua[\\/]shared[\\/]Translate[\\/]' }) {
                $conv = Get-TranslationConversion $file.FullName
                if ($conv.Ok) {
                    $plans.Add([pscustomobject]@{Kind='Translation';WorkshopId=$wid;Path=$conv.Destination;Count=$conv.PairCount;Content=$conv.Content;Source=$conv.Source}) | Out-Null
                } elseif ($conv.Reason -eq 'Unparsed or empty translation file') {
                    Write-Warning "Skipped complex translation file: $($conv.Source)"
                    foreach ($b in @($conv.BadLines)) { Write-Warning "  $b" }
                }
            }
        }
    }
}

if ($GameInstalls.Count -gt 0) {
    $gameEffects = Join-Path $GameInstalls[0] 'media\effects'
    $gaelMods = @(Get-ModRootsForWorkshop $GaelWorkshopId | Where-Object {
        $_.ItemRoot -like ($PrimaryWorkshopRoots[0] + '*')
    } | Select-Object -First 1)
    if ($gaelMods.Count -eq 0) {
        $gaelMods = @(Get-ModRootsForWorkshop $GaelWorkshopId | Select-Object -First 1)
    }
    foreach ($mod in $gaelMods) {
        foreach ($root in Get-B42LoadRoots $mod.ModRoot) {
            $effects = Join-Path $root 'media\effects'
            if (-not (Test-Path -LiteralPath $effects)) { continue }
            foreach ($src in Get-ChildItem -LiteralPath $effects -File -Filter 'bullet_tracer_effect*ggs*_tracer.txt' -ErrorAction SilentlyContinue) {
                $dst = Join-Path $gameEffects $src.Name
                $needs = $true
                if (Test-Path -LiteralPath $dst) {
                    $needs = ((Get-FileHash -LiteralPath $src.FullName -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash)
                }
                if ($needs) {
                    $plans.Add([pscustomobject]@{Kind='GaelTracer';WorkshopId=$GaelWorkshopId;Path=$dst;Count=1;Content='';Source=$src.FullName}) | Out-Null
                }
            }
        }
    }
}

Write-Status ''
Write-Status "Project Zomboid B42.21 multiplayer compatibility patch - $Mode" Cyan
Write-Status ("Steam libraries: {0}" -f $SteamLibraries.Count)
Write-Status ("Primary Workshop roots: {0}" -f $PrimaryWorkshopRoots.Count)
Write-Status ("Hosted-server Workshop roots: {0}" -f $HostedWorkshopRoots.Count)
Write-Status ("Game installs: {0}" -f $GameInstalls.Count)
if ($HostedWorkshopRoots.Count -eq 0) {
    Write-Status 'Host note: no hosted-server Workshop cache exists yet. If this machine hosts, start the server once so Steam downloads its Workshop cache, stop it, then rerun Apply.' Yellow
} else {
    Write-Status 'Host note: Steam Workshop updates can replace hosted-cache edits. After any Workshop refresh, stop the server and rerun Audit/Apply before players connect.' Yellow
}
Write-Status ("Planned changes: {0}" -f $plans.Count)
$plans | Group-Object Kind | Sort-Object Name | ForEach-Object {
    Write-Status ("  {0,-12} files={1} operations={2}" -f $_.Name,$_.Count,(($_.Group | Measure-Object Count -Sum).Sum))
}

if ($Mode -eq 'Audit') {
    foreach ($p in $plans) { Write-Host ("[{0}] {1}" -f $p.Kind,$p.Path) }
    Write-Status 'Audit complete. No files were changed.' Green
    exit 0
}

if ($plans.Count -eq 0) { Write-Status 'Nothing needs patching.' Green; exit 0 }

foreach ($p in $plans) {
    switch ($p.Kind) {
        'GloveBox' {
            Backup-ForChange $p.Path $p.Kind $true
            [System.IO.File]::WriteAllText($p.Path,[string]$p.Content,$Utf8NoBom)
            Write-Status ("Multiplayer GloveBox fix x{0}: {1}" -f $p.Count,$p.Path) Green
        }
        'GaelRequire' {
            Backup-ForChange $p.Path $p.Kind $true
            [System.IO.File]::WriteAllText($p.Path,[string]$p.Content,$Utf8NoBom)
            Write-Status ("GaelGunStore multiplayer require fix: {0}" -f $p.Path) Green
        }
        'ServerProfile' {
            Backup-ForChange $p.Path $p.Kind $true
            [System.IO.File]::WriteAllText($p.Path,[string]$p.Content,$Utf8NoBom)
            Write-Status ("Server profile WorkshopItems synchronized: {0}" -f $p.Path) Green
        }
        'RuntimeText' {
            Backup-ForChange $p.Path $p.Kind $true
            [System.IO.File]::WriteAllText($p.Path,[string]$p.Content,$Utf8NoBom)
            Write-Status ("Runtime compatibility fix: {0}" -f $p.Description) Green
        }
        'ModInfo' {
            Backup-ForChange $p.Path $p.Kind $true
            [System.IO.File]::WriteAllText($p.Path,[string]$p.Content,$Utf8NoBom)
            Write-Status ("Migrated mod.info version -> modversion: {0}" -f $p.Path) Green
        }
        'ItemType' {
            Backup-ForChange $p.Path $p.Kind $true
            [System.IO.File]::WriteAllText($p.Path, [string]$p.Content, $Utf8NoBom)
            Write-Status ("Patched ItemType x{0}: {1}" -f $p.Count,$p.Path) Green
        }
        'Translation' {
            Backup-ForChange $p.Path $p.Kind (Test-Path -LiteralPath $p.Path)
            [System.IO.File]::WriteAllText($p.Path, [string]$p.Content, $Utf8NoBom)
            Write-Status ("Created B42 JSON ({0} keys): {1}" -f $p.Count,$p.Path) Green
        }
        'GaelTracer' {
            $parent = Split-Path $p.Path -Parent
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            Backup-ForChange $p.Path $p.Kind (Test-Path -LiteralPath $p.Path)
            Copy-Item -LiteralPath $p.Source -Destination $p.Path -Force
            Write-Status ("Installed tracer preset: {0}" -f (Split-Path $p.Path -Leaf)) Green
        }
    }
}

Save-Manifest
Write-Status ''
Write-Status "Patch complete. Backup set: $script:BackupDir" Green
Write-Status 'Run this script again with -Mode Audit to verify no planned changes remain.' Cyan
