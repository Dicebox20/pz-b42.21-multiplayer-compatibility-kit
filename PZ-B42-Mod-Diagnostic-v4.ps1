<#
.SYNOPSIS
  Project Zomboid Build 42 mod compatibility diagnostic.

.DESCRIPTION
  Read-only scanner for Project Zomboid mods. It discovers Steam libraries,
  Workshop mods, local mods, and authoring mods; determines which B42 folder
  would load for TargetVersion; scans metadata and source files for common
  B41 -> B42 and B42 patch migration problems; parses recent console logs; and
  writes CSV/JSON/text reports.

  It does NOT modify Project Zomboid, Workshop content, savegames, or mods.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\PZ-B42-Mod-Diagnostic.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\PZ-B42-Mod-Diagnostic.ps1 -TargetVersion 42.21 -OpenReport
#>

# IMPORTANT: Run this file with PowerShell -File. Do not paste the script body into an interactive >> prompt.
#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$TargetVersion = '42.21',
    [string[]]$AdditionalModRoots = @(),
    [string]$OutputRoot = '',
    [switch]$OpenReport
)

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $OutputRoot = Join-Path $desktop ('PZ-Mod-Diagnostic-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$AppId = '108600'
$script:Findings = [System.Collections.Generic.List[object]]::new()
$script:Mods = [System.Collections.Generic.List[object]]::new()
$script:SeenFiles = @{}

function New-Finding {
    param(
        [string]$Severity,
        [string]$Code,
        [string]$ModId,
        [string]$ModName,
        [string]$Path,
        [string]$File,
        [Nullable[int]]$Line,
        [string]$Message,
        [string]$Recommendation
    )
    $script:Findings.Add([pscustomobject]@{
        Severity       = $Severity
        Code           = $Code
        ModId          = $ModId
        ModName        = $ModName
        Path           = $Path
        File           = $File
        Line           = $Line
        Message        = $Message
        Recommendation = $Recommendation
    }) | Out-Null
}

function Convert-PzVersion {
    param([string]$Version)
    if ([string]::IsNullOrWhiteSpace($Version)) { return $null }
    $m = [regex]::Match($Version.Trim(), '^(?<maj>\d+)(?:\.(?<min>\d+))?(?:\.(?<patch>\d+))?')
    if (-not $m.Success) { return $null }
    $maj = [int]$m.Groups['maj'].Value
    $min = if ($m.Groups['min'].Success) { [int]$m.Groups['min'].Value } else { 0 }
    $patch = if ($m.Groups['patch'].Success) { [int]$m.Groups['patch'].Value } else { 0 }
    [pscustomobject]@{ Major=$maj; Minor=$min; Patch=$patch; Score=($maj * 1000000 + $min * 1000 + $patch); Text=$Version }
}

$Target = Convert-PzVersion $TargetVersion
if (-not $Target) { throw "TargetVersion '$TargetVersion' is not a valid numeric PZ version." }

function Get-IniLikeFile {
    param([string]$Path)
    $h = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $h }
    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue) {
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }
        $i = $line.IndexOf('=')
        if ($i -gt 0) {
            $k = $line.Substring(0,$i).Trim()
            $v = $line.Substring($i+1).Trim()
            $h[$k] = $v
        }
    }
    return $h
}

function Get-SteamRoots {
    $roots = [System.Collections.Generic.List[string]]::new()
    $candidates = @()
    try { $candidates += (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath } catch {}
    try { $candidates += (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction Stop).InstallPath } catch {}
    try { $candidates += (Get-ItemProperty 'HKLM:\SOFTWARE\Valve\Steam' -ErrorAction Stop).InstallPath } catch {}
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Steam') }
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'Steam') }

    foreach ($c in $candidates | Where-Object { $_ } | Select-Object -Unique) {
        if (Test-Path -LiteralPath $c) { $roots.Add((Resolve-Path -LiteralPath $c).Path) | Out-Null }
    }

    $libraries = [System.Collections.Generic.List[string]]::new()
    foreach ($root in $roots) {
        $libraries.Add($root) | Out-Null
        $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($line in Get-Content -LiteralPath $vdf -ErrorAction SilentlyContinue) {
                if ($line -match '"path"\s+"(?<p>.+)"') {
                    $p = $Matches['p'] -replace '\\\\','\'
                    if (Test-Path -LiteralPath $p) { $libraries.Add((Resolve-Path -LiteralPath $p).Path) | Out-Null }
                }
            }
        }
    }
    return @($libraries | Select-Object -Unique)
}

function Get-PzRoots {
    $result = [ordered]@{
        SteamLibraries = @()
        GameInstalls   = @()
        WorkshopRoots = @()
        UserRoot       = (Join-Path $env:USERPROFILE 'Zomboid')
        LocalMods      = (Join-Path $env:USERPROFILE 'Zomboid\mods')
        AuthoringMods  = (Join-Path $env:USERPROFILE 'Zomboid\Workshop')
    }
    $libs = @(Get-SteamRoots)
    $result.SteamLibraries = $libs
    foreach ($lib in $libs) {
        $game = Join-Path $lib 'steamapps\common\ProjectZomboid'
        $workshop = Join-Path $lib "steamapps\workshop\content\$AppId"
        if (Test-Path -LiteralPath $game) { $result.GameInstalls += $game }
        if (Test-Path -LiteralPath $workshop) { $result.WorkshopRoots += $workshop }
    }
    return [pscustomobject]$result
}

