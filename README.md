# Hide & Survive — Realistic Co-op Horror (Roblox / Luau)

A hide-and-survive horror game built to the spec in
[RobloxHorrorGame_MasterPrompt.md](RobloxHorrorGame_MasterPrompt.md):
an 8-zone facility, an adaptive stalker that hunts by sight AND sound,
layered audio, a tension meter that makes you *feel* the danger, and a
per-run results screen.

## The loop

Survive the night. Move quietly — **every footstep is a broadcast** (surface
matters: carpet muffles, tile clicks, vents clang). The Stalker patrols
room-by-room, investigates what it hears, remembers where it saw you, and
searches hiding spots when it loses you. At the final stretch the
**EXTRACTION** door unlocks — get there or outlast the clock.

| Key | Action |
|-----|--------|
| Shift | Sprint (fast, LOUD, drains stamina — exhaustion makes you slow and audible) |
| C | Crouch (slow, near-silent, harder to see) |
| G | Hold breath (~4s, silences you; cooldown after) |
| Q / E | Peek lean |
| F | Flashlight (the beam gives you away farther) |
| E | Interact: hide, open door fast (loud), pick up bottle, vault window |
| R | Open door **slowly** (near-silent) |
| T | Throw bottle — glass shatter = sound decoy |

Other systems: **barricade** heavy shelves into doorways (very loud, buys
time — the Stalker bashes through), **vents** to reroute silently but slowly,
**12 hiding spots** with real safety levels (a locker beats a table — and it
checks them when searching), **near-miss** feedback when it passes you by,
and a **results screen** (survival time, distance, close calls, hides used).

## Architecture (ModuleScripts, event-driven via Signals)

```
src/
├── shared/GameConfig.lua        -- EVERY tunable constant, one frozen table
├── server/
│   ├── init.server.lua          -- composition root (build map -> init systems -> run)
│   ├── Signals.lua              -- event bus: Noise / Detection / NearMiss / Caught
│   ├── MapManager.lua           -- 8-zone facility, props, storytelling, zone lookup
│   ├── DoorSystem.lua           -- fast/slow doors, barricades, enemy slams
│   ├── HidingSpotSystem.lua     -- spots + safety-level discovery rolls
│   ├── ThrowableSystem.lua      -- bottle decoys (pooled shatter FX)
│   ├── PlayerService.lua        -- stamina/breath/noise/tension/stats (authoritative)
│   ├── EnemyAI.lua              -- FSM + memory + search + hearing + adaptive speed
│   ├── AtmosphereSystem.lua     -- lighting, irregular flicker, enemy-proximity tells, particles
│   └── GameManager.lua          -- round loop, extraction, remotes, HUD, results
└── client/
    ├── init.client.lua          -- PlayerController: input, first-person camera, peek
    ├── SoundManager.lua         -- SoundGroups, per-surface footsteps, heartbeat, ducking
    ├── AnimationController.lua  -- placeholder anim ids, pcall-guarded, fade blending
    ├── UISystem.lua             -- HUD, tutorial card, extraction banner, results screen
    └── Effects.lua              -- tension vignette/shake, hunted pulse, flinch, jumpscare
```

Zones: Spawn (safe) → Hallway (lockers, creaky wood) → Common (open, risky) /
Kitchen (noisy tile, throwables) → Bedroom (hiding-dense) / Maintenance
(dark, echoing, flicker) → Extraction. Two vent runs connect
Hallway↔Bedroom and Kitchen↔Maintenance.

## Dev workflow (Rojo)

```powershell
git pull
rojo serve      # then Connect in Studio, press Play
```

`default.project.json` maps `src/` into ReplicatedStorage / ServerScriptService /
StarterPlayerScripts.

## Dropping in real assets

- **Audio:** put ids in `GameConfig.Sounds` (footsteps/creaks/heartbeat/growl…).
  `rbxasset://` entries are engine built-ins and always work.
- **Animations:** put ids in `GameConfig.Animations` — every state is wired and
  pcall-guarded; empty ids are skipped silently.
- **Meshes:** the map is parts-first; replace props zone by zone in
  `MapManager.lua` without touching gameplay.
