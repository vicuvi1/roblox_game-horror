# 90s Abandoned Shopping Mall — Co-Op Horror (Roblox / Luau)

A co-op multiplayer horror game with a VHS / retro aesthetic. This repo holds
the Luau source pulled into Roblox Studio by an HttpService loader.

## File structure

```
src/
├── server/init.lua       -- Main game manager: state machine, rounds, stamina + flashlight (authoritative), HUD broadcast
├── client/
│   ├── init.lua          -- Input (sprint/flashlight), HUD wiring, sprint FOV kick
│   └── Hud.lua           -- VHS-styled HUD built in code (bars, timer, blinking REC)
└── shared/GameConfig.lua -- ModuleScript with all tunable settings
```

## Controls

| Key      | Action                    |
|----------|---------------------------|
| `Shift`  | Hold to sprint (drains stamina) |
| `F`      | Toggle flashlight (drains battery) |

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

- Real spawn points + escape objective
- Monster AI + chase music (VHS-filtered)
- Stamina bar UI + flashlight (battery drain reuses the stamina pattern)
- Server → client RemoteEvent to broadcast game state for menus/HUD