function Get-ModListIdsFromText {
    param([string]$Text)
    $ids = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $m = [regex]::Match($Text, '(?ms)\bmods\s*\{(?<body>.*?)\}')
    if (-not $m.Success) { return @() }
    foreach ($line in ($m.Groups['body'].Value -split "`r?`n")) {
        $clean = ($line -replace '[#].*$', '').Trim()
        if (-not $clean) { continue }
        if ($clean -match '^mod\s*=\s*(?<id>.*?)(?:\s*,)?\s*$') {
            $v = $Matches['id'].Trim().Trim('"').Trim("'")
        } else {
            $v = ($clean -replace '[,;]\s*$', '').Trim().Trim('"').Trim("'")
        }
        if ($v) {
            # Build 42 prefixes mod references with a backslash in presets/dependencies.
            # Normalize it away only for comparisons against internal id= values.
            $v = $v.Trim().TrimStart([char]92)
            if ($v) { $ids.Add($v) | Out-Null }
        }
    }
    return @($ids | Select-Object -Unique)
}

function Get-ActiveModReferences {
    param($Roots)
    $r = [ordered]@{
        DefaultFile = (Join-Path $Roots.UserRoot 'mods\default.txt')
        DefaultIds = @()
        SaveIdCounts = @{}
        ServerIdCounts = @{}
        ServerWorkshopCounts = @{}
        SaveFilesScanned = 0
        ServerFilesScanned = 0
    }

    if (Test-Path -LiteralPath $r.DefaultFile) {
        try { $r.DefaultIds = @(Get-ModListIdsFromText (Get-Content -LiteralPath $r.DefaultFile -Raw -ErrorAction Stop)) } catch {}
    }

    $savesRoot = Join-Path $Roots.UserRoot 'Saves'
    if (Test-Path -LiteralPath $savesRoot) {
        foreach ($f in Get-ChildItem -LiteralPath $savesRoot -Filter 'mods.txt' -File -Recurse -ErrorAction SilentlyContinue) {
            $r.SaveFilesScanned++
            try {
                foreach ($id in Get-ModListIdsFromText (Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop)) {
                    $k = $id.ToLowerInvariant()
                    if (-not $r.SaveIdCounts.ContainsKey($k)) { $r.SaveIdCounts[$k] = 0 }
                    $r.SaveIdCounts[$k]++
                }
            } catch {}
        }
    }

    $serverRoot = Join-Path $Roots.UserRoot 'Server'
    if (Test-Path -LiteralPath $serverRoot) {
        foreach ($f in Get-ChildItem -LiteralPath $serverRoot -Filter '*.ini' -File -ErrorAction SilentlyContinue) {
            $r.ServerFilesScanned++
            try {
                foreach ($line in Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue) {
                    if ($line -match '^\s*Mods\s*=\s*(?<v>.*)$') {
                        foreach ($id in ($Matches['v'] -split ';' | ForEach-Object { $_.Trim().TrimStart([char]92) } | Where-Object { $_ })) {
                            $k = $id.ToLowerInvariant()
                            if (-not $r.ServerIdCounts.ContainsKey($k)) { $r.ServerIdCounts[$k] = 0 }
                            $r.ServerIdCounts[$k]++
                        }
                    }
                    elseif ($line -match '^\s*WorkshopItems\s*=\s*(?<v>.*)$') {
                        foreach ($wid in ($Matches['v'] -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
                            if (-not $r.ServerWorkshopCounts.ContainsKey($wid)) { $r.ServerWorkshopCounts[$wid] = 0 }
                            $r.ServerWorkshopCounts[$wid]++
                        }
                    }
                }
            } catch {}
        }
    }
    return [pscustomobject]$r
}

function Get-GameVersionEvidence {
    param($Roots)
    $evidence = [System.Collections.Generic.List[object]]::new()
    foreach ($install in $Roots.GameInstalls) {
        foreach ($exeName in @('ProjectZomboid64.exe','ProjectZomboid32.exe','ProjectZomboid.exe')) {
            $exe = Join-Path $install $exeName
            if (Test-Path -LiteralPath $exe) {
                try {
                    $vi = (Get-Item -LiteralPath $exe).VersionInfo
                    $evidence.Add([pscustomobject]@{Source=$exe; Value=($vi.ProductVersion); Kind='ExecutableProductVersion'}) | Out-Null
                } catch {}
            }
        }
    }
    foreach ($log in @(
        (Join-Path $Roots.UserRoot 'console.txt'),
        (Join-Path $Roots.UserRoot 'coop-console.txt'),
        (Join-Path $Roots.UserRoot 'server-console.txt')
    )) {
        if (Test-Path -LiteralPath $log) {
            $lines = Get-Content -LiteralPath $log -Tail 2000 -ErrorAction SilentlyContinue
            foreach ($line in $lines) {
                if ($line -match '(?i)(?:version|build)[^0-9]{0,20}(?<v>42\.\d+(?:\.\d+)?)') {
                    $evidence.Add([pscustomobject]@{Source=$log; Value=$Matches['v']; Kind='ConsoleVersion'}) | Out-Null
                    break
                }
            }
        }
    }
    return $evidence.ToArray()
}

function Get-ModContainers {
    param($Roots)
    $items = [System.Collections.Generic.List[object]]::new()

    foreach ($wr in $Roots.WorkshopRoots) {
        if (-not (Test-Path -LiteralPath $wr)) { continue }
        foreach ($wid in Get-ChildItem -LiteralPath $wr -Directory -ErrorAction SilentlyContinue) {
            $modsDir = Join-Path $wid.FullName 'mods'
            if (Test-Path -LiteralPath $modsDir) {
                foreach ($m in Get-ChildItem -LiteralPath $modsDir -Directory -ErrorAction SilentlyContinue) {
                    $items.Add([pscustomobject]@{Source='Workshop'; WorkshopId=$wid.Name; Root=$m.FullName}) | Out-Null
                }
            }
        }
    }

    if (Test-Path -LiteralPath $Roots.LocalMods) {
        foreach ($m in Get-ChildItem -LiteralPath $Roots.LocalMods -Directory -ErrorAction SilentlyContinue) {
            $items.Add([pscustomobject]@{Source='Local'; WorkshopId=''; Root=$m.FullName}) | Out-Null
        }
    }

    if (Test-Path -LiteralPath $Roots.AuthoringMods) {
        foreach ($modsDir in Get-ChildItem -LiteralPath $Roots.AuthoringMods -Directory -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '[\\/]Contents[\\/]mods$' }) {
            foreach ($m in Get-ChildItem -LiteralPath $modsDir.FullName -Directory -ErrorAction SilentlyContinue) {
                $items.Add([pscustomobject]@{Source='Authoring'; WorkshopId=''; Root=$m.FullName}) | Out-Null
            }
        }
    }

    foreach ($extra in $AdditionalModRoots) {
        if (Test-Path -LiteralPath $extra) {
            $resolved = (Resolve-Path -LiteralPath $extra).Path
            $items.Add([pscustomobject]@{Source='Additional'; WorkshopId=''; Root=$resolved}) | Out-Null
        }
    }

    return @($items | Sort-Object Root -Unique)
}

