# Havoc Hub

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

Everything runs through `loadstring` — the loader fetches the matching script plus the shared modules (`uilib.luau` and `espui.luau`) and loads them straight into memory. Nothing is copied into your executor's workspace; only your config files are written there.

## Games

### Havoc — `games/7336302630.luau` (PlaceId 7336302630)

The original suite:

- **Aimbot** — target selection, FOV control, visible-only check, silent aim, ballistics tuning
- **ESP** — Player / NPC / Drops / Radar. Names, health, distance, team colors; vehicles (e.g. MI-24V) included; optional landmine overlay
- **Inventory ESP**, HUD, radar, movement/misc tweaks, persistent config and rebindable hotkeys

### Driving Empire — `games/3351674303.luau` (PlaceId 3351674303)

Built against the game's decompiled source — vehicle physics run client-side:

- **Vehicle** — speed, acceleration, grip and brake multipliers (engine, torque, tyre traction and braking in the client physics), infinite nitro, ignore speed caps
- **Teleports** — Race Hub, main dealership, aviation + boat garages, drag strip, bank, police station, drawbridge
- **HUD** — live speedometer (MPH, gear, RPM) straight from the car's chassis controller, plus your cash
- **Money** — live cash readout on the HUD
- **Auto farm** — holds the throttle (optional steer bias for circles) so driving income keeps ticking while you're AFK; auto-reverses when stuck; **sky plate** mode builds a personal 10,000-stud-high plate and u-turns at its edges
- **Visuals** — player ESP with the full customizer, fullbright
- **Misc** — anti-AFK, reset character, rejoin server

### Universal — `games/universal.luau` (any other game)

Generic toolkit for games without a dedicated script:

- **Camera aimbot** — FOV circle, smoothing, team check, optional visibility check, Hold-RMB or Always activation
- **Player ESP (fully customizable)** — boxes / fills / corner brackets, names, health bars + text, distance, tracers, head dots, skeletons, look lines, off-screen arrows and chams, with static / team / rainbow / gradient colour modes
- **ESP Customizer** — two-window editor: a preview window with a real player model showing exactly how your ESP will look, plus a settings window for every element's style, placement, offsets and colours
- **Movement** — walk speed, jump power, infinite jump, fly
- **Misc** — fullbright, anti-AFK, rejoin server

## Manual setup (without the loader)

Copy `games/7336302630.luau` (or `games/universal.luau`) into your executor's workspace folder and execute it. The shared modules (`uilib.luau`, and `espui.luau` for the universal script) are only needed if nothing fetched them for you — without them the affected menu / ESP features are skipped with a warning.

## Files

| File | Purpose |
| --- | --- |
| `loader.luau` | Hub loader — picks by PlaceId, fetches modules, runs everything via loadstring |
| `games/7336302630.luau` | Havoc Project Delta (game-specific suite) |
| `games/3351674303.luau` | Driving Empire (vehicle performance, teleports, speedometer HUD) |
| `games/universal.luau` | Universal aimbot / ESP / utilities fallback |
| `uilib.luau` | Shared UI toolkit — window base, widgets, toasts, rebind capture, popup management |
| `espui.luau` | ESP schema, Drawing renderer and two-window customizer (preview + settings) used by every script |
| `StructureDumper.Luau` | Dev tool — dumps a game's structure for keeping detection logic up to date |
| `Libraries_Im_Using.txt` | Reference list of the executor APIs this project relies on |

## Configuration

- Havoc saves to `havoc_delta_config.json`, Driving Empire to `driving_empire_config.json` and the universal script to `universal_hub_config.json` — the only files the hub writes to the executor workspace
- Persists keybinds (including enabled/disabled state), feature toggles and values
- To reset a script: delete its config file from the workspace folder and re-execute

## Disclaimer

This project is shared for educational purposes. Using it may get your account banned. Use at your own risk.
