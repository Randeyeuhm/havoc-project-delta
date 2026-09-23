--[[
    ============================================
    HAVOC HUB - LOADSTRING LOADER
    ============================================

    Multi-game hub: picks the script that matches the current PlaceId and
    falls back to a universal script everywhere else.

    Usage (paste in the executor console):
        loadstring(game:HttpGet("https://raw.githubusercontent.com/Randeyeuhm/havoc-project-delta/main/loader.luau"))()

    How the pick works:
      • games/<PlaceId>.luau  - game-specific script (games/7336302630.luau
                                is Havoc Project Delta)
      • games/universal.luau  - fallback: generic aimbot / ESP / utilities

    Adding support for a new game = drop a "<PlaceId>.luau" file into the
    repo's games/ folder and push. No loader changes needed.

    It also fetches uilib.luau + espui.luau (shared UI toolkit and ESP
    customizer) and hands their sources to the game script, which loads them
    with loadstring - nothing is ever written to the executor's workspace.
]]

local USER   = "Randeyeuhm"
local REPO   = "havoc-project-delta"
local BRANCH = "main"

local GAMES_DIR      = "games/"
local UNIVERSAL_FILE = GAMES_DIR .. "universal.luau"
local UILIB_FILE     = "uilib.luau"
local ESPUI_FILE     = "espui.luau"

local RAW_BASE = ("https://raw.githubusercontent.com/%s/%s/%s/"):format(USER, REPO, BRANCH)

local function log(...)
    print("[Havoc Hub]", ...)
end

-- URL-encode spaces so "Havoc Project delta.luau" resolves on raw.github.
local function encode(path)
    return (path:gsub(" ", "%%20"))
end

-- Fetch a repo file. The os.time() cache-buster makes sure GitHub hands us
-- the very latest commit instead of a cached copy.
local function fetch(path)
    local url = RAW_BASE .. encode(path) .. "?t=" .. tostring(os.time())
    local ok, res = pcall(function()
        return game:HttpGet(url)
    end)
    if ok and type(res) == "string" and #res > 0 and res:sub(1, 1) ~= "<" and res:sub(1, 3) ~= "404" then
        return res
    end
    return nil, tostring(res)
end

local function baseName(path)
    return (path:match("([^/]+)$")) or path
end

-- 1) Pick the script for this game: games/<PlaceId>.luau when the repo has
--    one, otherwise fall back to the universal script.
local placeId = game.PlaceId
local gamePath = GAMES_DIR .. tostring(placeId) .. ".luau"
local gameSrc = fetch(gamePath)
if gameSrc then
    log("game script found for PlaceId " .. placeId)
else
    gamePath = UNIVERSAL_FILE
    log("no script for PlaceId " .. placeId .. " - loading the universal script")
    gameSrc = fetch(gamePath)
end
if not gameSrc then
    warn("[Havoc Hub] failed to download " .. gamePath .. " - check the repo")
    return
end
log(("fetched %s (%.1f KB)"):format(baseName(gamePath), #gameSrc / 1024))

-- 2) Shared modules - fetched here and handed to the game script as SOURCES
--    (it loadstring()s them). Nothing is written to the workspace.
local moduleSources = {}
for _, name in ipairs({ UILIB_FILE, ESPUI_FILE }) do
    local src = fetch(name)
    if src then
        moduleSources[name] = src
        log(("%s: %.1f KB"):format(name, #src / 1024))
        if name == ESPUI_FILE then
            -- Echo the build string so a stale module is obvious.
            local ver = src:match("ESPUI%.VERSION%s*=%s*\"([^\"]+)\"")
            log("espui build: " .. (ver or "unknown"))
        end
    else
        warn("[Havoc Hub] could not fetch " .. name .. " - the script will fall back to a local copy if present")
    end
end
if type(getgenv) == "function" then
    getgenv().HAVOC_HUB_SOURCES = moduleSources
else
    warn("[Havoc Hub] getgenv unavailable - the script needs local module files")
end

-- 3) Run it.
local chunk, compileErr = loadstring(gameSrc, "@" .. gamePath)
if not chunk then
    warn("[Havoc Hub] compile error in " .. gamePath .. ": " .. tostring(compileErr))
    return
end

log("launching " .. baseName(gamePath))
local ok, err = xpcall(chunk, function(e)
    return debug.traceback(tostring(e), 2)
end)
if not ok then
    warn("[Havoc Loader] runtime error:\n" .. tostring(err))
end