function Get-LoadLayout {
    param([string]$ModRoot)
    $common = Join-Path $ModRoot 'common'
    $rootInfo = Join-Path $ModRoot 'mod.info'
    $rootMedia = Join-Path $ModRoot 'media'
    $versions = [System.Collections.Generic.List[object]]::new()

    foreach ($d in Get-ChildItem -LiteralPath $ModRoot -Directory -ErrorAction SilentlyContinue) {
        $v = Convert-PzVersion $d.Name
        if ($v -and $v.Major -ge 42 -and $v.Score -le $Target.Score) {
            $versions.Add([pscustomobject]@{Path=$d.FullName; Name=$d.Name; Version=$v; HasInfo=(Test-Path -LiteralPath (Join-Path $d.FullName 'mod.info'))}) | Out-Null
        }
    }

    $best = $versions | Sort-Object { $_.Version.Score } -Descending | Select-Object -First 1
    $commonInfo = Join-Path $common 'mod.info'
    $selectedInfo = $null
    if ($best -and $best.HasInfo) { $selectedInfo = Join-Path $best.Path 'mod.info' }
    elseif (Test-Path -LiteralPath $commonInfo) { $selectedInfo = $commonInfo }

    [pscustomobject]@{
        RootInfo       = (Test-Path -LiteralPath $rootInfo)
        RootMedia      = (Test-Path -LiteralPath $rootMedia)
        CommonDir      = (Test-Path -LiteralPath $common)
        CommonInfo     = (Test-Path -LiteralPath $commonInfo)
        VersionDirs    = $versions.ToArray()
        Selected       = $best
        SelectedInfo   = $selectedInfo
        IsLoadableB42  = [bool]$selectedInfo
    }
}

function Get-TextFiles {
    param([string[]]$Roots)
    $ext = @('.lua','.txt','.json','.xml','.ini','.cfg')
    $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($r in $Roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) }) {
        foreach ($f in Get-ChildItem -LiteralPath $r -File -Recurse -ErrorAction SilentlyContinue) {
            if ($ext -contains $f.Extension.ToLowerInvariant() -and $f.Length -le 8MB) { $files.Add($f) | Out-Null }
        }
    }
    return @($files | Sort-Object FullName -Unique)
}

function Scan-Regex {
    param(
        [System.IO.FileInfo[]]$Files,
        [string]$Pattern,
        [string]$Severity,
        [string]$Code,
        [string]$ModId,
        [string]$ModName,
        [string]$ModRoot,
        [string]$Message,
        [string]$Recommendation
    )
    foreach ($f in $Files) {
        try {
            foreach ($m in Select-String -LiteralPath $f.FullName -Pattern $Pattern -AllMatches -ErrorAction SilentlyContinue) {
                New-Finding $Severity $Code $ModId $ModName $ModRoot $f.FullName $m.LineNumber ($Message + '  Match: ' + $m.Line.Trim()) $Recommendation
            }
        } catch {}
    }
}

