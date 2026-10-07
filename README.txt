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
  Metadata map identifying the 48 Workshop source files used to rebuild the overlay.

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
Final overlay Audit: content current=True, server profile current=True.
Real Steam-hosted coop server log after port: 27 mod loads, 0 ERROR lines, 0 exception/stack lines, 0 client-command errors, 0 server-command errors.
Targeted failures in real hosted coop log after port:
  NetChecksum null-path: 0
  Missing client/server files: 0
  Checksum mismatch: 0
  GloveBox key-spawn NPE: 0
  GGS_FactoryPresets warning: 0
  GGS_LootMagazineRules warning: 0

Remaining warnings are primarily missing optional/world-item meshes. Those can produce invisible dropped/world-item models, but they are not multiplayer authority/checksum failures.

Important validation note
-------------------------
The real Steam-hosted server side is clean after the port. The host client's latest console.txt available during development was from the pre-patch session, so a fresh post-patch player join is still the final runtime confirmation for client-side visuals/gameplay. The Verify launcher is included specifically for that follow-up.
