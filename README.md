# 90s Abandoned Shopping Mall — Co-Op Horror (Roblox / Luau)

A co-op multiplayer horror game with a VHS / retro aesthetic. This repo holds
the Luau source pulled into Roblox Studio by an HttpService loader.

## File structure

```
src/
├── server/
│   ├── init.lua          -- Game manager: state machine, rounds, win/lose, stamina + flashlight, HUD broadcast, dev arena
│   ├── Objectives.lua    -- Collectibles (WIN condition) with hold-E prompts
│   └── MonsterAI.lua     -- "The Stalker" (LOSE condition): pathfinding patrol/chase/search AI
├── client/
│   ├── init.lua          -- Input (sprint/flashlight), HUD wiring, sprint FOV kick
│   └── Hud.lua           -- VHS-styled HUD built in code (bars, timer, objectives, REC, result)
└── shared/GameConfig.lua -- ModuleScript with all tunable settings
```

## The game loop

Each round: **collect every objective and survive until they're all gathered — before the Stalker catches everyone.**

| Outcome | Trigger |
|---------|---------|
| 🟢 **ESCAPED** (win) | All objectives collected |
| 🔴 **CAUGHT** (lose) | The Stalker kills the last living player |
| 🔴 **TIME UP** (lose) | Match timer hits zero with objectives left |

> **Playable out of the box:** with `CreateDevArena = true` (default), the server
> builds a floor, obstacle shelves, a lobby platform, and dark/foggy horror
> lighting so you can test immediately. Set it to `false` once you drop in a
> real mall map, and replace `ArenaCenter` / `LobbySpawn` with your own spawns.

## Controls

| Key      | Action                    |
|----------|---------------------------|
| `Shift`  | Hold to sprint (drains stamina) |
| `F`      | Toggle flashlight (drains battery) |

## Getting it into Roblox Studio (Rojo — live auto-sync)

This repo is set up for [Rojo](https://rojo.space), which syncs these local
files straight into Studio and **updates live every time a file is saved**.
`default.project.json` maps the folders to the right Roblox services.

**One-time setup**
1. Install the Rojo CLI (already done on this machine via `winget install Rojo.Rojo`).
2. Install the **Rojo plugin** inside Studio: `Plugins` tab → `Manage Plugins` /
   Creator Store → search **Rojo** → Install.

**Every session**
1. In a terminal, from this folder, run:  `rojo serve`
   (prints something like `Rojo server listening on localhost:34872`).
2. In Studio, click the **Rojo** toolbar button → **Connect**.
3. Done — edits to any file in `src/` now appear in Studio instantly. Press
   **Play** (F5) to test.

> Rojo reads your LOCAL files, so this works even before the GitHub push is set
> up. To pull my latest work: `git pull` in this folder and Rojo syncs it in.

**Build a `.rbxlx` without Studio open (optional):**
`rojo build default.project.json -o build.rbxlx`

## Where each script belongs in Roblox

| File                     | Roblox location                          | Class          |
|--------------------------|------------------------------------------|----------------|
| `src/shared/GameConfig.lua` | `ReplicatedStorage > Shared`          | ModuleScript   |
| `src/server/init.lua`    | `ServerScriptService`                     | Script (server)|
| `src/client/init.lua`    | `StarterPlayer > StarterPlayerScripts`    | LocalScript    |
| `src/client/Hud.lua`     | child of the client LocalScript (sibling module) | ModuleScript |

> The server and client scripts both `require` `ReplicatedStorage.Shared.GameConfig`.
> Make sure your loader places `GameConfig` inside a folder named **`Shared`** in
> `ReplicatedStorage` (or edit the require paths at the top of each script).

## How it works

- **State machine** (`server/init.lua`): loops forever through
  `Intermission → InGame → GameOver`. Intermission waits for `MinPlayers` and
  counts down; InGame runs for `MatchLength` seconds; GameOver shows results.
- **Round system**: teleports are currently `print()` placeholders
  (`teleportPlayersToMall` / `teleportPlayersToLobby`). Swap in real
  `PivotTo(CFrame)` calls to your spawn parts.
- **Stamina / sprint** (server-authoritative): the client only *requests*
  sprint over the `SprintRequest` RemoteEvent when Shift is held. The server
  drains stamina while sprinting, forces `WalkSpeed` back to normal at 0
  stamina, and regenerates after a short delay. This design prevents
  speed-hack exploits.
- **Flashlight / battery** (server-authoritative): pressing `F` requests a
  toggle over the `FlashlightRequest` RemoteEvent. The server creates a real
  `SpotLight` on the player's head (so **all co-op players see each other's
  lights**), drains battery while it's on, and forces it off at 0. Battery
  does not recharge by default — add pickups via `addBattery(player, amount)`.
- **HUD** (`client/Hud.lua`): the server pushes each player's stamina, battery,
  game state, and round timer over the `HudUpdate` RemoteEvent (~10x/sec). The
  client renders a VHS-style overlay: stamina/battery bars, an `MM:SS` timer,
  and a blinking `● REC`. The stamina FOV kick is purely local feel.

## Tuning

All gameplay values live in `src/shared/GameConfig.lua` (match length, player
counts, walk/sprint speeds, stamina rates). The table is frozen — edit values
in that file, in source control.

## Roadmap ideas

- Replace the dev arena with a real 90s mall map (storefronts, food court)
- Animated monster rig + chase music (VHS-filtered) + jumpscare on catch
- Battery / objective pickups in the world (`addBattery(player, amount)` is ready)
- A real exit door that unlocks once all objectives are collected
- VHS post-processing (scanlines, chromatic aberration, grain)
- Downed/revive system so co-op players can save each other instead of instant death