function Scan-LegacyItemTypes {
    param(
        [System.IO.FileInfo[]]$Files,
        [string]$ModId,
        [string]$ModName,
        [string]$ModRoot
    )
    foreach ($f in $Files) {
        try {
            $raw = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop
            $items = [regex]::Matches($raw, '(?ms)^\s*item\s+(?<name>[^\s\{]+)\s*(?:\r?\n\s*)?\{(?<body>.*?)(?=^\s*\})')
            foreach ($item in $items) {
                $body = $item.Groups['body'].Value
                if ($body -match '(?im)^\s*ItemType\s*=') { continue }
                $tm = [regex]::Match($body, '(?im)^\s*Type\s*=\s*(?<value>[^,\r\n]+)')
                if (-not $tm.Success) { continue }
                $prefixLen = $item.Groups['body'].Index + $tm.Index
                $lineNo = ([regex]::Matches($raw.Substring(0,$prefixLen), "`n")).Count + 1
                $itemName = $item.Groups['name'].Value
                New-Finding 'HIGH' 'LEGACY_ITEM_TYPE_ONLY' $ModId $ModName $ModRoot $f.FullName $lineNo ("Item '$itemName' uses Type=$($tm.Groups['value'].Value.Trim()) but has no ItemType field.") 'Add the appropriate namespaced ItemType (for example base:normal) after comparing the item with the current B42.21 vanilla schema. Keep Type only if the mod still needs it for its own compatibility logic.'
            }
        } catch {}
    }
}

