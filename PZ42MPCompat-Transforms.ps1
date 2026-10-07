$ErrorActionPreference = 'Stop'

function Normalize-PZCompatText([string]$Text) {
    if ($null -eq $Text) { return '' }
    return $Text.Replace("`r`n","`n").Replace("`r","`n")
}

function Replace-PZCompatRequired(
    [string]$Text,
    [string]$Old,
    [string]$New,
    [string]$Label
) {
    $oldN = Normalize-PZCompatText $Old
    $newN = Normalize-PZCompatText $New
    if (!$Text.Contains($oldN)) {
        throw "PZ42MPCompat transform marker missing: $Label"
    }
    return $Text.Replace($oldN,$newN)
}

function Convert-PZ42MPCompatContent(
    [string]$Relative,
    [string]$Content
) {
    $rel = $Relative.Replace('/','\').ToLowerInvariant()
    $isTarget = $rel -in @(
        'media\lua\shared\ggs_dynamicammo.lua',
        'media\lua\shared\ggs_manualrackoption.lua',
        'media\lua\shared\ggs_reloadanimcompat.lua',
        'media\lua\client\mymulticlaim_client.lua'
    )
    if (!$isTarget) { return $Content }

    $t = Normalize-PZCompatText $Content

    switch ($rel) {
        'media\lua\shared\ggs_dynamicammo.lua' {
            $t = Replace-PZCompatRequired $t @'
require("ISUI/ISInventoryPaneContextMenu")
'@ '' 'GGS_DynamicAmmo early inventory-context require'

            $t = Replace-PZCompatRequired $t @'
_G.GGS_DynamicAmmo = M

'@ @'
_G.GGS_DynamicAmmo = M

-- B42.21: this shared file is parsed before the client UI tree is available.
-- Defer the client-only inventory context import until the client boot events.
local function ensureDynamicAmmoClientUI()
    if isServer and isServer() then
        return
    end
    if not ISInventoryPaneContextMenu then
        require("ISUI/ISInventoryPaneContextMenu")
    end
end

if Events and Events.OnGameBoot and Events.OnGameBoot.Add then
    Events.OnGameBoot.Add(ensureDynamicAmmoClientUI)
end
if Events and Events.OnGameStart and Events.OnGameStart.Add then
    Events.OnGameStart.Add(ensureDynamicAmmoClientUI)
end

'@ 'GGS_DynamicAmmo deferred client import'
        }

        'media\lua\shared\ggs_manualrackoption.lua' {
            $t = Replace-PZCompatRequired $t @'
require "TimedActions/ISReloadWeaponAction"
require("TimedActions/ISTimedActionQueue")
require("TimedActions/ISRackFirearm")
'@ @'
require "TimedActions/ISReloadWeaponAction"
require("TimedActions/ISRackFirearm")
'@ 'GGS_ManualRackOption early queue require'

            $t = Replace-PZCompatRequired $t @'
local function applyManualRackPatches()
    if not ISReloadWeaponAction then
        require("TimedActions/ISReloadWeaponAction")
    end
    if not ISTimedActionQueue then
        require("TimedActions/ISTimedActionQueue")
    end
    if not ISRackFirearm then
        require("TimedActions/ISRackFirearm")
    end
    patchReloadAction()
    patchTimedActionQueue()
    patchRackValidity()
end

applyManualRackPatches()
'@ @'
local function applyManualRackPatches()
    local serverSide = isServer and isServer()

    if not ISReloadWeaponAction then
        require("TimedActions/ISReloadWeaponAction")
    end
    if not serverSide and not ISTimedActionQueue then
        require("TimedActions/ISTimedActionQueue")
    end
    if not ISRackFirearm then
        require("TimedActions/ISRackFirearm")
    end

    patchReloadAction()
    if not serverSide then
        patchTimedActionQueue()
    end
    patchRackValidity()
end

-- The client queue class is not available while shared Lua is first parsed.
-- Server-safe portions can be applied immediately; client hooks are applied
-- by OnGameBoot/OnGameStart below.
if isServer and isServer() then
    applyManualRackPatches()
end
'@ 'GGS_ManualRackOption late client patch'
        }

        'media\lua\shared\ggs_reloadanimcompat.lua' {
            $t = Replace-PZCompatRequired $t @'
if not (isServer and isServer()) then
    require("PartAbility/Stool/GrenadeLauncher_SetFunction")
    compatLog("GL click module required")
end

'@ @'
-- B42.21: this helper is present in GaelGunStore's client tree, but shared Lua
-- is parsed before client-only modules can be required. Load it after client boot.
local function ensureGrenadeLauncherClientModule()
    if isServer and isServer() then
        return
    end
    if _G.__ggsGrenadeLauncherClickModuleLoaded then
        return
    end
    require("PartAbility/Stool/GrenadeLauncher_SetFunction")
    _G.__ggsGrenadeLauncherClickModuleLoaded = true
    compatLog("GL click module required after client boot")
end

'@ 'GGS_ReloadAnimCompat deferred grenade helper'

            $t = Replace-PZCompatRequired $t @'
if Events and Events.OnGameBoot and Events.OnGameBoot.Add then
    Events.OnGameBoot.Add(applyReloadAnimCompatibilityPatches)
    Events.OnGameBoot.Add(registerReloadCompatEvents)
end

if Events and Events.OnGameStart and Events.OnGameStart.Add then
    Events.OnGameStart.Add(applyReloadAnimCompatibilityPatches)
    Events.OnGameStart.Add(registerReloadCompatEvents)
end
'@ @'
if Events and Events.OnGameBoot and Events.OnGameBoot.Add then
    Events.OnGameBoot.Add(ensureGrenadeLauncherClientModule)
    Events.OnGameBoot.Add(applyReloadAnimCompatibilityPatches)
    Events.OnGameBoot.Add(registerReloadCompatEvents)
end

if Events and Events.OnGameStart and Events.OnGameStart.Add then
    Events.OnGameStart.Add(ensureGrenadeLauncherClientModule)
    Events.OnGameStart.Add(applyReloadAnimCompatibilityPatches)
    Events.OnGameStart.Add(registerReloadCompatEvents)
end
'@ 'GGS_ReloadAnimCompat boot ordering'
        }

        'media\lua\client\mymulticlaim_client.lua' {
            $t = Replace-PZCompatRequired $t @'
require "ISUI/ISSafehouseUI"
'@ @'
require "ISUI/UserPanel/ISSafehouseUI"
'@ 'MultipleSafehouse ISSafehouseUI path'

            $t = Replace-PZCompatRequired $t @'
require "ISUI/ISUserPanelUI"
'@ @'
require "ISUI/UserPanel/ISUserPanelUI"
'@ 'MultipleSafehouse ISUserPanelUI path'

            $t = Replace-PZCompatRequired $t @'
require "ISUI/HaloTextHelper" 
'@ '' 'MultipleSafehouse obsolete HaloTextHelper Lua require'
        }
    }

    return $t.Replace("`n","`r`n")
}
