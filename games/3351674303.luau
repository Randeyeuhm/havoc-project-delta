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
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer      = Players.LocalPlayer

local SCRIPT_VERSION = "de-v5"

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
    Vehicle  = { SpeedMult = 1, TorqueMult = 1, GripMult = 1, InfNitro = false, NoSpeedCap = false },
    HUD      = { Enabled = true, SpeedSize = 18, InfoSize = 13, XOffset = 14, YOffset = 40 },
    Money    = { ShowHud = true, AutoDrops = false },
    Farm     = { Enabled = false, Steer = 0, Plate = false },
    -- ESP gets filled out by ESPUI.fill (the full espui schema); these four
    -- exist before the module loads so the file merge has typed targets.
    ESP      = { Enabled = false, TeamCheck = false, VisibleOnly = false, MaxDistance = 2000 },
    Misc     = { Fullbright = false, AntiAFK = true },
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
Config.Vehicle.SpeedMult = math.clamp(tonumber(Config.Vehicle.SpeedMult) or 1, 1, 3)
Config.Vehicle.TorqueMult = math.clamp(tonumber(Config.Vehicle.TorqueMult) or 1, 1, 3)
Config.Vehicle.GripMult = math.clamp(tonumber(Config.Vehicle.GripMult) or 1, 1, 3)
Config.HUD.SpeedSize = math.clamp(tonumber(Config.HUD.SpeedSize) or 18, 10, 40)
Config.HUD.InfoSize = math.clamp(tonumber(Config.HUD.InfoSize) or 13, 8, 30)
Config.HUD.XOffset = math.clamp(tonumber(Config.HUD.XOffset) or 14, 0, 400)
Config.HUD.YOffset = math.clamp(tonumber(Config.HUD.YOffset) or 40, 0, 600)
Config.ESP.MaxDistance = math.clamp(tonumber(Config.ESP.MaxDistance) or 2000, 100, 10000)
Config.Farm.Steer = math.clamp(tonumber(Config.Farm.Steer) or 0, -1, 1)

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
    if ChassisUtils then
        if not vehicleHooks.origSpeed then
            vehicleHooks.origSpeed = ChassisUtils.GetSpeedMult
            vehicleHooks.origTorque = ChassisUtils.GetTorqueMult
            vehicleHooks.speedFactor = 1
            vehicleHooks.torqueFactor = 1
        end
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
        local ok = pcall(function() vehModel:PivotTo(target) end)
        if ok then
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
-- FEATURES: MONEY  (cash display + NASCAR World cash drops)
-- ============================================================
-- Cash is read straight off leaderstats. Cash drops are CollectionService
-- models tagged "CashDrop" whose name is the drop index; the game's own
-- client fires CollectCashDrop when you touch one, so we fire the same
-- remote for drops we haven't tried this session. The server still decides
-- whether to award them (it may want you nearby - then drive close).
local RemotesModule
local function getRemotes()
    if RemotesModule then return RemotesModule end
    local node = waitPath(ReplicatedStorage, { "Modules", "Shared", "Remotes" })
    if node then
        local ok, res = pcall(require, node)
        if ok and type(res) == "table" then RemotesModule = res end
    end
    return RemotesModule
end

local firedDrops = {}

local function collectCashDrops(force)
    if not force and not Config.Money.AutoDrops then return 0 end
    local remotes = getRemotes()
    if not remotes then return 0 end
    local fired = 0
    for _, model in ipairs(CollectionService:GetTagged("CashDrop")) do
        local num = tonumber(model.Name)
        if num and not firedDrops[num] then
            firedDrops[num] = true
            fired = fired + 1
            pcall(function() remotes.fireServer("CollectCashDrop", num) end)
        end
    end
    return fired
end

track(CollectionService:GetInstanceAddedSignal("CashDrop"):Connect(function()
    if Config.Money.AutoDrops then
        task.defer(function() collectCashDrops(false) end)
    end
end))

task.spawn(function()
    while true do
        task.wait(3)
        pcall(collectCashDrops, false)
    end
end)

-- ============================================================
-- FEATURES: SKY PLATE  (flat 10k-stud-high runway for the farm)
-- ============================================================
-- A local-only plate high above the map: no traffic, no kerbs, no walls -
-- the farm drives straight lines on it and U-turns when it reaches the
-- edge (turn direction alternates so the car ping-pongs around the middle
-- instead of drifting off). The plate only exists on this client; the car
-- physics run client-side, so the car drives on it like any other road.
local SKY_PLATE = { Y = 10000, GRID = 2, SEG = 2048, THICKNESS = 8, MARGIN = 600, TURN_THROTTLE = 0.55 }
local skyPlate = nil
local skyState = { turning = false, entryLook = nil, turnDir = 1, turns = 0, lastTp = 0 }

