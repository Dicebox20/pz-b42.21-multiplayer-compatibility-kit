Project Zomboid Build 42.21 Multiplayer Compatibility Kit

Purpose
-------
This kit ports the tested mod stack for Project Zomboid stable Build 42.21 multiplayer without disabling Lua checksum validation.

The kit does not redistribute Workshop mod assets. It repairs files from the user's own Steam Workshop subscriptions, then builds a local compatibility overlay from those repaired subscriptions.

Recommended order
-----------------
1. Subscribe to/download the same Workshop mods.
2. Close Project Zomboid and any dedicated/hosted server.
3. Run 01-Audit-Multiplayer.cmd.
4. Run 02-Apply-Multiplayer.cmd.
5. Run 03-Verify-Multiplayer.cmd.
6. Host/join a multiplayer session.
7. Run 03-Verify-Multiplayer.cmd again to inspect the latest hosted log.
8. Use 04-Restore-Latest.cmd to undo the latest compatibility changes.

What is ported
--------------
- Build 42 item schema / ItemType updates.
- Build 42.15 translation JSON migration.
- W900 modversion metadata.
- GaelGunStore effect preset installation.
- GaelGunStore multiplayer require path fixes.
- GaelGunStore B42.21 client/shared load-order fixes for Dynamic Ammo, Manual Rack, and grenade-launcher reload compatibility.
- Multiple Safehouse Claims B42.21 UI path fixes; obsolete HaloTextHelper Lua import removed while preserving the Java-exposed HaloTextHelper API.
- B42 vehicle GloveBox container fixes, including Papa_Chad "contanier" typos and KI5 camper omissions.
- Additional tested B42 vehicle-script/runtime fixes.
- Hosted-server Workshop cache handling.
- Merucia-style WorkshopItems synchronization while keeping DoLuaChecksum=true.
- PZ42MPCompat local overlay, generated from the user's own patched subscriptions and loaded last in matching server Mods lists.

Files
-----
PZ-B42.21-Multiplayer-Patch.ps1
  Core B42.21 and multiplayer source/cache patcher.

PZ-B42.21-MP-Overlay.ps1
  Builds/restores the PZ42MPCompat local override mod.

PZ-B42.21-MP-OverlayMap.json
  Metadata map identifying the 52 Workshop source files used to rebuild the overlay.

PZ42MPCompat-Transforms.ps1
  Deterministic B42.21 text transforms applied to selected Workshop-owned Lua sources while rebuilding the overlay.

PZ42MPCompat_aliases.txt
  Small compatibility alias/template file created for this port.

Verify-PZ-B42.21-Multiplayer.ps1
  Runs static audits and checks the latest coop-console.txt for the targeted multiplayer failure classes.

PZ-B42-Mod-Diagnostic-v4.ps1
  Optional broader read-only diagnostic.

Safety
------
- Project Zomboid must be closed before Apply or Restore.
- Both core and overlay installers create rollback backups before changes.
- DoLuaChecksum remains enabled.
- Steam Workshop updates may overwrite repaired Workshop files. Stop the server and rerun Audit/Apply after Workshop updates.
- The PZ42MPCompat overlay is appended last in matching server Mods lists so its overrides win deterministically.

Tested state
------------
Source machine: Windows, Project Zomboid stable 42.21.
Final core Audit: 0 planned changes.
Final overlay Audit after the 1.1.0 API-transform staging: 52/52 mapped sources, content current=True, server profile current=True.
Live Steam-hosted coop testing confirmed Rujiel and Dyscid both fully connected as admins. After Dyscid's successful full connection, the server recorded 0 new runtime errors, 0 exceptions, 0 Lua warnings, 0 packet-limit warnings, and 0 checksum failures.
Targeted multiplayer failures remain at 0 for:
  NetChecksum null-path
  Missing client/server files
  Checksum mismatch
  GloveBox key-spawn NPE
  GGS_FactoryPresets warning
  GGS_LootMagazineRules warning

Startup still produces Build 42/mod scan noise, including optional AnimSets/actiongroups path probes and vanilla worldgen/map warnings. These are tracked separately from live-play failures.

Important validation note
-------------------------
The 1.1.0 API/load-order transforms are staged for the next process start and have passed static transform/audit verification. A fresh host/client restart is still required to prove that the corrected GaelGunStore and Multiple Safehouse Claims imports load without the prior require warnings. All multiplayer clients must regenerate the same PZ42MPCompat overlay before that restart so Lua checksums remain matched.

Live-play diagnostic
--------------------
Run 06-Live-Play-Diagnostic.cmd before hosting/joining. It watches only new client/server log lines created during that play session and writes TXT + JSON reports under:
  %USERPROFILE%\Zomboid\LiveModuleDiagnostics\<timestamp>\

During play, press these keys in the diagnostic window after you have exercised each module family:
  1 Papa_Chad
  2 KI5/DAMN
  3 TsarLib
  4 GaelGunStore
  5 W900
  6 PZ42MPCompat
Press Q when finished.

The report distinguishes:
- TESTED CLEAN: manually exercised, with no targeted issue attributed to that module.
- ACTIVITY OBSERVED: module-specific live log activity was seen without a targeted issue.
- ISSUES OBSERVED: a targeted problem was attributed to that module.
- NOT OBSERVED: no identifiable live log activity was seen; this is not automatically a failure.
- REVIEW: unrelated/unattributed runtime errors that should be inspected but do not automatically fail a module.

Use LIVE-PLAY-CHECKLIST.txt so each module family is deliberately exercised.
