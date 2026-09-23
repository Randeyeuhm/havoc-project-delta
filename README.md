# Havoc Project Delta

A script suite for the Roblox game **Havoc**, built for the [Potassium](https://docs.potassium.pro/) executor. Modular LuaU (Luau) codebase with a standalone UI toolkit and persistent configuration.

## Features

- **Aimbot** — target selection, FOV control, visible-only check, silent aim, ballistics tuning
- **ESP** — Player / NPC / Drops / Radar. Names, health, distance, team colors; vehicles (e.g. MI-24V) included; optional landmine overlay
- **Inventory ESP** — compact live item card
- **Movement & Misc** — walkspeed / jump overrides, fly, viewmodel tweaks
- **Persistent config** — everything saves to `havoc_delta_config.json` and survives re-execution
- **Rebindable hotkeys** — click a key chip, press a key. Duplicate keys are refused; the menu key stays locked
- **Menu** — dark, searchable, card-based UI powered by `uilib.luau`

## Requirements

- A Roblox executor with filesystem access, `loadstring` and the `Drawing` API — built and tested on **Potassium**
- The game's client is not included, obviously. Bring your own account, at your own risk

## Setup

1. Copy **both** of these into your executor's workspace folder (the same folder where `havoc_delta_config.json` is written):
   - `Havoc Project delta.luau` — the main script
   - `uilib.luau` — the menu library it loads at startup
2. Execute `Havoc Project delta.luau` through the executor.
3. Press `RightShift` to toggle the menu.

> If `uilib.luau` is missing, everything **except the settings menu** still runs — you'll just see a warning in the console.

## Files

| File | Purpose |
| --- | --- |
| `Havoc Project delta.luau` | Main script — features, hooks, ESP, aimbot, config system |
| `uilib.luau` | Self-contained UI toolkit — widgets, toasts, dropdowns, rebind capture, popup management |
| `StructureDumper.Luau` | Dev tool — dumps the game's structure (ReplicatedStorage, zones, part layouts) for keeping detection logic up to date |
| `Libraries_Im_Using.txt` | Reference list of the executor APIs this project relies on |

## Configuration

- Saved as `havoc_delta_config.json` in the executor workspace, next to the scripts
- Persists keybinds (including enabled/disabled state), ESP settings, aimbot settings and GUI position
- To reset: delete the config file from the workspace folder and re-execute

## Disclaimer

This project is shared for educational purposes. Using it may get your account banned. Use at your own risk.