function Test-Mod {
    param($Container)
    $layout = Get-LoadLayout $Container.Root
    $meta = [ordered]@{}
    if ($layout.SelectedInfo) { $meta = Get-IniLikeFile $layout.SelectedInfo }
    elseif ($layout.RootInfo) { $meta = Get-IniLikeFile (Join-Path $Container.Root 'mod.info') }

    $modId = if ($meta.Contains('id')) { [string]$meta['id'] } else { Split-Path $Container.Root -Leaf }
    $modName = if ($meta.Contains('name')) { [string]$meta['name'] } else { Split-Path $Container.Root -Leaf }

    $scanRoots = [System.Collections.Generic.List[string]]::new()
    if ($layout.CommonDir) { $scanRoots.Add((Join-Path $Container.Root 'common')) | Out-Null }
    if ($layout.Selected) { $scanRoots.Add($layout.Selected.Path) | Out-Null }
    if (-not $layout.IsLoadableB42) { $scanRoots.Add($Container.Root) | Out-Null }
    $files = @(Get-TextFiles @($scanRoots))

    $versionFolder = if ($layout.Selected) { $layout.Selected.Name } else { '' }
    $script:Mods.Add([pscustomobject]@{
        ModId          = $modId
        Name           = $modName
        Source         = $Container.Source
        WorkshopId     = $Container.WorkshopId
        Root           = $Container.Root
        B42Loadable    = $layout.IsLoadableB42
        SelectedFolder = $versionFolder
        ModInfo        = $layout.SelectedInfo
        FileCount      = $files.Count
        Require        = if ($meta.Contains('require')) { [string]$meta['require'] } else { '' }
        Incompatible   = if ($meta.Contains('incompatible')) { [string]$meta['incompatible'] } else { '' }
        VersionMin     = if ($meta.Contains('versionMin')) { [string]$meta['versionMin'] } else { '' }
        VersionMax     = if ($meta.Contains('versionMax')) { [string]$meta['versionMax'] } else { '' }
        ActiveDefault  = [bool]($script:Active.DefaultIds -contains $modId)
        SaveReferences = if ($script:Active.SaveIdCounts.ContainsKey($modId.ToLowerInvariant())) { [int]$script:Active.SaveIdCounts[$modId.ToLowerInvariant()] } else { 0 }
        ServerReferences = if ($script:Active.ServerIdCounts.ContainsKey($modId.ToLowerInvariant())) { [int]$script:Active.ServerIdCounts[$modId.ToLowerInvariant()] } else { 0 }
        ServerWorkshopReferences = if ($Container.WorkshopId -and $script:Active.ServerWorkshopCounts.ContainsKey([string]$Container.WorkshopId)) { [int]$script:Active.ServerWorkshopCounts[[string]$Container.WorkshopId] } else { 0 }
    }) | Out-Null

    if (-not $layout.IsLoadableB42) {
        if ($layout.RootInfo -or $layout.RootMedia) {
            New-Finding 'CRITICAL' 'B41_ROOT_ONLY' $modId $modName $Container.Root '' $null 'This mod has B41-style root content but no B42-loadable common/version mod.info.' 'Create common/ and/or a compatible 42 or 42.21 version folder with mod.info; migrate B42 code instead of merely moving files.'
        } else {
            New-Finding 'CRITICAL' 'NO_B42_MODINFO' $modId $modName $Container.Root '' $null 'No B42-compatible mod.info was found for the target build.' 'Add common/mod.info or a version folder <= the target build containing mod.info.'
        }
    }

    $futureDirs = @()
    foreach ($d in Get-ChildItem -LiteralPath $Container.Root -Directory -ErrorAction SilentlyContinue) {
        $v = Convert-PzVersion $d.Name
        if ($v -and $v.Major -ge 42 -and $v.Score -gt $Target.Score) { $futureDirs += $d.Name }
    }
    if ($futureDirs.Count -gt 0 -and -not $layout.IsLoadableB42) {
        New-Finding 'CRITICAL' 'VERSION_FOLDER_TOO_NEW' $modId $modName $Container.Root '' $null ("Only newer B42 version folders were found: " + ($futureDirs -join ', ')) 'Provide common/ or a 42.x folder whose version is not newer than the installed game.'
    }

    if ($layout.SelectedInfo) {
        if (-not $meta.Contains('id') -or [string]::IsNullOrWhiteSpace([string]$meta['id'])) {
            New-Finding 'HIGH' 'MODINFO_MISSING_ID' $modId $modName $Container.Root $layout.SelectedInfo $null 'mod.info has no id= value.' 'Add a stable, unique id= value.'
        }
        if (-not $meta.Contains('name') -or [string]::IsNullOrWhiteSpace([string]$meta['name'])) {
            New-Finding 'MEDIUM' 'MODINFO_MISSING_NAME' $modId $modName $Container.Root $layout.SelectedInfo $null 'mod.info has no name= value.' 'Add name= for clear mod-manager identification.'
        }
        foreach ($legacy in @('version','minVersion','maxVersion')) {
            if ($meta.Contains($legacy)) {
                New-Finding 'HIGH' 'LEGACY_MODINFO_FIELD' $modId $modName $Container.Root $layout.SelectedInfo $null ("Legacy mod.info field '$legacy' is present.") 'Use B42 metadata fields such as modversion, versionMin, and versionMax as appropriate.'
            }
        }
        if ($meta.Contains('versionMin')) {
            $vmin = Convert-PzVersion ([string]$meta['versionMin'])
            if ($vmin -and $vmin.Score -gt $Target.Score) {
                New-Finding 'CRITICAL' 'VERSION_MIN_TOO_NEW' $modId $modName $Container.Root $layout.SelectedInfo $null ("versionMin=$($meta['versionMin']) is newer than target $TargetVersion.") 'Lower versionMin only if the mod actually works on the target build, otherwise build a target-specific compatibility folder.'
            }
        }
        if ($meta.Contains('versionMax')) {
            $vmax = Convert-PzVersion ([string]$meta['versionMax'])
            if ($vmax -and $vmax.Score -lt $Target.Score) {
                New-Finding 'CRITICAL' 'VERSION_MAX_TOO_OLD' $modId $modName $Container.Root $layout.SelectedInfo $null ("versionMax=$($meta['versionMax']) excludes target $TargetVersion.") 'Update versionMax after testing compatibility.'
            }
        }
        if ($meta.Contains('pzversion') -and ([string]$meta['pzversion']) -match '^41') {
            New-Finding 'HIGH' 'B41_PZVERSION' $modId $modName $Container.Root $layout.SelectedInfo $null ("pzversion=$($meta['pzversion']) still targets B41.") 'Review metadata and B42 code migration.'
        }
    }

    $scriptFiles = @($files | Where-Object { $_.FullName -match '[\\/]media[\\/](scripts|lua)[\\/]' -or $_.Name -eq 'registries.lua' })
    $translateFiles = @($files | Where-Object { $_.FullName -match '[\\/]Translate[\\/]' })
    $registries = @($files | Where-Object { $_.Name -ieq 'registries.lua' -and $_.FullName -match '[\\/]media[\\/]registries\.lua$' })

    # B42 recipe and item-script migration.
    Scan-Regex $scriptFiles '(?im)^\s*recipe\s+[A-Za-z0-9_]+\s*\{' 'HIGH' 'LEGACY_RECIPE_BLOCK' $modId $modName $Container.Root 'Legacy recipe { } syntax detected.' 'Convert to B42 craftRecipe syntax and verify inputs/outputs semantics.'
    Scan-LegacyItemTypes ($scriptFiles | Where-Object { $_.FullName -match '[\\/]media[\\/]scripts[\\/]' }) $modId $modName $Container.Root

    # 42.13 registry system. Heuristic: definitions/API names that commonly require registration.
    $registryNeedPattern = '(?i)\b(CharacterTrait|CharacterProfession|ItemTag|ItemType|ItemBodyLocation|MoodleType|WeaponCategory|Flier|Brochure|Newspaper|AmmoType)\b|(?im)^\s*(trait|profession)\s+[A-Za-z0-9_]+'
    $needsRegistry = $false
    foreach ($f in $scriptFiles) {
        try { if (Select-String -LiteralPath $f.FullName -Pattern $registryNeedPattern -Quiet -ErrorAction SilentlyContinue) { $needsRegistry = $true; break } } catch {}
    }
    if ($needsRegistry -and $registries.Count -eq 0) {
        New-Finding 'REVIEW' 'REGISTRY_FILE_REVIEW' $modId $modName $Container.Root '' $null 'Registry-backed identifiers are referenced, but no media/registries.lua was found. This is not automatically an error because the mod may only consume base or dependency registrations.' 'Review only if the mod defines new registry-backed IDs. For custom IDs on 42.13+, register them early and use a mod namespace such as modid:name.'
    }
    foreach ($rf in $registries) {
        try {
            foreach ($m in Select-String -LiteralPath $rf.FullName -Pattern '(?i)\.register\(\s*["''](?<id>[^"'']+)["'']\s*\)' -AllMatches -ErrorAction SilentlyContinue) {
                foreach ($mm in $m.Matches) {
                    $id = $mm.Groups['id'].Value
                    if ($id -notmatch ':') {
                        New-Finding 'HIGH' 'UNNAMESPACED_REGISTRY_ID' $modId $modName $Container.Root $rf.FullName $m.LineNumber ("Registry ID '$id' is not namespaced.") 'Use modid:name (for example MyMod:MyTrait) and update all references to the same namespaced ID.'
                    }
                }
            }
        } catch {}
    }

    # 42.15 translation migration.
    foreach ($tf in $translateFiles | Where-Object { $_.Extension -ieq '.txt' }) {
        $lang = Split-Path $tf.DirectoryName -Leaf
        $oldBase = [System.IO.Path]::GetFileNameWithoutExtension($tf.Name)
        $newBase = $oldBase -replace ('_' + [regex]::Escape($lang) + '$'), ''
        $jsonPeer = Join-Path $tf.DirectoryName ($newBase + '.json')
        if (Test-Path -LiteralPath $jsonPeer) {
            New-Finding 'INFO' 'LEGACY_TRANSLATION_TXT_REDUNDANT' $modId $modName $Container.Root $tf.FullName $null 'Legacy translation TXT remains, but a matching B42.15 JSON category exists.' 'No automatic repair is needed for 42.21. Keep/remove the TXT only according to the author''s backwards-compatibility plan.'
        } else {
            New-Finding 'HIGH' 'LEGACY_TRANSLATION_TXT_ONLY' $modId $modName $Container.Root $tf.FullName $null ("Legacy translation TXT has no matching B42.15 JSON category ($($newBase).json).") 'Migrate this translation category to UTF-8 JSON using the current B42 category/key conventions.'
        }
    }
    foreach ($jf in $translateFiles | Where-Object { $_.Extension -ieq '.json' }) {
        try {
            $raw = Get-Content -LiteralPath $jf.FullName -Raw -ErrorAction Stop
            $null = $raw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $msg = $_.Exception.Message
            if ($msg -match "duplicated keys '([^']+)' and '([^']+)'") {
                $a = $Matches[1]; $b = $Matches[2]
                if ($a -cne $b -and $a.ToLowerInvariant() -eq $b.ToLowerInvariant()) {
                    New-Finding 'INFO' 'JSON_CASE_COLLISION_PS51' $modId $modName $Container.Root $jf.FullName $null ("PowerShell 5.1 cannot represent case-distinct JSON keys '$a' and '$b'; this alone does not prove the PZ JSON is invalid.") 'Do not rewrite solely for this scanner warning. Validate against the game/runtime or a case-sensitive JSON parser.'
                    continue
                }
            }
            New-Finding 'HIGH' 'INVALID_TRANSLATION_JSON' $modId $modName $Container.Root $jf.FullName $null ('Invalid JSON: ' + $msg) 'Fix JSON syntax/encoding. Prefer UTF-8 and current B42 JSON translation structure.'
        }
    }

    # MP/server-authority heuristic. Not automatically wrong, but worth inspection.
    foreach ($cf in $files | Where-Object { $_.FullName -match '[\\/]media[\\/]lua[\\/]client[\\/]' }) {
        try {
            foreach ($m in Select-String -LiteralPath $cf.FullName -Pattern '(?i)\b(InventoryItemFactory\.CreateItem|instanceItem|getScriptManager\(\).*FindItem|AddItem\s*\()' -AllMatches -ErrorAction SilentlyContinue) {
                New-Finding 'MEDIUM' 'CLIENT_ITEM_CREATION_REVIEW' $modId $modName $Container.Root $cf.FullName $m.LineNumber 'Client-side code appears to create/add inventory items; B42 MP is more server-authoritative.' 'Verify this path sends a command to the server and creates authoritative inventory state server-side.'
            }
        } catch {}
    }

    # loadstring/loadstream are allowed again in current stable, but flag as informational security-sensitive code.
    Scan-Regex $scriptFiles '(?i)\b(loadstring|loadstream)\s*\(' 'INFO' 'DYNAMIC_CODE_LOAD' $modId $modName $Container.Root 'Dynamic Lua loading detected. These calls were temporarily disabled in 42.20.4 and re-enabled in 42.21.' 'No 42.21 compatibility change is required solely for this, but review remote-code use carefully for MP/security.'

    # Java/native injections require manual verification across patches.
    foreach ($bin in Get-ChildItem -LiteralPath $Container.Root -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.jar','.class','.dll') }) {
        New-Finding 'MEDIUM' 'BINARY_CODE_REVIEW' $modId $modName $Container.Root $bin.FullName $null 'Binary/Java/native code detected.' 'Manually verify against the current B42 Java/API/security changes; static Lua/script checks cannot prove compatibility.'
    }
}