local function ensureSkyPlate()
    if skyPlate and skyPlate.Parent then return skyPlate end
    if UILib and UILib.restoreIdentity then UILib.restoreIdentity() end
    local ok, model = pcall(function()
        local m = Instance.new("Model")
        m.Name = "HavocSkyPlate"
        for ix = 0, SKY_PLATE.GRID - 1 do
            for iz = 0, SKY_PLATE.GRID - 1 do
                local p = Instance.new("Part")
                p.Name = "SkyTile"
                p.Size = Vector3.new(SKY_PLATE.SEG, SKY_PLATE.THICKNESS, SKY_PLATE.SEG)
                p.CFrame = CFrame.new(
                    (ix - (SKY_PLATE.GRID - 1) / 2) * SKY_PLATE.SEG,
                    SKY_PLATE.Y - SKY_PLATE.THICKNESS / 2,
                    (iz - (SKY_PLATE.GRID - 1) / 2) * SKY_PLATE.SEG)
                p.Anchored = true
                p.CanCollide = true
                p.Material = Enum.Material.SmoothPlastic
                p.Color = Color3.fromRGB(34, 38, 46)
                p.Transparency = 0.35
                p.Parent = m
            end
        end
        m.Parent = workspace
        return m
    end)
    if ok and model then
        skyPlate = model
        return model
    end
    return nil
end

local function teleportToPlate()
    local model = getLocalVehicleModel()
    if not model then
        local char = LocalPlayer.Character
        if char and char.PrimaryPart then model = char end
    end
    if not model then
        notify("Get in a car first")
        return false
    end
    local cf = model:GetPivot()
    model:PivotTo(CFrame.new(Vector3.new(0, SKY_PLATE.Y + 10, 0)) * (cf - cf.Position))
    skyState.lastTp = os.clock()
    return true
end

-- Runs from farmTick while the plate farm is on: watches for the edge and
-- flips between "drive straight" and "u-turn" phases.
local function farmPlateTick()
    local model = getLocalVehicleModel()
    if not model then
        skyState.turning = false
        return
    end
    local ok, pivot = pcall(function() return model:GetPivot() end)
    if not ok or not pivot then return end
    local pos = pivot.Position

    -- Fell off / died / got flung? Put the car back on the plate (rate-limited).
    if pos.Y < SKY_PLATE.Y - 600 then
        if os.clock() - skyState.lastTp > 5 then
            pcall(function() teleportToPlate() end)
        end
        return
    end

    local half = (SKY_PLATE.GRID * SKY_PLATE.SEG) / 2 - SKY_PLATE.MARGIN
    local look = pivot.LookVector
    if not skyState.turning then
        if math.abs(pos.X) > half or math.abs(pos.Z) > half then
            skyState.turning = true
            skyState.entryLook = look
            skyState.turns = skyState.turns + 1
            skyState.turnDir = (skyState.turns % 2 == 0) and 1 or -1
        end
    else
        local entry = skyState.entryLook
        if entry and entry:Dot(look) < -0.75 then
            skyState.turning = false
            skyState.entryLook = nil
        end
    end
