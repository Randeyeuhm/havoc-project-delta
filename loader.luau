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

    It also syncs uilib.luau (the shared UI toolkit) into the executor's
    workspace folder, since the scripts read it from disk. Files are only
    rewritten when the remote content actually changed.
]]

local USER   = "Randeyeuhm"
local REPO   = "havoc-project-delta"
local BRANCH = "main"

local GAMES_DIR      = "games/"
local UNIVERSAL_FILE = GAMES_DIR .. "universal.luau"
local UILIB_FILE     = "uilib.luau"

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

-- Write to the executor workspace only when the content changed, so a file
-- that is already current is left untouched.
local function syncToDisk(name, src)
    if type(writefile) ~= "function" then return false, "no filesystem API" end
    if type(readfile) == "function" then
        local ok, cur = pcall(readfile, name)
        if ok and cur == src then return true, "up to date" end
    end
    local ok, err = pcall(writefile, name, src)
    if ok then return true, "updated" end
    return false, tostring(err)
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

-- 2) UI library - non-fatal, a local copy still works if the fetch fails.
local uilibSrc = fetch(UILIB_FILE)
if uilibSrc then
    local ok, status = syncToDisk(UILIB_FILE, uilibSrc)
    if ok then
        log("uilib.luau: " .. status)
    else
        warn("[Havoc Hub] could not save uilib.luau (" .. tostring(status) .. ") - settings menu may be skipped")
    end
else
    warn("[Havoc Hub] could not update uilib.luau - using the local copy if present")
end

-- Keep a local copy of the loaded script, for manual runs.
syncToDisk(baseName(gamePath), gameSrc)

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