function Analyze-ActiveReferences {
    $installed = @{}
    foreach ($m in $script:Mods) { if ($m.ModId) { $installed[$m.ModId.ToLowerInvariant()] = $true } }

    foreach ($id in $script:Active.DefaultIds) {
        if (-not $installed.ContainsKey($id.ToLowerInvariant())) {
            New-Finding 'CRITICAL' 'ACTIVE_DEFAULT_MOD_MISSING' $id $id $script:Active.DefaultFile $script:Active.DefaultFile $null "default.txt enables '$id', but no installed mod with that internal id was found." 'Install the missing mod or update the default preset to the mod''s current internal id.'
        }
    }
    foreach ($k in $script:Active.SaveIdCounts.Keys) {
        if (-not $installed.ContainsKey($k)) {
            New-Finding 'HIGH' 'SAVE_MOD_MISSING' $k $k (Join-Path $env:USERPROFILE 'Zomboid\Saves') '' $null ("One or more saves reference missing mod id '$k' (references: $($script:Active.SaveIdCounts[$k])).") 'Do not load/convert those saves until the required mod is restored or a deliberate save-migration plan is made.'
        }
    }
    foreach ($k in $script:Active.ServerIdCounts.Keys) {
        if (-not $installed.ContainsKey($k)) {
            New-Finding 'CRITICAL' 'SERVER_MOD_MISSING' $k $k (Join-Path $env:USERPROFILE 'Zomboid\Server') '' $null ("Server config references missing mod id '$k' (references: $($script:Active.ServerIdCounts[$k])).") 'Install the mod and ensure Mods= uses its exact current internal id.'
        }
    }
}

