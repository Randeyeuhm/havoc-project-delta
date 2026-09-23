# Havoc Hub (Havoc Project Delta)

A multi-game script suite for Roblox, built for the [Potassium](https://docs.potassium.pro/) executor. One loader picks the right script for the current game — and falls back to a universal toolkit anywhere else.

## How it works

`loader.luau` checks `game.PlaceId` when you execute it:

1. **`games/<PlaceId>.luau`** — if the repo has a script for the current game, that one loads (e.g. `games/7336302630.luau` is the Havoc Project Delta suite).
2. **`games/universal.luau`** — otherwise the universal script loads: generic aimbot, ESP and utilities that work across most games.

Adding support for a new game is just dropping a `<PlaceId>.luau` file into `games/` — no loader changes needed.

## Quick start (loader)

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Randeyeuhm/havoc-project-delta/main/loader.luau"))()
```

The loader downloads the matching script plus `uilib.luau` into your executor's workspace folder (only rewriting files when they changed), then runs it. Your existing configs keep working since they live in the same folder.

## Games

### Havoc — `games/7336302630.luau` (PlaceId 7336302630)

The original suite:

- **Aimbot** — target selection, FOV control, visible-only check, silent aim, ballistics tuning
- **ESP** — Player / NPC / Drops / Radar. Names, health, distance, team colors; vehicles (e.g. MI-24V) included; optional landmine overlay
- **Inventory ESP**, HUD, radar, movement/misc tweaks, persistent config and rebindable hotkeys

### Universal — `games/universal.luau` (any other game)

Generic toolkit for games without a dedicated script:

- **Camera aimbot** — FOV circle, smoothing, team check, optional visibility check, Hold-RMB or Always activation
- **Player ESP** — boxes, names, health, distance, tracers, team check, configurable max distance
- **Movement** — walk speed, jump power, infinite jump, fly
- **Misc** — fullbright, anti-AFK, rejoin server

## Manual setup (without the loader)

Copy `games/7336302630.luau` (or `games/universal.luau`) plus `uilib.luau` into your executor's workspace folder (same place the config files are written), then execute the script. If `uilib.luau` is missing, everything except the settings menu still runs — you'll just see a warning.

## Files

| File | Purpose |
| --- | --- |
| `loader.luau` | Hub loader — picks by PlaceId, syncs files, runs |
| `games/7336302630.luau` | Havoc Project Delta (game-specific suite) |
| `games/universal.luau` | Universal aimbot / ESP / utilities fallback |
| `uilib.luau` | Shared UI toolkit — widgets, toasts, rebind capture, popup management |
| `StructureDumper.Luau` | Dev tool — dumps a game's structure for keeping detection logic up to date |
| `Libraries_Im_Using.txt` | Reference list of the executor APIs this project relies on |

## Configuration

- Havoc saves to `havoc_delta_config.json`, the universal script to `universal_hub_config.json` — both in the executor workspace next to the scripts
- Persists keybinds (including enabled/disabled state), feature toggles and values
- To reset a script: delete its config file from the workspace folder and re-execute

## Disclaimer

This project is shared for educational purposes. Using it may get your account banned. Use at your own risk.
