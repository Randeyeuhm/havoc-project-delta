--[[
    ============================================
    HAVOC PROJECT DELTA - LOADSTRING LOADER
    ============================================

    Fetches the latest script + UI library from GitHub and runs them.

    Usage (paste in the executor console):
        loadstring(game:HttpGet("https://raw.githubusercontent.com/Randeyeuhm/havoc-project-delta/main/loader.luau"))()

    What it does:
      1. Downloads "Havoc Project delta.luau" and "uilib.luau" from the repo.
      2. Saves both into the executor's workspace folder - the main script
         reads uilib.luau from disk at startup, and your existing
         havoc_delta_config.json keeps working because it's the same folder.
         Files are only rewritten when the remote content actually changed.
      3. Executes the downloaded main script.
]]

local USER   = "Randeyeuhm"
local REPO   = "havoc-project-delta"
local BRANCH = "main"

local MAIN_FILE  = "Havoc Project delta.luau"
local UILIB_FILE = "uilib.luau"

local RAW_BASE = ("https://raw.githubusercontent.com/%s/%s/%s/"):format(USER, REPO, BRANCH)

local function log(...)
    print("[Havoc Loader]", ...)
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
    if ok and type(res) == "string" and #res > 0 and res:sub(1, 1) ~= "<" then
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

-- 1) Main script - without it there is nothing to run.
local mainSrc, mainErr = fetch(MAIN_FILE)
if not mainSrc then
    warn("[Havoc Loader] failed to download " .. MAIN_FILE .. " (" .. tostring(mainErr) .. ")")
    return
end
log(("fetched %s (%.1f KB)"):format(MAIN_FILE, #mainSrc / 1024))

-- 2) UI library - non-fatal, a local copy still works if the fetch fails.
local uilibSrc = fetch(UILIB_FILE)
if uilibSrc then
    local ok, status = syncToDisk(UILIB_FILE, uilibSrc)
    if ok then
        log("uilib.luau: " .. status)
    else
        warn("[Havoc Loader] could not save uilib.luau (" .. tostring(status) .. ") - settings menu may be skipped")
    end
else
    warn("[Havoc Loader] could not update uilib.luau - using the local copy if present")
end

-- Keep a local copy of the main script too, for manual runs.
syncToDisk(MAIN_FILE, mainSrc)

-- 3) Run it.
local chunk, compileErr = loadstring(mainSrc, "@" .. MAIN_FILE)
if not chunk then
    warn("[Havoc Loader] compile error: " .. tostring(compileErr))
    return
end

log("launching " .. MAIN_FILE)
local ok, err = xpcall(chunk, function(e)
    return debug.traceback(tostring(e), 2)
end)
if not ok then
    warn("[Havoc Loader] runtime error:\n" .. tostring(err))
end