function Analyze-Dependencies {
    $idGroups = $script:Mods | Where-Object { $_.ModId } | Group-Object ModId
    foreach ($g in $idGroups | Where-Object { $_.Count -gt 1 }) {
        $paths = ($g.Group.Root -join ' | ')
        foreach ($m in $g.Group) {
            New-Finding 'HIGH' 'DUPLICATE_MOD_ID' $m.ModId $m.Name $m.Root $m.ModInfo $null ("Duplicate mod id '$($m.ModId)' is installed in multiple locations: $paths") 'Remove/stage duplicate copies or give distinct mods unique IDs. Duplicate IDs can make dependency/load-order behavior ambiguous.'
        }
    }
    $installed = @{}
    foreach ($m in $script:Mods) { if ($m.ModId) { $installed[$m.ModId.ToLowerInvariant()] = $true } }
    foreach ($m in $script:Mods) {
        if ($m.Require) {
            foreach ($req in ($m.Require -split '[,;]' | ForEach-Object { $_.Trim().TrimStart([char]92) } | Where-Object { $_ })) {
                if (-not $installed.ContainsKey($req.ToLowerInvariant()) -and $req -notin @('Base')) {
                    New-Finding 'HIGH' 'MISSING_DEPENDENCY' $m.ModId $m.Name $m.Root $m.ModInfo $null ("Required mod '$req' was not found among scanned mods.") 'Install/enable the dependency or update require= if the dependency ID changed in B42.'
                }
            }
        }
        if ($m.Incompatible) {
            foreach ($bad in ($m.Incompatible -split '[,;]' | ForEach-Object { $_.Trim().TrimStart([char]92) } | Where-Object { $_ })) {
                if ($installed.ContainsKey($bad.ToLowerInvariant())) {
                    New-Finding 'MEDIUM' 'INSTALLED_INCOMPATIBLE_MOD' $m.ModId $m.Name $m.Root $m.ModInfo $null ("Declared incompatible mod '$bad' is also installed.") 'Do not enable both in the same preset unless the incompatibility declaration is obsolete and has been retested.'
                }
            }
        }
    }
}

function Analyze-ConsoleLogs {
    param($Roots)
    $logs = @(
        (Join-Path $Roots.UserRoot 'console.txt'),
        (Join-Path $Roots.UserRoot 'coop-console.txt'),
        (Join-Path $Roots.UserRoot 'server-console.txt')
    ) | Where-Object { Test-Path -LiteralPath $_ }

    foreach ($log in $logs) {
        $tail = Get-Content -LiteralPath $log -Tail 12000 -ErrorAction SilentlyContinue
        $n = 0
        foreach ($line in $tail) {
            $n++
            if ($line -match '(?i)(Exception|ERROR:|stack traceback|dumping Lua stack trace|MOD:)') {
                New-Finding 'RUNTIME' 'CONSOLE_ERROR' '' '' '' $log $n $line.Trim() 'Correlate this runtime error with the mod/path named in adjacent console lines; reproduce on a fresh test save with a minimal mod set.'
            }
        }
    }
}

$Roots = Get-PzRoots
$script:Active = Get-ActiveModReferences $Roots
$GameEvidence = @(Get-GameVersionEvidence $Roots)
$Containers = @(Get-ModContainers $Roots)

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null

