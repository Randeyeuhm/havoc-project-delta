--[[
    ============================================
    HAVOC HUB - DRIVING EMPIRE  (PlaceId 3351674303)
    ============================================
    Game-specific script. Grounded in the decompiled game source (structure
    dump): the vehicle physics run CLIENT-SIDE inside
    ReplicatedStorage.Modules.Client.Vehicles.ChassisControllers, and the
    live car object is exposed through
    VehicleController.getActiveChassisController() - the same accessor the
    game's own tuning UI uses. The speed/torque pipeline reads
    ChassisUtils.GetSpeedMult / GetTorqueMult every frame, which is where
    the multipliers hook in.

      • Vehicle   - speed multiplier, acceleration multiplier, infinite
                    nitro, ignore speed caps (client-side physics)
      • Teleports - Race Hub, dealerships, garages, bank, drag strip, ...
      • HUD       - live speedometer (MPH, gear, RPM)
      • Visuals   - player ESP (full customizer) + fullbright
      • Misc      - anti-AFK, rejoin, reset character

    Menu key: RightShift (locked). Config: driving_empire_config.json.
    Requires uilib.luau + espui.luau from the hub loader (or local copies).
]]

if setstackhidden then pcall(setstackhidden, true) end

-- ============================================================
-- SERVICES / STATE
-- ============================================================
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Lighting         = game:GetService("Lighting")
local HttpService      = game:GetService("HttpService")
local VirtualUser      = game:GetService("VirtualUser")
local TeleportService  = game:GetService("TeleportService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer      = Players.LocalPlayer

local SCRIPT_VERSION = "de-v42"

-- ONE-RUN-PER-CLIENT GUARD: the queued teleport payload checks this flag
-- before loading the hub, and the hub itself sets it - so even if several
-- payload copies are queued (or a same-client teleport fires one while the
-- hub is already running) the hub never starts twice in one client.
if type(getgenv) == "function" then
    pcall(function() getgenv().HAVOC_HUB_TELEPORT_EXEC = true end)
end

local Connections = {}
local function track(conn)
    table.insert(Connections, conn)
    return conn
end

-- ============================================================
-- CONFIG  (persisted to driving_empire_config.json)
-- ============================================================
local CONFIG_FILE = "driving_empire_config.json"

local DEFAULTS = {
    Vehicle  = { SpeedMult = 1, TorqueMult = 1, GripMult = 1, SteerMult = 1, BrakeMult = 1, InfNitro = false, NoSpeedCap = false, InstantShift = true, NoTires = false },
    HUD      = { Enabled = true, SpeedSize = 18, InfoSize = 13, XOffset = 14, YOffset = 40 },
    Money    = { ShowHud = true },
    Farm     = { Enabled = false, Steer = 0 },
    Race     = { HopDelay = 0.5, SweepDist = 12, PayoutBuffer = 1, CarLimitPad = 1.25, AutoFarm = false, AutoRequeue = false },
    -- ESP gets filled out by ESPUI.fill (the full espui schema); these four
    -- exist before the module loads so the file merge has typed targets.
    ESP      = { Enabled = false, TeamCheck = false, VisibleOnly = false, MaxDistance = 2000 },
    Misc     = { Fullbright = false, AntiAFK = true, TeleportExec = true },
}

local function copyDefaults()
    local out = {}
    for section, values in pairs(DEFAULTS) do
        out[section] = {}
        for k, v in pairs(values) do out[section][k] = v end
    end
    return out
end

local Config = copyDefaults()

local function saveConfig()
    if type(writefile) ~= "function" then return end
    pcall(function()
        writefile(CONFIG_FILE, HttpService:JSONEncode(Config))
    end)
end

local saveScheduled = false
local function saveConfigDebounced()
    if saveScheduled then return end
    saveScheduled = true
    task.delay(0.5, function()
        saveScheduled = false
        saveConfig()
    end)
end

-- The file is read now but merged LATER (after espui has filled the ESP
-- section), so saved customizer settings can actually restore.
local savedFromFile = nil
if type(isfile) == "function" and isfile(CONFIG_FILE) and type(readfile) == "function" then
    local ok, decoded = pcall(function()
        return HttpService:JSONDecode(readfile(CONFIG_FILE))
    end)
    if ok and type(decoded) == "table" then
        savedFromFile = decoded
    end
end

-- ============================================================
-- UI LIBRARY + ESP MODULE  (sources stashed by the hub loader)
-- ============================================================
local function moduleSource(name)
    local genv = type(getgenv) == "function" and getgenv() or nil
    local stash = genv and genv.HAVOC_HUB_SOURCES
    if type(stash) == "table" and type(stash[name]) == "string" and stash[name] ~= "" then
        return stash[name]
    end
    if type(readfile) == "function" then
        local ok, src = pcall(readfile, name)
        if ok and type(src) == "string" and src ~= "" then return src end
    end
    return nil
end

local UILIB_FILE = "uilib.luau"
local UILib
do
    local ok, res = pcall(function()
        local src = moduleSource(UILIB_FILE)
        if not src then error("no source (loader stash empty, no local file)") end
        local chunk, compileErr = loadstring(src, "@" .. UILIB_FILE)
        if not chunk then error("compile error: " .. tostring(compileErr)) end
        return chunk()
    end)
    if ok and type(res) == "table" then
        UILib = res
        print("[driving-empire] uilib " .. tostring(UILib.VERSION or "?") .. " loaded")
    else
        warn("[driving-empire] uilib.luau not loaded (" .. tostring(res) .. ") - settings menu will be skipped")
    end
end

local ESPUI_FILE = "espui.luau"
local ESPUI
do
    local ok, res = pcall(function()
        local src = moduleSource(ESPUI_FILE)
        if not src then error("no source (loader stash empty, no local file)") end
        local chunk, compileErr = loadstring(src, "@" .. ESPUI_FILE)
        if not chunk then error("compile error: " .. tostring(compileErr)) end
        return chunk()
    end)
    if ok and type(res) == "table" then
        ESPUI = res
        print("[driving-empire] espui " .. tostring(ESPUI.VERSION or "?") .. " loaded")
    else
        warn("[driving-empire] espui.luau not loaded (" .. tostring(res) .. ") - ESP disabled")
    end
end

-- Fill the ESP schema first, THEN merge the saved file, then repair enums.
if ESPUI then
    ESPUI.fill(Config.ESP)
end
if savedFromFile then
    for section, values in pairs(savedFromFile) do
        if type(Config[section]) == "table" and type(values) == "table" then
            for k, v in pairs(values) do
                if type(v) == type(Config[section][k]) then
                    Config[section][k] = v
                end
            end
        end
    end
end
if ESPUI then
    ESPUI.sanitize(Config.ESP)
end

-- Clamp anything numeric the file could have corrupted.
Config.Vehicle.SpeedMult = math.clamp(tonumber(Config.Vehicle.SpeedMult) or 1, 1, 50)
Config.Vehicle.TorqueMult = math.clamp(tonumber(Config.Vehicle.TorqueMult) or 1, 1, 50)
Config.Vehicle.GripMult = math.clamp(tonumber(Config.Vehicle.GripMult) or 1, 1, 500)
Config.Vehicle.BrakeMult = math.clamp(tonumber(Config.Vehicle.BrakeMult) or 1, 1, 50)
Config.Vehicle.SteerMult = math.clamp(tonumber(Config.Vehicle.SteerMult) or 1, 1, 50)
Config.Vehicle.InstantShift = Config.Vehicle.InstantShift ~= false
Config.Vehicle.NoTires = Config.Vehicle.NoTires == true
Config.HUD.SpeedSize = math.clamp(tonumber(Config.HUD.SpeedSize) or 18, 10, 40)
Config.HUD.InfoSize = math.clamp(tonumber(Config.HUD.InfoSize) or 13, 8, 30)
Config.HUD.XOffset = math.clamp(tonumber(Config.HUD.XOffset) or 14, 0, 400)
Config.HUD.YOffset = math.clamp(tonumber(Config.HUD.YOffset) or 40, 0, 600)
Config.ESP.MaxDistance = math.clamp(tonumber(Config.ESP.MaxDistance) or 2000, 100, 10000)
Config.Farm.Steer = math.clamp(tonumber(Config.Farm.Steer) or 0, -1, 1)
Config.Race.HopDelay = math.clamp(tonumber(Config.Race.HopDelay) or 0.5, 0.5, 1.5)
Config.Race.SweepDist = math.clamp(tonumber(Config.Race.SweepDist) or 12, 6, 60)
Config.Race.PayoutBuffer = math.clamp(tonumber(Config.Race.PayoutBuffer) or 1, 0, 60)
Config.Race.CarLimitPad = math.clamp(tonumber(Config.Race.CarLimitPad) or 1.25, 1, 3)
Config.Race.AutoFarm = Config.Race.AutoFarm == true
Config.Race.AutoRequeue = Config.Race.AutoRequeue == true
Config.Misc.TeleportExec = Config.Misc.TeleportExec ~= false

-- ============================================================
-- SCREEN GUI + TOASTS
-- ============================================================
local screenGui
if UILib then
    screenGui = Instance.new("ScreenGui")
    screenGui.Name = "HavocHubDrivingEmpire"
    screenGui.ResetOnSpawn = false
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screenGui.DisplayOrder = 40
    screenGui.IgnoreGuiInset = true
    local ok = pcall(function()
        if gethui then
            screenGui.Parent = gethui()
        else
            screenGui.Parent = game:GetService("CoreGui")
        end
    end)
    if not ok then pcall(function() screenGui.Parent = LocalPlayer:WaitForChild("PlayerGui") end) end
end

local notify
if screenGui and UILib and UILib.makeToaster then
    notify = UILib.makeToaster(screenGui)
else
    notify = function(text) print("[Havoc Hub]", tostring(text)) end
end

-- ============================================================
-- GUI CONTROL REGISTRY + UILIB WIRING
-- ============================================================
local guiControls = {}
local function refreshGUI()
    for _, e in ipairs(guiControls) do
        if e.update then pcall(e.update) end
    end
end
local function addControl(e)
    table.insert(guiControls, e)
    return e
end

local rebuildKeyMap

if UILib then
    UILib.init{
        notify        = notify,
        save          = saveConfig,
        saveDebounced = saveConfigDebounced,
        onKeybindToggled = function()
            rebuildKeyMap(); saveConfig(); refreshGUI()
        end,
        onKeybindChanged = function(entry)
            rebuildKeyMap(); saveConfig(); refreshGUI()
            print(("[driving-empire] Rebound '%s' to %s"):format(entry.Desc, entry.Key.Name))
        end,
    }
    track(UILib.attachInput())
end

-- ============================================================
-- HOTKEYS
-- ============================================================
local keyMap = {}

local Hotkeys = {
    { Id = "ToggleMenu", Key = Enum.KeyCode.RightShift, Desc = "Toggle Menu", Enabled = true,
      Action = function()
          if screenGui then screenGui.Enabled = not screenGui.Enabled end
      end },

    { Id = "ToggleESP", Key = Enum.KeyCode.KeypadOne, Desc = "Toggle Player ESP", Enabled = true,
      Action = function()
          Config.ESP.Enabled = not Config.ESP.Enabled
          refreshGUI(); saveConfig()
          notify("Player ESP: " .. (Config.ESP.Enabled and "on" or "off"))
      end },
}

local hotkeyById = {}
for _, hk in ipairs(Hotkeys) do hotkeyById[hk.Id] = hk end

rebuildKeyMap = function()
    keyMap = {}
    for _, hk in ipairs(Hotkeys) do
        if hk.Enabled ~= false then keyMap[hk.Key] = hk end
    end
end
rebuildKeyMap()

-- ============================================================
-- VEHICLE MODULES + MULTIPLIER HOOKS
-- ============================================================
-- The game simulates the driven car on THIS client and asks the shared
-- ChassisUtils module for the engine/torque multipliers every frame. We
-- replace those two module fields with scaled versions; restoring the
-- originals fully reverts. Originals are kept in getgenv so re-executing
-- the script can never stack hooks on top of each other.
local vehicleHooks = (function()
    local g = type(getgenv) == "function" and getgenv() or _G
    if type(g.HavocDE_VehicleHooks) ~= "table" then g.HavocDE_VehicleHooks = {} end
    return g.HavocDE_VehicleHooks
end)()

local ChassisUtils, ClientVehicles, VehicleController
local Remotes, RaceUtil, RaceController, TeleportDetection
local ClientRaceHelper
local MatchmakingUtil
local VehicleStatTracker

local function waitPath(root, segments)
    local node = root
    for _, seg in ipairs(segments) do
        local child = node:FindFirstChild(seg)
        if not child then
            local ok, found = pcall(function() return node:WaitForChild(seg, 15) end)
            child = ok and found or nil
        end
        if not child then return nil end
        node = child
    end
    return node
end

-- INSTANT SHIFTING: the sim stages gear changes behind a shift timer
-- (Tune.ShiftUpTime * 0.8, with the clutch and throttle cut while
-- IsShifting). We finish the pending shift in the same frame it starts -
-- the gear snaps over, no wait, no cut. Wraps the module field; the true
-- original lives in getgenv so re-executes can't stack wrappers.
local function installTransmissionHooks()
    if not ChassisUtils or type(ChassisUtils.UpdateTransmission) ~= "function" then return end
    if type(vehicleHooks.origUpdateTransmission) ~= "function" then
        vehicleHooks.origUpdateTransmission = ChassisUtils.UpdateTransmission
    end
    local orig = vehicleHooks.origUpdateTransmission
    ChassisUtils.UpdateTransmission = function(chassis)
        orig(chassis)
        if Config.Vehicle.InstantShift and type(chassis) == "table" and chassis.IsShifting then
            chassis.ShiftEndTime = 0
            orig(chassis)
        end
    end
end

-- CHASSIS LOCK (the "wheels bug out when you go fast" guard): every frame
-- the sim freezes the whole chassis - pins the body AND every wheel's CFrame
-- back to last frame's position - once horizontal speed passes 3.5x the
-- car's TopSpeed (a client-side speed-hack tripwire). TopSpeed is rewritten
-- from the tune data at the top of every frame, so the bypass re-raises it
-- right before that check (see applyLockBypass below) and puts the stock
-- value back the moment the check has passed (this UpdateBoost wrapper -
-- UpdateBoost is the first thing called after it), leaving the rest of the
-- frame - gauges, boost doubling, drag - on the stock value.
local function installBoostRestore()
    if not ChassisUtils or type(ChassisUtils.UpdateBoost) ~= "function" then return end
    if type(vehicleHooks.origUpdateBoost) ~= "function" then
        vehicleHooks.origUpdateBoost = ChassisUtils.UpdateBoost
    end
    local orig = vehicleHooks.origUpdateBoost
    ChassisUtils.UpdateBoost = function(chassis, ...)
        if type(chassis) == "table" then
            local hold = chassis.__hubTopSpeedHold
            if hold ~= nil then
                chassis.TopSpeed = hold
                chassis.__hubTopSpeedHold = nil
            end
        end
        return orig(chassis, ...)
    end
end

-- RACE PROBE: the race client tells the server "I crossed checkpoint N"
-- through invokeServer("RaceCheckpoint", N) and reads the answer back
-- (ok, reason when rejected). Wrapping invokeServer lets the race assist
-- watch those answers - accepted, rejected (with the server's own reason),
-- or never sent (the game's crossing raycast didn't touch the checkpoint).
local raceProbe = { seq = 0 }
local function installInvokeProbe()
    if not Remotes or type(Remotes.invokeServer) ~= "function" then return end
    if type(vehicleHooks.origInvokeServer) ~= "function" then
        vehicleHooks.origInvokeServer = Remotes.invokeServer
    end
    local orig = vehicleHooks.origInvokeServer
    Remotes.invokeServer = function(name, ...)
        local args = table.pack(...)
        local ret = table.pack(orig(name, table.unpack(args, 1, args.n)))
        if name == "RaceCheckpoint" or name == "RaceFinishLine" then
            raceProbe.seq = raceProbe.seq + 1
            raceProbe.kind = (name == "RaceFinishLine") and "finish" or "cp"
            raceProbe.num = args[1]
            raceProbe.ok = ret[1] and true or false
            raceProbe.reason = ret[2]
        end
        return table.unpack(ret, 1, ret.n)
    end
end

-- FIRE PROBE: count the game's race-recording uploads (RaceRecordUploadStart/
-- Chunk fire when a race ends) so the post-race report can say whether the
-- server even received a recording of the run.
local raceReport = { uploads = 0, chunks = 0 }
local function installFireProbe()
    if not Remotes or type(Remotes.fireServer) ~= "function" then return end
    if type(vehicleHooks.origFireServer) ~= "function" then
        vehicleHooks.origFireServer = Remotes.fireServer
    end
    local orig = vehicleHooks.origFireServer
    Remotes.fireServer = function(name, ...)
        if name == "RaceRecordUploadStart" then
            raceReport.uploads = raceReport.uploads + 1
        elseif name == "RaceRecordUploadChunk" then
            raceReport.chunks = raceReport.chunks + 1
        end
        return orig(name, ...)
    end
end

-- RACE RESULT PROBE: when the server finalizes a racer it fires RaceFinished
-- on ReplicatedStorage.Remotes (decoded from the game's own client code,
-- tbl.ReceivedFinishTime): raceId uuid, userId, final time, best lap, racer
-- count, extra cash, placement, metadata. The results screen row and the
-- victory sound are driven by this event - a row stuck on "TBD" means it
-- never arrived for you, and the server withholds the payout for runs it
-- refuses to finalize. Capturing it makes the post-race report conclusive.
local raceResult = { at = nil, userId = nil, time = nil, bestLap = nil, racers = nil, extra = nil, place = nil, mine = false }
local raceResultToast = nil  -- assigned lower down, once notify() exists
local function installRaceFinishedProbe()
    local ev = waitPath(ReplicatedStorage, { "Remotes", "RaceFinished" })
    if not ev or not ev.OnClientEvent then return end
    if vehicleHooks.raceFinishedConn then
        pcall(function() vehicleHooks.raceFinishedConn:Disconnect() end)
    end
    vehicleHooks.raceFinishedConn = ev.OnClientEvent:Connect(function(...)
        local a = table.pack(...)
        raceResult.at = os.clock()
        raceResult.userId = a[2]
        raceResult.time = tonumber(a[3])
        raceResult.bestLap = tonumber(a[4])
        raceResult.racers = tonumber(a[5])
        raceResult.extra = tonumber(a[6])
        raceResult.place = tonumber(a[7])
        raceResult.mine = (LocalPlayer ~= nil and a[2] == LocalPlayer.UserId)
        print(("[driving-empire] RaceFinished: race=%s user=%s final=%ss bestLap=%ss racers=%s extraCash=%s place=%s meta=%s"):format(
            tostring(a[1]), tostring(a[2]), tostring(a[3]), tostring(a[4]),
            tostring(a[5]), tostring(a[6]), tostring(a[7]), tostring(a[8])))
        if raceResult.mine and raceResultToast then
            pcall(raceResultToast, raceResult.time, raceResult.bestLap, raceResult.racers, raceResult.place)
        end
    end)
end

-- RACE CLOCK: every racing-loop tick the client pushes the race's live HUD
-- info (elapsed time, current lap, total laps, NEXT expected gate) through
-- ClientRaceHelper.updateTrackInfo. Wrapping it gives the assist an exact
-- race timer (for the payout hold) plus the authoritative lap count and lap
-- position (for correct floors, and for restarting mid-race).
local raceClock = { time = nil, at = nil, laps = nil, lap = nil, nextCp = nil, epoch = 0 }
local function installRaceClockHook()
    if not ClientRaceHelper or type(ClientRaceHelper.updateTrackInfo) ~= "function" then return end
    if type(vehicleHooks.origUpdateTrackInfo) ~= "function" then
        vehicleHooks.origUpdateTrackInfo = ClientRaceHelper.updateTrackInfo
    end
    local orig = vehicleHooks.origUpdateTrackInfo
    ClientRaceHelper.updateTrackInfo = function(info, ...)
        if type(info) == "table" then
            if tonumber(info.Time) then
                raceClock.time = tonumber(info.Time)
                raceClock.at = os.clock()
            end
            local tl = tonumber(info.TotalLaps)
            if tl and tl > 0 then raceClock.laps = tl end
            local cl = tonumber(info.CurrentLap)
            if cl then raceClock.lap = cl end
            if info.Checkpoint ~= nil then raceClock.nextCp = info.Checkpoint end
        elseif info == nil then
            -- the race UI got torn down (race over / left) - forget it all
            raceClock.time, raceClock.at = nil, nil
            raceClock.laps, raceClock.lap, raceClock.nextCp = nil, nil, nil
            raceClock.epoch = (raceClock.epoch or 0) + 1
        end
        return orig(info, ...)
    end
end

-- AUTO-FARM shared state ("Race auto-farm" in the Money tab): the farm
-- loop near the race systems reads it; watchRacePayout marks done runs.
local farmRace = { epoch = -1, attempts = 0, lastAttempt = 0, finished = false,
    wasRacing = false, raceSeenAt = nil, pendingAt = nil, lastJoinAt = 0,
    rejoinTries = 0, lastTrack = nil, lastMode = nil }

-- Current race time in seconds (nil when no live reading is available).
local function raceElapsed()
    if raceClock.time and raceClock.at then
        local extra = os.clock() - raceClock.at
        if extra >= 0 and extra < 300 then
            return raceClock.time + extra
        end
    end
    return nil
end

local function initVehicleModules()
    if not ChassisUtils then
        local node = waitPath(ReplicatedStorage, { "Modules", "Shared", "Vehicles", "ChassisUtils" })
        if node then
            local ok, res = pcall(require, node)
            if ok and type(res) == "table" then ChassisUtils = res end
        end
    end
    if not ClientVehicles then
        local node = waitPath(ReplicatedStorage, { "Modules", "Client", "Vehicles", "ClientVehicles" })
        if node then
            local ok, res = pcall(require, node)
            if ok and type(res) == "table" then ClientVehicles = res end
        end
    end
    if not VehicleController then
        local node = waitPath(ReplicatedStorage, { "Modules", "Client", "Vehicles", "VehicleController" })
        if node then
            local ok, res = pcall(require, node)
            if ok and type(res) == "table" then VehicleController = res end
        end
    end
    if not Remotes then
        local node = waitPath(ReplicatedStorage, { "Modules", "Shared", "Remotes" })
        if node then
            local ok, res = pcall(require, node)
            if ok and type(res) == "table" then Remotes = res end
        end
    end
    if not RaceUtil then
        local node = waitPath(ReplicatedStorage, { "Modules", "Shared", "Races", "RaceUtil" })
        if node then
            local ok, res = pcall(require, node)
            if ok and type(res) == "table" then RaceUtil = res end
        end
    end
    if not RaceController then
        local node = waitPath(ReplicatedStorage, { "Modules", "Client", "Races", "RaceController" })
        if node then
            local ok, res = pcall(require, node)
            if ok and type(res) == "table" then RaceController = res end
        end
    end
    if not TeleportDetection then
        local node = waitPath(ReplicatedStorage, { "Modules", "Client", "Exploit", "VehicleTeleportDetectionController" })
        if node then
            local ok, res = pcall(require, node)
            if ok and type(res) == "table" then TeleportDetection = res end
        end
    end
    if not ClientRaceHelper then
        local node = waitPath(ReplicatedStorage, { "Modules", "Client", "Races", "ClientRaceHelper" })
        if node then
            local ok, res = pcall(require, node)
            if ok and type(res) == "table" then ClientRaceHelper = res end
        end
    end
    if not MatchmakingUtil then
        local node = waitPath(ReplicatedStorage, { "Modules", "Shared", "Matchmaking", "MatchmakingUtil" })
        if node then
            local ok, res = pcall(require, node)
            if ok and type(res) == "table" then MatchmakingUtil = res end
        end
    end
    if not VehicleStatTracker then
        local node = waitPath(ReplicatedStorage, { "Modules", "Client", "Vehicles", "VehicleStatTracker" })
        if node then
            local ok, res = pcall(require, node)
            if ok and type(res) == "table" then VehicleStatTracker = res end
        end
    end
    installInvokeProbe()
    installFireProbe()
    installRaceFinishedProbe()
    installRaceClockHook()
    if ChassisUtils then
        if not vehicleHooks.origSpeed then
            vehicleHooks.origSpeed = ChassisUtils.GetSpeedMult
            vehicleHooks.origTorque = ChassisUtils.GetTorqueMult
            vehicleHooks.speedFactor = 1
            vehicleHooks.torqueFactor = 1
        end
        installTransmissionHooks()
        installBoostRestore()
        return true
    end
    return false
end

local function setSpeedFactor(f)
    if not ChassisUtils then return end
    if f == vehicleHooks.speedFactor then return end
    if f == 1 then
        ChassisUtils.GetSpeedMult = vehicleHooks.origSpeed
    else
        local orig, factor = vehicleHooks.origSpeed, f
        ChassisUtils.GetSpeedMult = function(...)
            return orig(...) * factor
        end
    end
    vehicleHooks.speedFactor = f
end

local function setTorqueFactor(f)
    if not ChassisUtils then return end
    if f == vehicleHooks.torqueFactor then return end
    if f == 1 then
        ChassisUtils.GetTorqueMult = vehicleHooks.origTorque
    else
        local orig, factor = vehicleHooks.origTorque, f
        ChassisUtils.GetTorqueMult = function(...)
            return orig(...) * factor
        end
    end
    vehicleHooks.torqueFactor = f
end

local function getActiveChassis()
    if not VehicleController or type(VehicleController.getActiveChassisController) ~= "function" then
        return nil
    end
    local ok, chassis = pcall(VehicleController.getActiveChassisController)
    return ok and chassis or nil
end

local function getLocalVehicleModel()
    if not ClientVehicles then return nil end
    local ok, veh = pcall(function() return ClientVehicles.GetVehicleFromDriver(LocalPlayer) end)
    if ok and veh and veh.Object then return veh.Object end
    return nil
end

local function getLocalVehicleObject()
    if not ClientVehicles then return nil end
    local ok, veh = pcall(function() return ClientVehicles.GetVehicleFromDriver(LocalPlayer) end)
    if ok and veh then return veh end
    return nil
end

-- The reliable handle on the car you are driving: the active chassis
-- controller owns the same vehicle object the sim uses, and it is available
-- even where the driver-seat lookup comes up empty (e.g. races).
local function getDrivenVehicle()
    local chassis = getActiveChassis()
    if chassis and chassis.VehicleObject then return chassis.VehicleObject end
    return getLocalVehicleObject()
end

-- Tell the game's own teleport detector that a car teleport is coming - this
-- is exactly what the game does before its own vehicle teleports (respawns,
-- race exits), so ours don't read as unexplained position jumps.
local function authorizeTeleport()
    if TeleportDetection and type(TeleportDetection.AuthorizeNextTeleport) == "function" then
        pcall(TeleportDetection.AuthorizeNextTeleport)
    end
end

-- Move the driven car. Mirrors the game's own onVehicleTeleport: zero the
-- velocity of every part, authorize the jump, then move via the weight part.
local function teleportCarTo(target)
    local veh = getDrivenVehicle()
    if not veh or not veh.Object then return false end
    local model = veh.Object
    local weight = veh.Components and veh.Components.Weight
    local ok = pcall(function()
        for _, d in ipairs(model:GetDescendants()) do
            if d:IsA("BasePart") then
                d.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
            end
        end
        authorizeTeleport()
        if weight and model.PrimaryPart ~= weight then
            model.PrimaryPart = weight
        end
        model:PivotTo(target)
        for _, d in ipairs(model:GetDescendants()) do
            if d:IsA("BasePart") then
                d.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
            end
        end
    end)
    return ok
end

initVehicleModules()
setSpeedFactor(Config.Vehicle.SpeedMult)
setTorqueFactor(Config.Vehicle.TorqueMult)

-- The modules can be missing for a moment right after a sub-place join.
task.spawn(function()
    for _ = 1, 30 do
        if initVehicleModules() then
            setSpeedFactor(Config.Vehicle.SpeedMult)
            setTorqueFactor(Config.Vehicle.TorqueMult)
            break
        end
        task.wait(1)
    end
end)

-- GRIP: the chassis controllers read `ExternalGripMultiplier` every frame
-- (Generic + Motorcycle: wheel traction and friction weight). The game's own
-- zones touch it too, so we use the controller's setter, remember what it
-- was before we overrode it, and put that back when grip returns to 1x or
-- the driven car changes.
local gripState = { chassis = nil, original = nil }

local function setChassisGrip(chassis, value)
    if type(chassis.SetExternalGripMultiplier) == "function" then
        pcall(function() chassis:SetExternalGripMultiplier(value) end)
    else
        pcall(function() chassis.ExternalGripMultiplier = value end)
    end
end

local function restoreGrip(state)
    if state.chassis then
        setChassisGrip(state.chassis, state.original)
        state.chassis = nil
        state.original = nil
    end
end

local function applyGrip(chassis)
    if not chassis then return end
    local g = Config.Vehicle.GripMult
    if g ~= 1 then
        if gripState.chassis ~= chassis then
            restoreGrip(gripState)   -- car switched: undo on the old one first
            gripState.chassis = chassis
            gripState.original = chassis.ExternalGripMultiplier
        end
        if chassis.ExternalGripMultiplier ~= g then
            setChassisGrip(chassis, g)
        end
    elseif gripState.chassis then
        restoreGrip(gripState)
    end
end

-- BRAKE: the sim multiplies brake torque by PerformanceUpgrades.BrakeMult
-- when braking (Generic + Motorcycle). Scale it in place; the true base is
-- kept under a marker key so the written value is always base * factor and
-- survives the game rebuilding the table (a fresh table re-captures its
-- own base). Factor 1 restores the base.
local function applyBrake(chassis)
    if not chassis then return end
    local pu = chassis.PerformanceUpgrades
    if type(pu) ~= "table" then return end
    local base = pu.__hubBrakeBase
    if base == nil then
        base = tonumber(pu.BrakeMult) or 1
        pu.__hubBrakeBase = base
    end
    local want = base * Config.Vehicle.BrakeMult
    if pu.BrakeMult ~= want then pu.BrakeMult = want end
end

-- STEER: the sim scales the wheel steer angle by
-- performanceConfig.TurnRadiusMult (angle = Tune.TurnRadius * TurnRadiusMult
-- * input), so scaling that field scales how hard the car turns. Same
-- marker-key base trick as the brake multiplier.
local function applySteer(chassis)
    if not chassis then return end
    local pc = chassis.performanceConfig
    if type(pc) ~= "table" then return end
    local base = pc.__hubSteerBase
    if base == nil then
        base = tonumber(pc.TurnRadiusMult) or 1
        pc.__hubSteerBase = base
    end
    local want = base * Config.Vehicle.SteerMult
    if pc.TurnRadiusMult ~= want then pc.TurnRadiusMult = want end
end

-- CHASSIS LOCK BYPASS: see installBoostRestore above. UpdateBrakeDiscHeating
-- runs in the sim immediately before the 3.5x-speed freeze check (it is the
-- only hook point between the TopSpeed rewrite and that check), so bumping
-- TopSpeed here - just for the check - keeps the anti-speed-hack freeze from
-- ever tripping, no matter how fast the multipliers take the car.
local function applyLockBypass(chassis)
    if type(chassis) ~= "table" or chassis.__hubLockBypass then return end
    local orig = chassis.UpdateBrakeDiscHeating
    if type(orig) ~= "function" then return end
    chassis.__hubLockBypass = true
    chassis.UpdateBrakeDiscHeating = function(self, ...)
        if type(self) == "table" then
            local vo = self.VehicleObject
            local weight = vo and vo.Components and vo.Components.Weight
            local vel = weight and (weight.AssemblyLinearVelocity or weight.Velocity)
            local top = tonumber(self.TopSpeed)
            if vel and top then
                local h = (vel * Vector3.new(1, 0, 1)).Magnitude
                if top * 3.5 < h then
                    self.__hubTopSpeedHold = top
                    self.TopSpeed = h / 3.3
                end
            end
        end
        return orig(self, ...)
    end
end

-- REMOVE TIRES: hides the wheel visuals and drops the wheels' collision on
-- the player's current car (wheels come from the vehicle object's own
-- Cache.Wheels - each entry has Wheel = the physics wheel part, and the
-- visual rim/tire parts live in the wheel unit's "Parts" folder). Fully
-- reversible: every part's original look is remembered until switched off.
local tireState = { veh = nil, parts = {} }

local function restoreTires()
    for _, p in ipairs(tireState.parts) do
        if p and p.Parent and p.__hubTire then
            p.Transparency = p.__hubTire.t
            p.CanCollide = p.__hubTire.c
            p.__hubTire = nil
        end
    end
    tireState.parts = {}
    tireState.veh = nil
end

local function applyTires()
    if not Config.Vehicle.NoTires then
        if tireState.veh or #tireState.parts > 0 then restoreTires() end
        return
    end
    local veh = getDrivenVehicle()
    if not veh then
        if tireState.veh then restoreTires() end
        return
    end
    if tireState.veh ~= veh then
        restoreTires()
        tireState.veh = veh
    end
    local cache = veh.Cache
    local wheels = cache and cache.Wheels
    if type(wheels) ~= "table" then return end
    local function addPart(p)
        if p == nil then return end
        local isOk, isPart = pcall(function() return p:IsA("BasePart") end)
        if not isOk or not isPart then return end
        if p.__hubTire == nil then
            p.__hubTire = { t = p.Transparency, c = p.CanCollide }
            table.insert(tireState.parts, p)
        end
        if p.Transparency ~= 1 then p.Transparency = 1 end
        if p.CanCollide then p.CanCollide = false end
    end
    for _, w in ipairs(wheels) do
        local wheelPart = w.Wheel
        addPart(wheelPart)
        local unit = wheelPart and wheelPart.Parent
        local vis = unit and unit:FindFirstChild("Parts")
        if vis then
            for _, p in ipairs(vis:GetDescendants()) do addPart(p) end
        end
        if type(w.Tires) == "table" then
            for _, p in ipairs(w.Tires) do addPart(p) end
        end
    end
end

-- ============================================================
-- FEATURES: SPEEDOMETER HUD
-- ============================================================
local hud = { ready = false, broken = false, speed = nil, info = nil, cash = nil }

local function ensureHud()
    if hud.ready or hud.broken then return hud.ready end
    local ok = pcall(function()
        local function mkText(size, color)
            local t = Drawing.new("Text")
            t.Center = false
            t.Outline = true
            t.OutlineColor = Color3.new(0, 0, 0)
            t.Color = color
            t.Transparency = 1   -- this executor's Drawing: 1 = fully visible
            t.Size = size
            t.Visible = false
            t.Font = Drawing.Fonts.UI
            return t
        end
        hud.speed = mkText(Config.HUD.SpeedSize, Color3.fromRGB(120, 220, 255))
        hud.info = mkText(Config.HUD.InfoSize, Color3.fromRGB(210, 210, 220))
        hud.cash = mkText(Config.HUD.InfoSize + 1, Color3.fromRGB(120, 230, 140))
        hud.ready = true
    end)
    if not ok then hud.broken = true end
    return hud.ready
end

local function getCash()
    local ls = LocalPlayer:FindFirstChild("leaderstats")
    local cash = ls and ls:FindFirstChild("Cash")
    return cash and cash.Value or nil
end

local function formatCash(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local rev = s:reverse():gsub("(%d%d%d)", "%1,")
    rev = rev:reverse()
    if rev:sub(1, 1) == "," then rev = rev:sub(2) end
    return "$" .. rev
end

local function updateHud(chassis)
    if not ensureHud() then return end
    local cam = workspace.CurrentCamera
    if not cam then return end
    local vp = cam.ViewportSize

    local lineY = Config.HUD.YOffset
    local showSpeed = Config.HUD.Enabled and chassis ~= nil
    if showSpeed then
        local speedText = ("%d MPH"):format(math.floor((chassis.SpeedMPH or 0) + 0.5))
        local infoText = ("Gear %d  |  %d RPM"):format(chassis.Gear or 0, math.floor((chassis.RPM or 0) + 0.5))

        hud.speed.Text = speedText
        hud.speed.Size = Config.HUD.SpeedSize
        hud.info.Text = infoText
        hud.info.Size = Config.HUD.InfoSize

        local w1 = 0
        pcall(function() w1 = hud.speed.TextBounds.X end)
        if w1 <= 0 then w1 = #speedText * Config.HUD.SpeedSize * 0.62 end
        hud.speed.Position = Vector2.new(vp.X - Config.HUD.XOffset - w1, lineY)

        local w2 = 0
        pcall(function() w2 = hud.info.TextBounds.X end)
        if w2 <= 0 then w2 = #infoText * Config.HUD.InfoSize * 0.62 end
        hud.info.Position = Vector2.new(vp.X - Config.HUD.XOffset - w2,
            lineY + Config.HUD.SpeedSize + 4)
        lineY = lineY + Config.HUD.SpeedSize + 4 + Config.HUD.InfoSize + 6
    end
    hud.speed.Visible = showSpeed
    hud.info.Visible = showSpeed

    local cashValue = getCash()
    local showCash = Config.Money.ShowHud and cashValue ~= nil
    if showCash then
        local cashText = formatCash(cashValue)
        hud.cash.Text = cashText
        hud.cash.Size = Config.HUD.InfoSize + 1
        local w3 = 0
        pcall(function() w3 = hud.cash.TextBounds.X end)
        if w3 <= 0 then w3 = #cashText * (Config.HUD.InfoSize + 1) * 0.62 end
        hud.cash.Position = Vector2.new(vp.X - Config.HUD.XOffset - w3, lineY)
    end
    hud.cash.Visible = showCash
end

-- ============================================================
-- FEATURES: FULLBRIGHT / ANTI-AFK
-- ============================================================
local fullbrightOriginals = nil

local function setFullbright(on)
    if on then
        if not fullbrightOriginals then
            fullbrightOriginals = {
                Ambient = Lighting.Ambient,
                OutdoorAmbient = Lighting.OutdoorAmbient,
                Brightness = Lighting.Brightness,
                ClockTime = Lighting.ClockTime,
                GlobalShadows = Lighting.GlobalShadows,
                FogEnd = Lighting.FogEnd,
            }
        end
        Lighting.Ambient = Color3.fromRGB(178, 178, 178)
        Lighting.OutdoorAmbient = Color3.fromRGB(178, 178, 178)
        Lighting.Brightness = 3
        Lighting.ClockTime = 14
        Lighting.GlobalShadows = false
        Lighting.FogEnd = 100000
    elseif fullbrightOriginals then
        for k, v in pairs(fullbrightOriginals) do
            pcall(function() Lighting[k] = v end)
        end
        fullbrightOriginals = nil
    end
end

track(LocalPlayer.Idled:Connect(function()
    if Config.Misc.AntiAFK then
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end
end))

-- ============================================================
-- FEATURES: PLAYER ESP  (rendering lives in espui.luau)
-- ============================================================
local espRenderer = ESPUI and ESPUI.newRenderer(function() return Config.ESP end)

local function colorForPlayer(player)
    if player.Team and LocalPlayer.Team and player.Team ~= LocalPlayer.Team then
        return player.Team.TeamColor.Color
    end
    if player.Team and player.Team == LocalPlayer.Team then
        return Color3.fromRGB(82, 202, 128)
    end
    return Color3.fromRGB(255, 80, 80)
end

local function espVisible(char, camPos, targetPos)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = { char }
    if LocalPlayer.Character then table.insert(ignore, LocalPlayer.Character) end
    local cam = workspace.CurrentCamera
    if cam then table.insert(ignore, cam) end
    params.FilterDescendantsInstances = ignore
    return workspace:Raycast(camPos, targetPos - camPos, params) == nil
end

local function buildSkeletonJoints(char)
    local function partPos(...)
        for _, name in ipairs({ ... }) do
            local p = char:FindFirstChild(name)
            if p and p:IsA("BasePart") then return p.Position end
        end
        return nil
    end
    return {
        Head = partPos("Head"),
        Torso = partPos("UpperTorso", "Torso", "HumanoidRootPart"),
        LeftHand = partPos("LeftHand", "Left Arm"),
        RightHand = partPos("RightHand", "Right Arm"),
        LeftFoot = partPos("LeftFoot", "Left Leg"),
        RightFoot = partPos("RightFoot", "Right Leg"),
    }
end

local function renderESP(cam)
    if not espRenderer then return end
    local cfg = Config.ESP
    if not cfg.Enabled then
        espRenderer:render({}, cam)
        return
    end

    local camPos = cam.CFrame.Position
    local targets = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            local char = player.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            local hrp = char and (char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart)
            local head = char and char:FindFirstChild("Head")
            if hum and hum.Health > 0 and hrp then
                local teamBlocked = cfg.TeamCheck and player.Team and LocalPlayer.Team
                    and player.Team == LocalPlayer.Team
                local dist = (hrp.Position - camPos).Magnitude
                if not teamBlocked and dist <= cfg.MaxDistance then
                    local headPos = head and head.Position or (hrp.Position + Vector3.new(0, 1.5, 0))
                    local pass = true
                    if cfg.VisibleOnly then
                        local ok, visible = pcall(espVisible, char, camPos, headPos)
                        pass = ok and visible
                    end
                    if pass then
                        table.insert(targets, {
                            key = player,
                            model = char,
                            name = cfg.NameSource == "DisplayName" and player.DisplayName or player.Name,
                            health = hum.Health,
                            maxHealth = hum.MaxHealth > 0 and hum.MaxHealth or 100,
                            headPos = headPos,
                            topPos = headPos + Vector3.new(0, 0.6, 0),
                            bottomPos = hrp.Position - Vector3.new(0, 3.2, 0),
                            distance = dist,
                            teamColor = colorForPlayer(player),
                            lookDir = head and head.CFrame.LookVector,
                            skel = cfg.Skeleton and buildSkeletonJoints(char) or nil,
                        })
                    end
                end
            end
        end
    end
    espRenderer:render(targets, cam)
end

-- ============================================================
-- FEATURES: TELEPORTS
-- ============================================================
-- Target parts are found at RUNTIME by name (first BasePart match), so this
-- keeps working regardless of where the map keeps them. Names come straight
-- from the structure dump.
local TELEPORTS = {
    { label = "Race Hub",        part = "raceHub" },
    { label = "Main Dealership", part = "mainDealer" },
    { label = "Aviation Garage", part = "garageAviation" },
    { label = "Boat Garage",     part = "garageBoat" },
    { label = "Drag Strip",      part = "dragPAD" },
    { label = "Bank",            part = "bank" },
    { label = "Police Station",  part = "policeStation" },
    { label = "Drawbridge",      part = "drawbridge" },
}

local teleportCache = {}

local function findPart(name)
    local cached = teleportCache[name]
    if cached and cached.Parent then return cached end
    teleportCache[name] = nil
    local found = nil
    local ok = pcall(function()
        for _, d in ipairs(workspace:GetDescendants()) do
            if d:IsA("BasePart") and d.Name == name then
                found = d
                break
            end
        end
    end)
    if ok and found then
        teleportCache[name] = found
        return found
    end
    return nil
end

local function teleportTo(partName, label)
    local part = findPart(partName)
    if not part then
        notify(label .. ": location not found (move around a bit and retry)")
        return
    end
    local target = part.CFrame * CFrame.new(0, 4, 0)

    -- Seated? move the whole car (the character is welded to it).
    local vehModel = getLocalVehicleModel()
    if vehModel then
        if teleportCarTo(target) then
            notify("Teleported to " .. label)
            return
        end
    end

    local char = LocalPlayer.Character
    if char then
        local ok = pcall(function() char:PivotTo(target) end)
        if ok then
            notify("Teleported to " .. label)
            return
        end
    end
    notify("Teleport failed")
end

-- ============================================================
-- MONEY  (cash display only - the NASCAR cash-drop collect attempt was
-- removed: the server validates those drops, so remote-fired collects
-- never awarded anything)
-- ============================================================

-- ============================================================
-- FEATURES: AUTO FARM  (driving income - scales with speed)
-- ============================================================
-- The chassis physics ask InputController.Get() for throttle/steer every
-- frame. Replacing that module field with a wrapper lets the farm hold full
-- throttle (plus an optional steer bias for circling). The true original is
-- kept in the getgenv hook registry, so re-executing can't stack wrappers.
local InputController
local farmState = { cashStart = 0, stuckSince = nil, recoverUntil = 0 }

local function farmInputOverride()
    if not Config.Farm.Enabled then return nil end
    if os.clock() < farmState.recoverUntil then
        return -1, -Config.Farm.Steer
    end
    return 1, Config.Farm.Steer
end

local function initFarmHook()
    if not InputController then
        local node = waitPath(ReplicatedStorage, { "Modules", "Client", "Vehicles", "InputController" })
        if node then
            local ok, res = pcall(require, node)
            if ok and type(res) == "table" then InputController = res end
        end
    end
    if not InputController then return false end
    if not vehicleHooks.origInputGet then
        vehicleHooks.origInputGet = InputController.Get
    end
    local orig = vehicleHooks.origInputGet
    InputController.Get = function()
        local throttle, steer = orig()
        local by, bs = farmInputOverride()
        if by then return by, bs end
        return throttle, steer
    end
    return true
end

-- Stuck detection: no movement for a few seconds while farming -> reverse
-- for 2s (with reversed steer) so the car backs off whatever it hit.
local function farmTick(chassis)
    if not Config.Farm.Enabled then
        farmState.stuckSince = nil
        return
    end
    local speed = chassis and chassis.Speed or 0
    if chassis and speed < 5 then
        farmState.stuckSince = farmState.stuckSince or os.clock()
        if (os.clock() - farmState.stuckSince) > 3.5 and os.clock() > farmState.recoverUntil then
            farmState.recoverUntil = os.clock() + 2
            farmState.stuckSince = nil
        end
    else
        farmState.stuckSince = nil
    end
end

initFarmHook()
task.spawn(function()
    for _ = 1, 30 do
        if initFarmHook() then break end
        task.wait(1)
    end
end)

-- ============================================================
-- FEATURES: RACE ASSIST  (take every checkpoint, then the finish line)
-- ============================================================
-- The game's own race client detects a checkpoint crossing by raycasting
-- from the car's front corners across the movement of the last frame - so
-- jumping the car from one side of a checkpoint to the other reads as a
-- crossing, and the game itself reports it to the server, in order. The
-- routine walks the car through every checkpoint of the race you are in
-- (the order matters - the server rejects wrong checkpoints), watches the
-- server's answers through the invokeServer probe, then jumps the finish
-- line. Failures surface the server's own rejection reason.
local raceBusy = false

local function findRaceTrackModel()
    local g = workspace:FindFirstChild("Game")
    local races = g and g:FindFirstChild("Races")
    if not races then return nil end
    local function isTrack(m)
        return m:IsA("Model") and m:FindFirstChild("Checkpoints") and m:FindFirstChild("Finish")
    end
    -- the live track normally sits in Races.LocalSession - scan broadly so a
    -- different container layout still gets found
    local session = races:FindFirstChild("LocalSession")
    if session then
        for _, m in ipairs(session:GetChildren()) do
            if isTrack(m) then return m end
        end
    end
    for _, d in ipairs(races:GetDescendants()) do
        if isTrack(d) then return d end
    end
    return nil
end

local function trackEntryPart(entry)
    if entry:IsA("BasePart") then return entry end
    return entry.PrimaryPart or entry:FindFirstChildWhichIsA("BasePart")
end

local function raceTrackInfo(model)
    if not RaceUtil then return nil, nil, nil end
    local names = { model.Name }
    if RaceController then
        local ok, decoded = pcall(function()
            local s = RaceController.getRaceDataString(LocalPlayer)
            return s and RaceUtil.decodeRaceData(s) or nil
        end)
        if ok and decoded and decoded.Checkpoint and decoded.Checkpoint.TrackName then
            table.insert(names, decoded.Checkpoint.TrackName)
        end
    end
    for _, nm in ipairs(names) do
        local ok, res = pcall(function() return RaceUtil.getTrackInfo(nm) end)
        if ok and res then
            local laps = tonumber(res.MaxLaps)
            local minTime = tonumber(res.MinTimeSeconds)
            if laps or minTime then
                return laps, minTime, nm
            end
        end
    end
    return nil, nil, nil
end

-- "1.5" style below 10s, whole seconds above (150, not 150.0)
local function fmtSecs(v)
    if v >= 10 then return tostring(math.floor(v)) end
    return tostring(math.round(v * 10) / 10)
end

-- The server also sanity-checks finish times against the car: your finish
-- can't be faster than the track physically allows at that car's top speed.
-- Compute that floor from the track's checkpoint distances + the car's tune
-- (plus a safety pad) so the assist never crosses before it looks possible.
local function carAwareMinTime(chassis, trackModel, laps)
    if not RaceUtil or type(RaceUtil.getTrackModelData) ~= "function" then return nil end
    local ok, data = pcall(RaceUtil.getTrackModelData, trackModel)
    if not ok or type(data) ~= "table" or type(data.Distances) ~= "table" then return nil end
    local d = data.Distances
    local spawns = data.Spawnpoints or {}
    local cps = data.Checkpoints or {}
    local length = (d.SpawnToFirst and d.SpawnToFirst[#spawns] or 0)
        + math.clamp(laps or 1, 1, 20) * (d.Lap or 0)
        - ((d.ToNextCheckpoint and d.ToNextCheckpoint[#cps]) or 0)
        + (d.LastToFinish or 0)
    if length <= 0 then return nil end
    local topMPH = 180
    if chassis and chassis.Tune and type(chassis.Tune.TransmissionSpeeds) == "table" then
        local t = chassis.Tune.TransmissionSpeeds
        local v = tonumber(t[#t])
        if v and v > 0 then topMPH = v end
    end
    -- The game's own chassis math: speed in studs/s is the tune top x2
    -- (EngineSpeed*2 feeds WheelSpeed; the gear-find compares tune*mult*2
    -- to velocity; boost doubles TopSpeed again). x2, not x1.6.
    local topStuds = math.clamp(topMPH * 2, 100, 1200)
    local pad = Config.Race.CarLimitPad or 1.25
    local floorTime = (length / topStuds) * pad
    print(("[driving-empire] car limit: track %.0f studs, car top %.0f (=%.0f studs/s), floor %.1fs (pad %.2f)"):format(length, topMPH, topStuds, floorTime, pad))
    return floorTime
end

-- The finish result the server receives includes the car's recorded top
-- speed (VehicleStatTracker). Teleport runs never actually move fast, so
-- that reading stays near zero - which can look impossible for the finish
-- time and get the payout withheld. Report the car's true tune top speed
-- instead (a number the car could really do), so the run stays plausible.
local function legitimizeVehicleStats(chassis)
    if not VehicleStatTracker or type(VehicleStatTracker.get) ~= "function" then return end
    local ok, stats = pcall(VehicleStatTracker.get)
    if not ok or type(stats) ~= "table" then return end
    local top = 180
    if chassis and chassis.Tune and type(chassis.Tune.TransmissionSpeeds) == "table" then
        local t = chassis.Tune.TransmissionSpeeds
        local v = tonumber(t[#t])
        if v and v > 0 then top = v end
    end
    local plausible = math.clamp(top * 2, 120, 1000)  -- tune top x2 -> studs/s (game's own relation)
    if type(stats.TopSpeedVectorMagnitude) == "number" and stats.TopSpeedVectorMagnitude < plausible then
        stats.TopSpeedVectorMagnitude = plausible
    end
end

-- Toast hook for the RaceFinished probe (installed at load; assigned
-- here because notify() only exists from this point down).
raceResultToast = function(time, bestLap, racers, place)
    notify(("Server finalized your result: place %s, %ss (best lap %ss, %s racers)"):format(
        tostring(place or "?"), fmtSecs(time or 0), fmtSecs(bestLap or 0), tostring(racers or "?")))
end

-- Watch leaderstats.Cash after a finished race and report when the payout
-- actually lands (or that it never came). Also reports whether the game
-- uploaded its race recording, how many players were in the session, and
-- whether the server FINALIZED our result - RaceFinished never arriving is
-- the "TBD" results screen (and why a withheld payout never lands).
local function watchRacePayout()
    farmRace.finished = true  -- the auto-farm loop knows this race is done
    local before = getCash()
    local here = #Players:GetPlayers()
    local uploads0, chunks0 = raceReport.uploads, raceReport.chunks
    local result0 = raceResult.at
    task.spawn(function()
        task.wait(15)  -- the recording upload fires right after the finish
        local uploads = raceReport.uploads - uploads0
        local chunks = raceReport.chunks - chunks0
        local uploaded = uploads > 0 and ("yes (%d chunks)"):format(chunks) or "NO"
        local gotResult = raceResult.at ~= result0 and raceResult.mine == true
        local finalized = gotResult
            and ("yes (place %s, %ss, %s racers)"):format(tostring(raceResult.place), fmtSecs(raceResult.time or 0), tostring(raceResult.racers))
            or "not yet - watch the console for 'RaceFinished' (if it never comes, the run was never finalized = the TBD screen + no money)"
        print(("[driving-empire] race report: players here=%d, game uploaded a recording: %s, server finalized your result: %s, cash before=%s"):format(
            here, uploaded, finalized, before and tostring(before) or "?"))
        notify(("Race report: %d players, recording uploaded: %s, result finalized: %s"):format(here, uploaded, gotResult and "yes" or "not yet"))
        if not before then
            notify("Couldn't read your cash - watch it manually after returning to the main server")
            return
        end
        local deadline = os.clock() + 300
        while os.clock() < deadline do
            task.wait(2.5)
            local now = getCash()
            if now and now > before then
                notify(("Race payout received: +%s"):format(formatCash(now - before)))
                print(("[driving-empire] race report: payout +%s"):format(tostring(now - before)))
                return
            end
        end
        notify("No race payout within 5 minutes - the server withheld it. If no 'RaceFinished' line for you appeared in the console, your result was never finalized (the TBD screen); stay on the server until the session fully ends")
    end)
end

-- Finishing too fast skips the payout - the server checks the total race
-- time against the track's payout minimum. Park at the last checkpoint
-- until the race clock clears it (+ the buffer).
local function waitForPayout(minTime, startClock)
    if not minTime or minTime <= 0 then return end
    local elapsed = raceElapsed()
    if not elapsed and startClock then
        elapsed = os.clock() - startClock  -- fallback: since the assist started
    end
    if not elapsed then return end
    local target = minTime + (Config.Race.PayoutBuffer or 1)
    if elapsed >= target then return end
    local waitFor = math.min(target - elapsed, 600)
    if waitFor > 0.5 then
        notify(("Race assist: holding %.1fs before the finish - finish gate %ss + %ss buffer"):format(waitFor, fmtSecs(minTime), fmtSecs(Config.Race.PayoutBuffer or 1)))
    end
    -- wait precisely: half-second chunks until close, then tenths, so the
    -- finish crossing lands right after the minimum
    local t0 = os.clock()
    while true do
        local remain = waitFor - (os.clock() - t0)
        if remain <= 0 then break end
        task.wait(remain > 1.5 and 0.5 or 0.1)
    end
end

-- Locked: 0.5s gives the server enough time to answer every crossing -
-- this is the value that clears rejections almost entirely.
local RACE_SERVER_WAIT = 0.5

-- One sweep: appear just before the gate, then just past it - the game's
-- crossing ray runs between those two frames and hits the part. Returns
-- "ok" / "rejected: <reason>" / "none" / "novh".
local function sweepAt(position, dir, dist)
    local rot = CFrame.lookAt(Vector3.new(0, 0, 0), dir).Rotation
    local before = CFrame.new(position - dir * dist) * rot
    local after = CFrame.new(position + dir * dist) * rot
    local snap = raceProbe.seq
    local tries = math.max(2, math.floor(RACE_SERVER_WAIT / 0.05))
    if not teleportCarTo(before) then return "novh", nil end
    task.wait(0.1)
    if not teleportCarTo(after) then return "novh", nil end
    for _ = 1, tries do
        task.wait(0.05)
        if raceProbe.seq > snap then
            local res = raceProbe.ok and "ok" or ("rejected: " .. tostring(raceProbe.reason))
            return res, raceProbe.kind
        end
    end
    return "none", nil
end

local function sweepCheckpoint(cp, dir, dist, lift)
    local base = cp.Position + Vector3.new(0, lift or 0, 0)
    return sweepAt(base, dir, dist)
end

local function crossCheckpoint(cp, dir)
    local last = "none"
    local sd = Config.Race.SweepDist or 12
    for _, v in ipairs({ { sd, 0 }, { sd + 4, 4 } }) do
        local res = sweepCheckpoint(cp, dir, v[1], v[2])
        if res == "ok" then return "ok" end
        if res ~= "none" then last = res end
    end
    return last
end

-- The finish gate can be a big arch, so try it from a few spots, heights
-- and sweep lengths until the server confirms the crossing.
local function tryFinish(finishPart, approachDir, full)
    local pos = finishPart.Position
    local size = finishPart.Size
    local bottom = pos - Vector3.new(0, size.Y / 2, 0) + Vector3.new(0, 2, 0)
    local look = finishPart.CFrame.LookVector * Vector3.new(1, 0, 1)
    if look.Magnitude < 0.1 then
        look = approachDir
    else
        look = look.Unit
    end
    local sd = Config.Race.SweepDist or 12
    local attempts = {
        { pos, approachDir, sd },
        { pos, approachDir, sd + 28 },
        { bottom, approachDir, sd },
    }
    if full then
        table.insert(attempts, { bottom, approachDir, sd + 28 })
        table.insert(attempts, { pos, look, sd })
        table.insert(attempts, { bottom, look, sd })
    end
    for _, a in ipairs(attempts) do
        local res, kind = sweepAt(a[1], a[2], a[3])
        if res == "ok" and kind == "finish" then
            return "ok"
        end
        if res == "novh" then return "novh" end
        task.wait(0.3)
    end
    return "none"
end

local function runRaceRoutine()
    if raceBusy then
        notify("Race assist is already running")
        return
    end
    if UILib and UILib.restoreIdentity then pcall(UILib.restoreIdentity) end
    local trackModel = findRaceTrackModel()
    if not trackModel then
        notify("Race assist: join a race first (with your car spawned)")
        return
    end
    local cps = {}
    for _, e in ipairs(trackModel.Checkpoints:GetChildren()) do
        local p = trackEntryPart(e)
        if p then table.insert(cps, p) end
    end
    table.sort(cps, function(a, b) return (tonumber(a.Name) or 0) < (tonumber(b.Name) or 0) end)
    local finish = trackEntryPart(trackModel.Finish)
    if #cps == 0 or not finish then
        notify("Race assist: couldn't read this race's checkpoints")
        return
    end
    local lapsKnown, minTime, trackName = raceTrackInfo(trackModel)
    local startClock = os.clock()
    raceBusy = true
    task.spawn(function()
        if UILib and UILib.restoreIdentity then pcall(UILib.restoreIdentity) end
        local chassis = getActiveChassis()
        if chassis then pcall(function() chassis.Teleporting = true end) end
        -- the race HUD's TotalLaps arrives live on every racing tick - it
        -- beats the config lookup and fixes the old "assumed 4 laps" bug
        -- (a wrong floor + a phantom finish hold halfway through the race)
        if raceClock.laps and raceClock.laps > 0 then lapsKnown = raceClock.laps end
        local laps = math.clamp(lapsKnown or 2, 1, 8)
        local carMin = carAwareMinTime(chassis, trackModel, laps)
        local minTxt = ""
        if carMin then
            local hold = math.max(minTime or 0, carMin)
            minTxt = (" - car limit ~%ss (crossing ~%ss)"):format(fmtSecs(carMin), fmtSecs(hold + (Config.Race.PayoutBuffer or 1)))
            minTime = hold
        elseif minTime then
            minTxt = (" - track minimum %ss (buffer +%ss)"):format(fmtSecs(minTime), fmtSecs(Config.Race.PayoutBuffer or 1))
        end
        if trackName and RaceUtil then
            -- show the game's own payout numbers: fixed cash per finishing
            -- place, plus a bonus for every extra racer (never car-based).
            -- Global matchmaking servers use their own payout table.
            local gmmOpts = nil
            if MatchmakingUtil and type(MatchmakingUtil.isMatchmakingPlace) == "function" then
                local okG, isG = pcall(MatchmakingUtil.isMatchmakingPlace)
                if okG and isG == true then gmmOpts = { IsGlobalMultiplayer = true } end
            end
            local payMode = gmmOpts and "GlobalMultiplayer" or "Exhibition"
            -- the game's own calculator: solo number + what it pays with a
            -- typical 5-car lobby (racer bonus included, player benefits too)
            local okPay, cash1, cash5 = pcall(function()
                if type(RaceUtil.calculatePayout) == "function" then
                    return RaceUtil.calculatePayout(payMode, trackName, 1, 1, LocalPlayer, nil, gmmOpts),
                        RaceUtil.calculatePayout(payMode, trackName, 1, 5, LocalPlayer, nil, gmmOpts)
                end
                local c = RaceUtil.calculateBaselinePayout and RaceUtil.calculateBaselinePayout(payMode, trackName, 1, gmmOpts) or nil
                return c, nil
            end)
            if okPay and type(cash1) == "number" and cash1 > 0 then
                minTxt = minTxt .. (", 1st ~%s"):format(formatCash(cash1))
                if type(cash5) == "number" and cash5 > cash1 then
                    minTxt = minTxt .. (" (5 racers: ~%s)"):format(formatCash(cash5))
                end
                if gmmOpts then
                    minTxt = minTxt .. " [matchmaking payout table]"
                end
            end
        end
        local contTxt = ""
        local curLap = tonumber(raceClock.lap)
        if curLap and curLap > 1 then
            contTxt = (" - continuing lap %d/%d"):format(math.min(curLap, laps), laps)
        end
        notify(("Race assist: taking %d checkpoints x%d lap(s)%s%s"):format(#cps, laps, minTxt, contTxt))
        local ok, err = pcall(function()
            local function dirBetween(fromPart, toPart)
                local d = (toPart.Position - fromPart.Position) * Vector3.new(1, 0, 1)
                if d.Magnitude < 1 then
                    d = toPart.CFrame.LookVector * Vector3.new(1, 0, 1)
                    if d.Magnitude < 0.1 then d = Vector3.new(1, 0, 0) end
                end
                return d.Unit
            end
            local dirs = {}
            for i = 1, #cps do
                dirs[i] = dirBetween(cps[i - 1] or cps[#cps], cps[i])
            end
            local finishDir = dirBetween(cps[#cps], finish)
            -- Cross a stretch of checkpoints [fromIdx..#cps] and return how
            -- many the server accepted / how many crossing rays missed. The
            -- rejected path redoes the SAME gate with spaced re-crossings
            -- (looping back through the previous gate broke runs more than
            -- it helped).
            local function crossFrom(fromIdx)
                local taken, skipped = 0, 0
                for i = fromIdx, #cps do
                    legitimizeVehicleStats(chassis)
                    local res = crossCheckpoint(cps[i], dirs[i])
                    if res == "ok" then
                        taken = taken + 1
                    elseif res == "none" then
                        skipped = skipped + 1
                    elseif res == "novh" then
                        error("couldn't move your car - make sure you're sitting in it", 0)
                    else
                        notify(("Race assist: checkpoint %d rejected (%s) - redoing it"):format(i, tostring(res)))
                        local cleared = false
                        for _ = 1, 4 do
                            task.wait(Config.Race.HopDelay or 0.5)
                            local res2 = crossCheckpoint(cps[i], dirs[i])
                            if res2 == "ok" then
                                cleared = true
                                break
                            end
                            if res2 == "novh" then
                                error("couldn't move your car - make sure you're sitting in it", 0)
                            end
                            if res2 == "none" and Remotes and type(Remotes.invokeServer) == "function" then
                                -- the crossing ray missed - report this gate
                                -- anyway through the remote
                                local okCall, answer = pcall(Remotes.invokeServer, "RaceCheckpoint", i)
                                if okCall and answer then
                                    cleared = true
                                    break
                                end
                            end
                        end
                        if not cleared then
                            error(("checkpoint %d kept getting rejected (%s) - press the button again (progress is kept)"):format(i, tostring(res)), 0)
                        end
                        taken = taken + 1
                        notify(("Race assist: checkpoint %d accepted after redoing it"):format(i))
                    end
                    task.wait(Config.Race.HopDelay or 0.5)  -- hop delay (Race tab slider)
                end
                return taken, skipped
            end

            -- Which gate is the RACE waiting for? The HUD info names the
            -- next expected checkpoint part - or the finish itself once
            -- every gate of the final lap is counted. Following it makes
            -- restarts mid-race continue exactly where the server is.
            local function expectedIndex()
                if not raceClock.nextCp then return nil end
                local okM, res = pcall(function()
                    local part = trackEntryPart(raceClock.nextCp)
                    if part == finish then return "finish" end
                    for i = 1, #cps do
                        if cps[i] == part then return i end
                    end
                    return nil
                end)
                if okM then return res end
                return nil
            end

            local startRaceLap = math.clamp(tonumber(raceClock.lap) or 1, 1, laps)
            if expectedIndex() ~= nil then
                -- LIVE MODE: follow the race's own expectations (fresh runs
                -- and mid-race restarts both just work; once the race says
                -- the finish is next, we drop into the finish rounds below)
                local pass = 0
                while true do
                    local idx = expectedIndex()
                    if idx == nil or idx == "finish" then break end
                    pass = pass + 1
                    if pass > laps + 2 then
                        error("the race didn't advance - press the button again", 0)
                    end
                    local taken, skipped = crossFrom(idx)
                    notify(("Race assist: lap %d/%d done (%d taken, %d skipped)"):format(
                        math.min(startRaceLap + pass - 1, laps), laps, taken, skipped))
                end
            else
                -- BLIND MODE: no live race info - cross everything, laps times
                for pass = 1, laps do
                    local taken, skipped = crossFrom(1)
                    if pass == 1 and taken == 0 then
                        -- nothing answered: race may not have started, or
                        -- every checkpoint is taken and only the finish left
                        local fres = tryFinish(finish, finishDir, false)
                        if fres == "ok" then
                            notify("Race assist: race finished!")
                            watchRacePayout()
                            return
                        end
                        error("no checkpoint answered - wait for the race to start (GO) and retry (if the checkpoints were already taken, press again for the finish)", 0)
                    end
                    notify(("Race assist: lap %d/%d done (%d taken, %d skipped)"):format(pass, laps, taken, skipped))
                    -- take the finish line too on the last lap, or every
                    -- lap when the lap count couldn't be read
                    if pass == laps or not lapsKnown then
                        waitForPayout(minTime, startClock)
                        local fres = tryFinish(finish, finishDir, false)
                        if fres == "ok" then
                            notify("Race assist: race finished!")
                            watchRacePayout()
                            return
                        end
                        if fres == "novh" then
                            error("couldn't move your car - make sure you're sitting in it", 0)
                        end
                    end
                end
            end
            -- final finish-line rounds (progress is kept, so a retry only has
            -- to land the finish crossing)
            for _ = 1, 2 do
                waitForPayout(minTime, startClock)
                local fres = tryFinish(finish, finishDir, true)
                if fres == "ok" then
                    notify("Race assist: race finished!")
                    watchRacePayout()
                    return
                end
                if fres == "novh" then
                    error("couldn't move your car - make sure you're sitting in it", 0)
                end
                task.wait(1)
            end
            error("the race didn't accept the finish - press the button again (it continues from your current progress)", 0)
        end)
        if chassis then pcall(function() chassis.Teleporting = false end) end
        raceBusy = false
        if not ok then
            notify("Race assist: " .. tostring(err))
        end
    end)
end

-- PAYOUT TABLE PRINTER: the live payout config (RacePayouts, ~22KB) is
-- fetched at runtime and cached client-side - read it there and print every
-- track's exact numbers: per-place cash + the per-racer bonus, for the
-- normal AND matchmaking tables, plus the current track's live minimum time.
local function printPayoutTable()
    if UILib and UILib.restoreIdentity then pcall(UILib.restoreIdentity) end
    task.spawn(function()
        local ok, err = pcall(function()
            local node = waitPath(ReplicatedStorage, { "Modules", "Shared", "Races", "RacePayoutsRemoteConfig" })
            if not node then error("RacePayoutsRemoteConfig not found") end
            local conf = require(node)
            local cache = conf.GetConfigAsync()
            local payouts = (cache and cache.Payouts) or {}
            local globals = (cache and cache.GlobalPayouts) or {}
            local function fmtRecord(r)
                if not r then return "none" end
                local parts = {}
                for i = 1, 8 do
                    local v = r[tostring(i)]
                    if v ~= nil then table.insert(parts, ("%d=$%s"):format(i, tostring(v))) end
                end
                local m = r.Multiplier
                if type(m) == "number" then
                    table.insert(parts, ("per-racer bonus=%s%%"):format(tostring(math.round(m * 1000) / 10)))
                else
                    table.insert(parts, "per-racer bonus=?")
                end
                return table.concat(parts, " ")
            end
            print("===== [driving-empire] LIVE RACE PAYOUTS (normal || matchmaking) =====")
            local names = {}
            for nm in pairs(payouts) do table.insert(names, nm) end
            if #names == 0 then
                for nm in pairs(globals) do table.insert(names, nm) end
            end
            table.sort(names)
            for _, nm in ipairs(names) do
                print(("[%s] normal: %s  ||  matchmaking: %s"):format(nm, fmtRecord(payouts[nm]), fmtRecord(globals[nm])))
            end
            local trackModel = findRaceTrackModel()
            local trackName = trackModel and select(3, raceTrackInfo(trackModel)) or nil
            if trackName and RaceUtil then
                local okInfo, info = pcall(RaceUtil.getTrackInfo, trackName)
                if okInfo and info then
                    print(("[current] %s MinTime=%ss TimeLimit=%ss MaxLaps=%s"):format(
                        trackName, tostring(info.MinTimeSeconds), tostring(info.TimeLimitSeconds), tostring(info.MaxLaps)))
                end
            end
            local trNode = waitPath(ReplicatedStorage, { "Modules", "Shared", "Races", "RaceRemoteConfig" })
            if trNode then
                local okT, tracks = pcall(function() return require(trNode).getTracks() end)
                if okT and type(tracks) == "table" then
                    local tnames = {}
                    for nm in pairs(tracks) do table.insert(tnames, nm) end
                    table.sort(tnames)
                    print("----- live track times (MinTime / TimeLimit / MaxLaps) -----")
                    for _, nm in ipairs(tnames) do
                        local t = tracks[nm]
                        print(("[track] %s MinTime=%ss TimeLimit=%ss MaxLaps=%s"):format(
                            nm, tostring(t.MinTime), tostring(t.TimeLimit), tostring(t.MaxLaps)))
                    end
                end
            end
            print("===== end payout table =====")
        end)
        if ok then
            notify("Payout table printed to the console")
        else
            notify("Payout print failed: " .. tostring(err))
        end
    end)
end

-- ============================================================
-- RACE AUTO-FARM (Money tab)
-- ============================================================
-- "Auto-run" starts the normal race assist (same routine as the button,
-- same Race tab timing settings) whenever a race goes live. "Auto-queue"
-- re-joins the same track after each race using the game's own queue call:
-- Remotes.invokeServer("JoinRacingQueue", track) -> (ok, ticketOrMessage).
local function farmRaceMode()
    if MatchmakingUtil and type(MatchmakingUtil.isMatchmakingPlace) == "function" then
        local okG, isG = pcall(MatchmakingUtil.isMatchmakingPlace)
        if okG and isG == true then return "GlobalMultiplayer" end
    end
    return "Exhibition"
end

-- Queue join = the JoinRacingQueue RemoteFunction (from the game's own
-- MatchmakingController): invokeServer(queueId) returns (ok, ticket ||
-- refusal message). Runs in a task so a slow answer never stalls the farm
-- loop; the reply is logged and toasted.
local function queueJoinNow()
    local track = farmRace.lastTrack or "Circuit"
    task.spawn(function()
        local pok, v1, v2
        if Remotes and type(Remotes.invokeServer) == "function" then
            pok, v1, v2 = pcall(Remotes.invokeServer, "JoinRacingQueue", track)
        else
            local node = waitPath(ReplicatedStorage, { "Remotes", "JoinRacingQueue" })
            if node then
                pok, v1, v2 = pcall(function() return node:InvokeServer(track) end)
            end
        end
        print(("[driving-empire] auto-queue: JoinRacingQueue(%s) pcall=%s ok=%s result=%s"):format(
            tostring(track), tostring(pok), tostring(v1), tostring(v2)))
        if pok == nil then
            notify("Queue join failed - JoinRacingQueue not found")
        elseif not pok then
            notify("Queue join error - see console")
        elseif v1 == true then
            pcall(function() if isfile("driving_empire_requeue.txt") then delfile("driving_empire_requeue.txt") end end)
            notify(("Queued for %s - waiting for the race"):format(tostring(track)))
        else
            notify(("Queue refused: %s"):format(tostring(v2 or v1)))
        end
    end)
end

task.spawn(function()
    while true do
        task.wait(1)
        if not vehicleHooks.farmJoinedConn then
            local ev = waitPath(ReplicatedStorage, { "Remotes", "RaceJoined" })
            if ev and ev.OnClientEvent then
                vehicleHooks.farmJoinedConn = ev.OnClientEvent:Connect(function(...)
                    local a = table.pack(...)
                    farmRace.pendingAt, farmRace.rejoinTries = nil, 0
                    print(("[driving-empire] RaceJoined: %s %s"):format(tostring(a[1]), tostring(a[2])))
                    if Config.Race.AutoFarm or Config.Race.AutoRequeue then
                        notify("Race auto-farm: joined a race - assist starts at GO")
                    end
                end)
            end
        end
        if farmRace.epoch ~= raceClock.epoch then
            farmRace.epoch = raceClock.epoch
            farmRace.attempts, farmRace.finished, farmRace.raceSeenAt = 0, false, nil
        end
        local live = raceClock.at and (os.clock() - raceClock.at) < 1.5
        local racing = (live and (tonumber(raceClock.time) or 0) > 1.5) and true or false
        if racing then
            farmRace.pendingAt = nil
            farmRace.rejoinTries = 0
            if not farmRace.raceSeenAt then farmRace.raceSeenAt = os.clock() end
            if raceResult.mine and raceResult.at and raceResult.at >= farmRace.raceSeenAt then
                farmRace.finished = true
            end
            if Config.Race.AutoFarm and not farmRace.finished and not raceBusy and farmRace.attempts < 5 then
                local trackModel = findRaceTrackModel()
                if trackModel then
                    local nm = select(3, raceTrackInfo(trackModel))
                    if nm then farmRace.lastTrack = nm end
                    farmRace.lastMode = farmRaceMode()
                    if (os.clock() - farmRace.lastAttempt) > 12 then
                        farmRace.attempts = farmRace.attempts + 1
                        farmRace.lastAttempt = os.clock()
                        notify(farmRace.attempts == 1 and "Race auto-farm: race live - running the assist"
                            or ("Race auto-farm: retry %d/5"):format(farmRace.attempts))
                        pcall(runRaceRoutine)
                    end
                end
            end
        else
            if Config.Race.AutoRequeue and farmRace.wasRacing then
                farmRace.pendingAt = os.clock() + 20  -- let results + teleports settle
                -- remember the requeue ACROSS the teleport back: the next
                -- place re-execs this script (teleport persistence) and
                -- picks the flag up to keep the farm looping
                pcall(function()
                    writefile("driving_empire_requeue.txt", ("%s|%d"):format(tostring(farmRace.lastTrack or "Circuit"), os.time()))
                end)
            end
            if Config.Race.AutoRequeue and farmRace.pendingAt and not raceBusy
                and os.clock() >= farmRace.pendingAt then
                if farmRace.rejoinTries >= 3 then
                    farmRace.pendingAt = nil
                elseif (os.clock() - farmRace.lastJoinAt) > 55 then
                    farmRace.rejoinTries = farmRace.rejoinTries + 1
                    farmRace.lastJoinAt = os.clock()
                    farmRace.pendingAt = os.clock() + 45  -- retry window
                    queueJoinNow()
                end
            end
        end
        farmRace.wasRacing = racing
    end
end)

-- ============================================================
-- TELEPORT PERSISTENCE (auto re-exec after getting teleported)
-- ============================================================
-- The race queue teleports you into the game's matchmaking place - a fresh
-- client where this script doesn't exist. queueonteleport (Potassium;
-- alias queue_on_teleport) runs a code string after the next teleport, so
-- we queue the hub LOADER: it maps every Driving Empire place back to this
-- same script, which re-queues itself for the hop after that - the farm
-- survives place hops on its own.
local HUB_LOADER_URL = "https://raw.githubusercontent.com/Randeyeuhm/havoc-project-delta/main/loader.luau"
local teleportPersist = { fn = nil, queuedAt = 0, warned = false }

local function resolveTeleportQueue()
    if teleportPersist.fn then return teleportPersist.fn end
    local g = type(getgenv) == "function" and getgenv() or nil
    if g then
        for _, name in ipairs({ "queueonteleport", "queue_on_teleport" }) do
            if type(g[name]) == "function" then
                teleportPersist.fn = g[name]
                break
            end
        end
        if not teleportPersist.fn then
            for _, nsName in ipairs({ "syn", "fluxus", "krnl", "delta" }) do
                local ns = g[nsName]
                if type(ns) == "table" and type(ns.queue_on_teleport) == "function" then
                    teleportPersist.fn = function(code) return ns.queue_on_teleport(code) end
                    break
                end
            end
        end
    end
    if not teleportPersist.fn then
        local ok, fn = pcall(function() return queueonteleport end)
        if ok and type(fn) == "function" then teleportPersist.fn = fn end
    end
    if not teleportPersist.fn then
        local ok, fn = pcall(function() return queue_on_teleport end)
        if ok and type(fn) == "function" then teleportPersist.fn = fn end
    end
    return teleportPersist.fn
end

local function clearTeleportQueue()
    local g = type(getgenv) == "function" and getgenv() or nil
    if g and type(g.clearteleportqueue) == "function" then
        if pcall(g.clearteleportqueue) then return true end
    end
    local ok, fn = pcall(function() return clearteleportqueue end)
    if ok and type(fn) == "function" then
        return (pcall(fn))
    end
    return false
end

local function refreshTeleportQueue(force)
    if Config.Misc.TeleportExec ~= true then return end
    local fn = resolveTeleportQueue()
    if not fn then
        if not teleportPersist.warned then
            teleportPersist.warned = true
            print("[driving-empire] teleport persistence: no queueonteleport function found in this executor")
        end
        return
    end
    if not force and (os.clock() - teleportPersist.queuedAt) < 45 then return end
    -- wipe the executor's queue first, then arm exactly ONE payload; the
    -- payload carries its own one-per-client guard - so no matter how often
    -- this re-arms, the next teleport runs the hub exactly once
    local code = ([[if not (getgenv and getgenv().HAVOC_HUB_TELEPORT_EXEC) then getgenv().HAVOC_HUB_TELEPORT_EXEC = true; loadstring(game:HttpGet(%q .. "?t=" .. tostring(os.time())))() end]]):format(HUB_LOADER_URL)
    local cleared = clearTeleportQueue()
    local ok = pcall(fn, code)
    teleportPersist.queuedAt = os.clock()
    if force then
        print(("[driving-empire] teleport persistence: re-exec queued (ok=%s, old copies cleared=%s)"):format(tostring(ok), tostring(cleared)))
    end
end

-- A race ended before we got teleported out? The requeue flag carries that
-- across the place hop - pick it up and continue the farm loop here.
pcall(function()
    if isfile("driving_empire_requeue.txt") then
        local data = readfile("driving_empire_requeue.txt")
        local track, at = tostring(data):match("^(.-)|(%d+)$")
        if track and at and (os.time() - tonumber(at)) < 900 and Config.Race.AutoRequeue then
            farmRace.lastTrack = track
            farmRace.pendingAt = os.clock() + 8
            notify(("Race auto-farm: continuing the loop - re-queuing %s"):format(track))
        end
        delfile("driving_empire_requeue.txt")
    end
end)

refreshTeleportQueue(true)

-- ============================================================
-- INPUT
-- ============================================================
track(UserInputService.InputBegan:Connect(function(input, processed)
    if UILib and UILib.handleRebindInput(input) then return end
    if processed then return end
    if UserInputService:GetFocusedTextBox() then return end

    local entry = keyMap[input.KeyCode]
    if entry and entry.Action then
        local ok, err = pcall(entry.Action)
        if not ok then warn(("[driving-empire] Hotkey '%s' errored: %s"):format(entry.Desc, tostring(err))) end
    end
end))

-- ============================================================
-- MENU
-- ============================================================
local function buildMenu()
    -- The Project Delta window shell lives in UILib.makeWindow now: dot
    -- header + drawn-X close, search bar (fed by our control list), left
    -- category rail, footer with the reopen hint + live status.
    if UILib.restoreIdentity then pcall(UILib.restoreIdentity) end
    local win = UILib.makeWindow{
        parent = screenGui,
        name = "Main",
        title = "HAVOC HUB  ·  DRIVING EMPIRE",
        subtitle = ("PlaceId %d  ·  %s"):format(game.PlaceId, SCRIPT_VERSION),
        tabs = { "Vehicle", "Teleports", "HUD", "Visuals", "Money", "Misc", "Race" },
        controls = guiControls,
        footerHint = "RightShift — show / hide this menu",
        onClose = function()
            screenGui.Enabled = false
            notify("Menu hidden - press RightShift to reopen")
        end,
    }
    local pages = { win.tab(1), win.tab(2), win.tab(3), win.tab(4), win.tab(5), win.tab(6), win.tab(7) }

    local builtCount = 0
    local function guard(what, fn)
        local ok, e = pcall(fn)
        if ok and type(e) == "table" then
            builtCount = builtCount + 1
            addControl(e)
            -- Remember where each row lives so search can put it back.
            if e.row then e.homeParent = e.row.Parent end
            return e
        end
        warn(("[driving-empire] widget '%s' failed: %s"):format(what, tostring(e)))
        return nil
    end
    local function section(page, text)
        guard("section " .. text, function() return UILib.makeSectionHeader(page, text) end)
    end
    local function toggle(page, text, getter, setter, hkEntry)
        guard("toggle " .. text, function() return UILib.makeToggle(page, text, getter, setter, hkEntry) end)
    end
    local function slider(page, text, getter, setter, step, min, max)
        guard("slider " .. text, function() return UILib.makeSlider(page, text, getter, setter, step, min, max) end)
    end
    local function bindrow(page, entry, opts)
        guard("keybind row " .. tostring(entry and entry.Desc or "?"), function()
            return UILib.makeKeybindRow(page, entry, opts)
        end)
    end
    local function button(page, text, onClick, opts)
        guard("button " .. text, function() return UILib.makeButton(page, text, onClick, opts) end)
    end
    local function note(page, text) pcall(function() UILib.makeNote(page, text, "auto") end) end

    -- ---------------- Vehicle ----------------
    local p1 = pages[1]
    section(p1, "Performance  (client-side physics)")
    slider(p1, "Speed multiplier",
        function() return Config.Vehicle.SpeedMult end,
        function(v)
            Config.Vehicle.SpeedMult = v
            initVehicleModules()
            setSpeedFactor(v)
        end, 0.05, 1, 50)
    slider(p1, "Acceleration multiplier",
        function() return Config.Vehicle.TorqueMult end,
        function(v)
            Config.Vehicle.TorqueMult = v
            initVehicleModules()
            setTorqueFactor(v)
        end, 0.05, 1, 50)
    slider(p1, "Grip multiplier",
        function() return Config.Vehicle.GripMult end,
        function(v) Config.Vehicle.GripMult = v end, 1, 1, 500)
    slider(p1, "Brake multiplier",
        function() return Config.Vehicle.BrakeMult end,
        function(v) Config.Vehicle.BrakeMult = v end, 0.05, 1, 50)
    slider(p1, "Steer strength",
        function() return Config.Vehicle.SteerMult end,
        function(v) Config.Vehicle.SteerMult = v end, 0.05, 1, 50)
    toggle(p1, "Instant shifting",
        function() return Config.Vehicle.InstantShift end,
        function(v) Config.Vehicle.InstantShift = v end)
    toggle(p1, "Remove tires (glitch)",
        function() return Config.Vehicle.NoTires end,
        function(v) Config.Vehicle.NoTires = v end)
    section(p1, "Nitro & caps")
    toggle(p1, "Infinite nitro",
        function() return Config.Vehicle.InfNitro end,
        function(v) Config.Vehicle.InfNitro = v end)
    toggle(p1, "Ignore speed caps",
        function() return Config.Vehicle.NoSpeedCap end,
        function(v) Config.Vehicle.NoSpeedCap = v end)
    note(p1, "Scales the driven car's engine/grip/brakes - resets on car switch. Keep 1.0 for races you care about.")

    -- ---------------- Teleports ----------------
    local p2 = pages[2]
    section(p2, "Locations")
    for _, tp in ipairs(TELEPORTS) do
        button(p2, tp.label, function() teleportTo(tp.part, tp.label) end)
    end
    note(p2, "Moves your car (or character on foot). 'Not found' = drive closer once so the map streams in.")

    -- ---------------- HUD ----------------
    local p3 = pages[3]
    section(p3, "Speedometer")
    toggle(p3, "Speedometer HUD",
        function() return Config.HUD.Enabled end,
        function(v) Config.HUD.Enabled = v end)
    slider(p3, "Speed text size",
        function() return Config.HUD.SpeedSize end,
        function(v) Config.HUD.SpeedSize = v end, 1, 10, 40)
    slider(p3, "Info text size",
        function() return Config.HUD.InfoSize end,
        function(v) Config.HUD.InfoSize = v end, 1, 8, 30)
    slider(p3, "Screen margin X",
        function() return Config.HUD.XOffset end,
        function(v) Config.HUD.XOffset = v end, 2, 0, 400)
    slider(p3, "Screen margin Y",
        function() return Config.HUD.YOffset end,
        function(v) Config.HUD.YOffset = v end, 2, 0, 600)
    note(p3, "Live speed/gear/RPM - the same numbers the game's own gauges use.")

    -- ---------------- Visuals ----------------
    local p4 = pages[4]
    section(p4, "Player ESP")
    toggle(p4, "Player ESP",
        function() return Config.ESP.Enabled end,
        function(v) Config.ESP.Enabled = v end,
        hotkeyById.ToggleESP)
    button(p4, "Open ESP Customizer", function()
        if ESPUI then
            ESPUI.open{
                cfg = Config.ESP,
                uilib = UILib,
                screenGui = screenGui,
                save = saveConfig,
                notify = notify,
            }
        else
            notify("espui.luau not loaded - customizer unavailable")
        end
    end)
    bindrow(p4, hotkeyById.ToggleESP)
    section(p4, "World")
    toggle(p4, "Fullbright",
        function() return Config.Misc.Fullbright end,
        function(v) Config.Misc.Fullbright = v; setFullbright(v) end)

    -- ---------------- Money ----------------
    local p5 = pages[5]
    section(p5, "Cash")
    toggle(p5, "Show cash on HUD",
        function() return Config.Money.ShowHud end,
        function(v) Config.Money.ShowHud = v end)
    note(p5, "Reads leaderstats.Cash and updates live.")
    section(p5, "Auto farm  (driving income)")
    toggle(p5, "Auto farm (auto drive)",
        function() return Config.Farm.Enabled end,
        function(v)
            Config.Farm.Enabled = v
            if v then
                initFarmHook()
                farmState.cashStart = getCash() or 0
                farmState.recoverUntil = 0
                notify(getLocalVehicleModel() and "Auto farm on - driving" or "Auto farm on - get in a car")
            else
                local delta = (getCash() or 0) - farmState.cashStart
                notify(delta > 0 and ("Auto farm off - earned %s"):format(formatCash(delta)) or "Auto farm off")
            end
        end)
    slider(p5, "Farm steer bias",
        function() return Config.Farm.Steer end,
        function(v) Config.Farm.Steer = v end, 0.05, -1, 1)
    note(p5, "Holds full throttle - faster car, more income. Steer 0 = straight, ~0.3 = circles. Auto-reverses when stuck.")

    section(p5, "Race auto-farm  (money loop)")
    toggle(p5, "Auto-run the race assist",
        function() return Config.Race.AutoFarm end,
        function(v)
            Config.Race.AutoFarm = v
            notify(v and "Race auto-farm on - races run themselves (Race tab settings apply)"
                or "Race auto-farm off")
        end)
    toggle(p5, "Auto-queue the next race",
        function() return Config.Race.AutoRequeue end,
        function(v)
            Config.Race.AutoRequeue = v
            notify(v and "Auto-queue on - re-queues the last track + mode after each race"
                or "Auto-queue off")
        end)
    button(p5, "Queue now (last track)", function()
        queueJoinNow()
    end)
    note(p5, "Auto-run finishes any race you enter (Race tab settings apply). Auto-queue re-joins the same track after each race. Toggle off to stop.")

    -- ---------------- Misc ----------------
    local p6 = pages[6]
    section(p6, "Utility")
    toggle(p6, "Anti-AFK",
        function() return Config.Misc.AntiAFK end,
        function(v) Config.Misc.AntiAFK = v end)
    button(p6, "Reset Character", function()
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if hum then
            pcall(function() hum.Health = 0 end)
            notify("Character reset")
        else
            notify("No character to reset")
        end
    end, { confirm = true, confirmText = "Click again to reset" })
    button(p6, "Rejoin Server", function()
        notify("Rejoining...")
        pcall(function() TeleportService:Teleport(game.PlaceId, LocalPlayer) end)
    end, { confirm = true, confirmText = "Click again to rejoin" })
    section(p6, "Teleport persistence")
    toggle(p6, "Auto re-exec after teleport",
        function() return Config.Misc.TeleportExec end,
        function(v)
            Config.Misc.TeleportExec = v
            if v then
                refreshTeleportQueue(true)
                notify("Teleport persistence on - the hub re-runs after every teleport")
            else
                local cleared = clearTeleportQueue()
                notify(cleared and "Teleport persistence off - queued re-exec cleared"
                    or "Teleport persistence off (no clear function in this executor - the next hop still re-runs once)")
            end
        end)
    button(p6, "Queue re-exec now", function()
        refreshTeleportQueue(true)
        notify(teleportPersist.fn and "Re-exec queued - runs after your next teleport" or "This executor has no queueonteleport function")
    end)
    note(p6, "The hub re-runs itself after every teleport - keeps the farm looping. Turn off to stop the chain.")
    section(p6, "Menu")
    bindrow(p6, hotkeyById.ToggleMenu, {
        locked = true,
        lockNote = "RightShift is the menu key and stays bound",
    })
    note(p6, ("Havoc Hub - Driving Empire (%s). Config: %s"):format(SCRIPT_VERSION, CONFIG_FILE))

    -- ---------------- Race ----------------
    local p7 = pages[7]
    section(p7, "Race assist")
    button(p7, "Finish race (take all checkpoints)", function() runRaceRoutine() end)
    section(p7, "Payout info")
    button(p7, "Print payout table (console)", function() printPayoutTable() end)
    note(p7, "Prints every track's live payout table (normal + matchmaking) to the console.")
    note(p7, "No payout? Stay on the server until the race fully ends - the cash watcher reports for 5 minutes.")
    section(p7, "Timing")
    slider(p7, "Hop delay (s)",
        function() return Config.Race.HopDelay end,
        function(v) Config.Race.HopDelay = v end, 0.05, 0.5, 1.5)
    slider(p7, "Sweep distance",
        function() return Config.Race.SweepDist end,
        function(v) Config.Race.SweepDist = v end, 1, 6, 60)
    slider(p7, "Payout buffer (s)",
        function() return Config.Race.PayoutBuffer end,
        function(v) Config.Race.PayoutBuffer = v end, 1, 0, 60)
    slider(p7, "Car time pad",
        function() return Config.Race.CarLimitPad end,
        function(v) Config.Race.CarLimitPad = v end, 0.05, 1, 3)
    note(p7, "Hop: pause between gates. Sweep: car placement around each gate. Buffer: extra seconds on top of the finish floor.")
    note(p7, "Server checks your finish time vs what your car can do - Car time pad is the safety margin (raise if a run doesn't pay). No 'RaceFinished' line for you = rejected run.")
    note(p7, "Teleports gate to gate, then the finish; rejected gates are redone, and re-pressing resumes mid-race. Wait for GO. Races are monitored.")
    note(p7, "Tip: 'Remove tires' on the Vehicle tab stops wheel flail during jumps.")

    win.setTab(1)
    print(("[driving-empire] menu built (%d controls)"):format(builtCount))
end

if UILib and screenGui then
    local ok, err = pcall(buildMenu)
    if not ok then
        warn("[driving-empire] menu build failed: " .. tostring(err))
    end
end

-- ============================================================
-- RENDER LOOP
-- ============================================================
track(RunService.RenderStepped:Connect(function()
    local cam = workspace.CurrentCamera
    if not cam then return end

    pcall(function()
        local chassis = getActiveChassis()
        if chassis then
            if Config.Vehicle.InfNitro and chassis.Tune then
                local cap = chassis.Tune.NitrousSupplyTime or 10
                if (chassis.CurrentBoostSupply or 0) < cap then
                    chassis.CurrentBoostSupply = cap
                end
            end
            if Config.Vehicle.NoSpeedCap and chassis.ExternalMaxSpeedMPH ~= nil then
                chassis.ExternalMaxSpeedMPH = nil
            end
        end
        updateHud(chassis)
        farmTick(chassis)
        applyGrip(chassis)
        applyBrake(chassis)
        applySteer(chassis)
        applyLockBypass(chassis)
        applyTires()
    end)

    pcall(renderESP, cam)
end))

print(("[driving-empire] %s loaded - speed x%.2f, torque x%.2f"):format(
    SCRIPT_VERSION, Config.Vehicle.SpeedMult, Config.Vehicle.TorqueMult))