end

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
    if Config.Farm.Plate and skyState.turning then
        return SKY_PLATE.TURN_THROTTLE, skyState.turnDir
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
        skyState.turning = false
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
    if Config.Farm.Plate then
        pcall(farmPlateTick)
    else
        skyState.turning = false
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
    local win = UILib.makeWindow{
        parent = screenGui,
        name = "Main",
        title = "HAVOC HUB  ·  DRIVING EMPIRE",
        subtitle = "PlaceId " .. tostring(game.PlaceId),
        size = UDim2.new(0, 560, 0, 380),
        position = UDim2.new(0, 30, 0, 40),
        tabs = { "Vehicle", "Teleports", "HUD", "Visuals", "Money", "Misc" },
        onClose = function()
            screenGui.Enabled = false
            notify("Menu hidden - press RightShift to reopen")
        end,
    }
    local pages = { win.tab(1), win.tab(2), win.tab(3), win.tab(4), win.tab(5), win.tab(6) }

    local builtCount = 0
    local function guard(what, fn)
        local ok, e = pcall(fn)
        if ok and type(e) == "table" then
            builtCount = builtCount + 1
            addControl(e)
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
        end, 0.05, 1, 3)
    slider(p1, "Acceleration multiplier",
        function() return Config.Vehicle.TorqueMult end,
        function(v)
            Config.Vehicle.TorqueMult = v
            initVehicleModules()
            setTorqueFactor(v)
        end, 0.05, 1, 3)
    slider(p1, "Grip multiplier",
        function() return Config.Vehicle.GripMult end,
        function(v) Config.Vehicle.GripMult = v end, 0.05, 1, 3)
    section(p1, "Nitro & caps")
    toggle(p1, "Infinite nitro",
        function() return Config.Vehicle.InfNitro end,
        function(v) Config.Vehicle.InfNitro = v end)
    toggle(p1, "Ignore speed caps",
        function() return Config.Vehicle.NoSpeedCap end,
        function(v) Config.Vehicle.NoSpeedCap = v end)
    note(p1, "Multipliers scale the driven car's engine, torque and tyre grip - " ..
        "they reset when you switch cars. Speed changes may stand out in races; " ..
        "keep 1.0 for events you care about.")

    -- ---------------- Teleports ----------------
    local p2 = pages[2]
    section(p2, "Locations")
    for _, tp in ipairs(TELEPORTS) do
        button(p2, tp.label, function() teleportTo(tp.part, tp.label) end)
    end
    note(p2, "Teleports move your car when you are driving, otherwise your " ..
        "character. If a location says 'not found', drive closer once - the " ..
        "map streams in around you.")

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
    note(p3, "Live speed, gear and RPM straight from the car's chassis " ..
        "controller - the same numbers the game's own gauges use.")

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
    section(p5, "Cash drops (NASCAR World)")
    toggle(p5, "Auto collect cash drops",
        function() return Config.Money.AutoDrops end,
        function(v)
            Config.Money.AutoDrops = v
            if v then collectCashDrops(true) end
        end)
    button(p5, "Collect now", function()
        local n = collectCashDrops(true)
        notify(n > 0 and ("Requested %d cash drop(s)"):format(n) or "No new cash drops found")
    end)
    note(p5, "Drops only spawn during the NASCAR World event (tagged 'CashDrop'). " ..
        "We fire the same remote the game fires on touch - if the server wants " ..
        "you nearby it may ignore distant calls.")
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
    toggle(p5, "Sky plate farm (10k studs up)",
        function() return Config.Farm.Plate end,
        function(v)
            Config.Farm.Plate = v
            if v then
                if UILib and UILib.restoreIdentity then UILib.restoreIdentity() end
                local ok, tp = pcall(function()
                    ensureSkyPlate()
                    return teleportToPlate()
                end)
                if not (ok and skyPlate) then
                    Config.Farm.Plate = false
                    refreshGUI()
                    notify("Sky plate farm failed to start")
                    return
                end
                -- The plate only exists for farming: drive straight lines
                -- until each edge, then u-turn.
                Config.Farm.Enabled = true
                Config.Farm.Steer = 0
                initFarmHook()
                farmState.cashStart = getCash() or 0
                farmState.recoverUntil = 0
                skyState.turning = false
                skyState.turns = 0
                refreshGUI()
                notify(tp and "Sky plate farm on - flattest runway in the game"
                    or "Sky plate farm on - get in a car")
            else
                skyState.turning = false
                pcall(function()
                    if skyPlate then skyPlate:Destroy() end
                end)
                skyPlate = nil
                notify("Sky plate farm off - plate removed")
            end
        end)
    button(p5, "Teleport onto / back to plate", function()
        if not Config.Farm.Plate then
            notify("Enable the sky plate farm first")
            return
        end
        if UILib and UILib.restoreIdentity then UILib.restoreIdentity() end
        local ok, tp = pcall(function()
            ensureSkyPlate()
            return teleportToPlate()
        end)
        notify(ok and tp and "Teleported to the sky plate" or "Sky plate not ready")
    end)
    note(p5, "Holds full throttle for you - income scales with speed, so pair it " ..
        "with a speed multiplier. 0 steer drives straight (aim down a long road " ..
        "first); about 0.3 steers in circles (wide open areas). Auto-reverses for " ..
        "2s when it gets stuck.")
    note(p5, "Sky plate: a personal plate 10,000 studs above the map - nothing " ..
        "to crash into, first gear to top speed, u-turns itself at the edges. " ..
        "Teleporting high up is exactly what anti-cheat watches for; your call.")

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
    section(p6, "Menu")
    bindrow(p6, hotkeyById.ToggleMenu, {
        locked = true,
        lockNote = "RightShift is the menu key and stays bound",
    })
    note(p6, ("Havoc Hub - Driving Empire (%s). Config: %s"):format(SCRIPT_VERSION, CONFIG_FILE))

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
    end)

    pcall(renderESP, cam)
end))

print(("[driving-empire] %s loaded - speed x%.2f, torque x%.2f"):format(
    SCRIPT_VERSION, Config.Vehicle.SpeedMult, Config.Vehicle.TorqueMult))