foreach ($c in $Containers) {
    try { Test-Mod $c }
    catch {
        New-Finding 'SCAN' 'SCAN_FAILURE' '' (Split-Path $c.Root -Leaf) $c.Root '' $null $_.Exception.Message 'Inspect this mod manually; scanner could not complete all checks for it.'
    }
}
Analyze-Dependencies
Analyze-ActiveReferences
Analyze-ConsoleLogs $Roots

# Deduplicate identical findings.
$dedup = $script:Findings | Sort-Object Severity,Code,ModId,File,Line,Message -Unique
$modsSorted = $script:Mods | Sort-Object Name,ModId,Root -Unique

$modsCsv = Join-Path $OutputRoot 'mods.csv'
$findingsCsv = Join-Path $OutputRoot 'findings.csv'
$jsonFile = Join-Path $OutputRoot 'diagnostic.json'
$summaryFile = Join-Path $OutputRoot 'SUMMARY.txt'

$modsSorted | Export-Csv -LiteralPath $modsCsv -NoTypeInformation -Encoding UTF8
$dedup | Export-Csv -LiteralPath $findingsCsv -NoTypeInformation -Encoding UTF8

$payload = [ordered]@{
    GeneratedAt     = (Get-Date).ToString('o')
    TargetVersion   = $TargetVersion
    Roots           = $Roots
    GameVersionEvidence = $GameEvidence
    ActiveReferences = $script:Active
    ModCount        = @($modsSorted).Count
    FindingCount    = @($dedup).Count
    SeverityCounts  = @($dedup | Group-Object Severity | Sort-Object Name | ForEach-Object { [pscustomobject]@{Severity=$_.Name; Count=$_.Count} })
    Mods            = @($modsSorted)
    Findings        = @($dedup)
}
$payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonFile -Encoding UTF8

$critical = @($dedup | Where-Object { $_.Severity -eq 'CRITICAL' }).Count
$high = @($dedup | Where-Object { $_.Severity -eq 'HIGH' }).Count
$medium = @($dedup | Where-Object { $_.Severity -eq 'MEDIUM' }).Count
$runtime = @($dedup | Where-Object { $_.Severity -eq 'RUNTIME' }).Count

$summary = [System.Collections.Generic.List[string]]::new()
$summary.Add('Project Zomboid Build 42 Mod Diagnostic') | Out-Null
$summary.Add(('Generated: ' + (Get-Date))) | Out-Null
$summary.Add(('Target stable/build: ' + $TargetVersion)) | Out-Null
$summary.Add('') | Out-Null
$summary.Add(('Scanned mods: ' + @($modsSorted).Count)) | Out-Null
$summary.Add(('Default enabled mods: ' + @($script:Active.DefaultIds).Count)) | Out-Null
$summary.Add(('Save mod-list files scanned: ' + $script:Active.SaveFilesScanned)) | Out-Null
$summary.Add(('Server config files scanned: ' + $script:Active.ServerFilesScanned)) | Out-Null
$summary.Add(("Findings: {0} critical, {1} high, {2} medium, {3} runtime-log entries" -f $critical,$high,$medium,$runtime)) | Out-Null
$summary.Add('') | Out-Null
$summary.Add('Game version evidence:') | Out-Null
if ($GameEvidence.Count -eq 0) { $summary.Add('  (none found; target version was supplied to the scanner)') | Out-Null }
foreach ($e in $GameEvidence) { $summary.Add(("  {0}: {1} ({2})" -f $e.Kind,$e.Value,$e.Source)) | Out-Null }
$summary.Add('') | Out-Null
$summary.Add('Top actionable findings:') | Out-Null
foreach ($f in $dedup | Where-Object { $_.Severity -in @('CRITICAL','HIGH','MEDIUM') } | Select-Object -First 80) {
    $where = if ($f.ModName) { $f.ModName } elseif ($f.File) { $f.File } else { $f.Path }
    $summary.Add(("  [{0}] {1} - {2}: {3}" -f $f.Severity,$f.Code,$where,$f.Message)) | Out-Null
    if ($f.Recommendation) { $summary.Add(('      -> ' + $f.Recommendation)) | Out-Null }
}
$summary.Add('') | Out-Null
$summary.Add('Files:') | Out-Null
$summary.Add('  mods.csv       - discovered mod inventory and selected B42 folder') | Out-Null
$summary.Add('  findings.csv   - all compatibility/runtime findings') | Out-Null
$summary.Add('  diagnostic.json- machine-readable report for automated repair planning') | Out-Null
$summary.Add('  SUMMARY.txt    - this report') | Out-Null
$summary | Set-Content -LiteralPath $summaryFile -Encoding UTF8

Write-Host ''
Write-Host 'Project Zomboid mod diagnostic complete.' -ForegroundColor Green
Write-Host ("Target: {0}" -f $TargetVersion)
Write-Host ("Mods: {0}" -f @($modsSorted).Count)
Write-Host ("Critical: {0}  High: {1}  Medium: {2}  Runtime entries: {3}" -f $critical,$high,$medium,$runtime)
Write-Host ("Report: {0}" -f $summaryFile)

if ($OpenReport) { Start-Process notepad.exe -ArgumentList ('"' + $summaryFile + '"') }
