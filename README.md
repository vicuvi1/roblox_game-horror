# Hide & Survive — Realistic Co-op Horror (Roblox / Luau)

A hide-and-survive horror game built to the spec in
[RobloxHorrorGame_MasterPrompt.md](RobloxHorrorGame_MasterPrompt.md):
an 8-zone facility, an adaptive stalker that hunts by sight AND sound,
layered audio, a tension meter that makes you *feel* the danger, and a
per-run results screen.

## The loop

Co-op survival. **Repair 3 generators** (spread across the far zones — you'll
have to split up) to **power the extraction**, then escape. Move quietly —
**every footstep is a broadcast** (carpet muffles, tile clicks, vents clang).

**Two entities hunt you:**
- **The Stalker** — patrols, hears noise, remembers where it saw you, searches
  hiding spots, *runs faster than your sprint* and lunges. Break line of sight,
  hide, or throw a decoy.
- **The Lurker** — a pale figure that **only moves while nobody is looking at
  it.** Keep it in view to freeze it; look away and it rushes you.

Get caught and you're **downed, not dead** — you crawl and bleed out while a
teammate holds E to revive you (or self-revive with a **Medkit**). When
everyone's down, it's over. Earn **coins** each run and spend them in the
**lobby shop** (medkit, brighter light, longer breath, more stamina, sixth
sense). Coins **persist** between sessions.

| Key | Action |
|-----|--------|
| Shift | Sprint (fast, LOUD, drains stamina — exhaustion makes you slow and audible) |
| C | Crouch (slow, near-silent, harder to see) |
| G | Hold breath (~4s, silences you; cooldown after) |
| Q / E | Peek lean |
| F | Flashlight (the beam gives you away farther) |
| E | Interact: hide, open door fast (loud), pick up bottle, vault window, **repair generator**, **revive teammate** |
| R | Open door **slowly** (near-silent) |
| T | Throw bottle — glass shatter = sound decoy |
| H | Use Medkit to self-revive while downed |

*Mobile: on-screen touch buttons appear automatically on phones/tablets.*

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
│   ├── Signals.lua              -- event bus (Noise/Detection/NearMiss/Caught/Downed/Revived/Death/ObjectiveDone)
│   ├── MapManager.lua           -- 8-zone facility, props, storytelling, generator/spawn points
│   ├── DoorSystem.lua           -- fast/slow doors, barricades, enemy slams
│   ├── HidingSpotSystem.lua     -- spots + safety-level discovery rolls
│   ├── ThrowableSystem.lua      -- bottle decoys (pooled shatter FX)
│   ├── ObjectiveSystem.lua      -- generators -> power the extraction
│   ├── PlayerService.lua        -- stamina/breath/noise/tension/stats + shop effects
│   ├── EnemyAI.lua              -- Stalker: FSM + memory + search + hearing + lunge + adaptive
│   ├── Lurker.lua               -- second entity (moves only when unobserved)
│   ├── DownSystem.lua           -- downed/bleedout/co-op revive/self-revive
│   ├── Gore.lua                 -- blood bursts + splatter pools
│   ├── Progression.lua          -- DataStore coins + owned items (persistent)
│   ├── ShopSystem.lua           -- lobby shop pedestals + buyable upgrades
│   ├── ModelLoader.lua          -- import Toolbox rigs/meshes via GameConfig.PropModels
│   ├── AtmosphereSystem.lua     -- FUTURE lighting, irregular flicker, proximity tells, particles
│   └── GameManager.lua          -- round loop, objectives, extraction, remotes, HUD, results, coins
└── client/
    ├── init.client.lua          -- PlayerController: input, first-person camera, peek, look-stream
    ├── SoundManager.lua         -- SoundGroups, per-surface footsteps, heartbeat, layered music, ducking
    ├── AnimationController.lua  -- placeholder anim ids, pcall-guarded, fade blending
    ├── UISystem.lua             -- HUD, objectives, downed overlay, coins, extraction banner, results
    ├── MobileControls.lua       -- touch buttons (phones/tablets)
    └── Effects.lua              -- tension vignette/shake, hunted pulse, blood, death-cam, sixth-sense glow
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
