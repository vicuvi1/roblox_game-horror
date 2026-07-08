# 90s Abandoned Shopping Mall — Co-Op Horror (Roblox / Luau)

A co-op multiplayer horror game with a VHS / retro aesthetic. This repo holds
the Luau source pulled into Roblox Studio by an HttpService loader.

## File structure

```
src/
├── server/init.lua      -- Main game manager: state machine, rounds, stamina (authoritative)
├── client/init.lua      -- Reads Shift input, requests sprint from the server
└── shared/GameConfig.lua -- ModuleScript with all tunable settings
```

## Where each script belongs in Roblox

| File                     | Roblox location                          | Class          |
|--------------------------|------------------------------------------|----------------|
| `src/shared/GameConfig.lua` | `ReplicatedStorage > Shared`          | ModuleScript   |
| `src/server/init.lua`    | `ServerScriptService`                     | Script (server)|
| `src/client/init.lua`    | `StarterPlayer > StarterPlayerScripts`    | LocalScript    |

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

## Tuning

All gameplay values live in `src/shared/GameConfig.lua` (match length, player
counts, walk/sprint speeds, stamina rates). The table is frozen — edit values
in that file, in source control.

## Roadmap ideas

- Real spawn points + escape objective
- Monster AI + chase music (VHS-filtered)
- Stamina bar UI + flashlight (battery drain reuses the stamina pattern)
- Server → client RemoteEvent to broadcast game state for menus/HUD
