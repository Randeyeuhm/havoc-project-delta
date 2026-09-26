--[[
    ============================================
    HAVOC HUB - CRIMINALITY  (games/8343259840.luau)
    ============================================
    Game: Criminality  (GameId 1494262959, dumped in place 8343259840)

      • Camera aimbot   - FOV circle, smoothing, team / visibility checks
      • Player ESP      - boxes, names, health, distance, tracers, chams
      • Weapons         - recoil percentage (scales the game's CamShake value)
      • Misc            - fullbright, anti-AFK, rejoin server

    Anti-cheat notes from the structure dump:
      * the game RENAMED the ReplicatedStorage service to "RepIicatedStorage"
        (capital i) - always reach it with GetService, never by name
      * per-player data: ReplicatedStorage.CharStats/<name> with TeamCode,
        ArmorHP/Head|Body and ArmoredParts/* - used for team checks here
      * moderators can SPECTATE in first person and watch your mouse/camera -
        the aimbot only moves the camera, so keep Smoothness high (soft lock)
        and leave Visible Check on. This script never touches game remotes.

    Menu key: RightShift (locked). Config: criminality_hub_config.json.
]]

if setstackhidden then pcall(setstackhidden, true) end

-- ============================================================
-- SERVICES / STATE
-- ============================================================
local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local Lighting          = game:GetService("Lighting")
local TweenService      = game:GetService("TweenService")
local HttpService       = game:GetService("HttpService")
local VirtualUser       = game:GetService("VirtualUser")
local TeleportService   = game:GetService("TeleportService")
local LocalPlayer       = Players.LocalPlayer

local Connections = {}
local function track(conn)
    table.insert(Connections, conn)
    return conn
end

-- ============================================================
-- CRIMINALITY GAME FACTS  (from the structure dump)
-- ============================================================
-- The game renamed the ReplicatedStorage service to "RepIicatedStorage"
-- (capital i) as an anti-exploit trick - GetService still resolves it, so
-- every access here goes through the service reference, never a name path.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- CharStats/<playerName> holds TeamCode (StringValue), ArmorHP/Head|Body
-- and ArmoredParts/*. TeamCode is the game's "teamed up" code - players on
-- the same code are on the same side even when Roblox teams are empty.
local function charStatsOf(player)
    local folder = ReplicatedStorage:FindFirstChild("CharStats")
    return folder and folder:FindFirstChild(player.Name) or nil
end

local function teamCodeOf(player)
    local stats = charStatsOf(player)
    local tc = stats and stats:FindFirstChild("TeamCode")
    local v = tc and tostring(tc.Value)
    if v and v ~= "" then return v end
    return nil
end

local function sameTeam(player)
    if player == LocalPlayer then return true end
    if player.Team and LocalPlayer.Team and player.Team == LocalPlayer.Team then return true end
    local a, b = teamCodeOf(player), teamCodeOf(LocalPlayer)
    return a ~= nil and a == b
end

-- ============================================================
-- CONFIG  (persisted to criminality_hub_config.json)
-- ============================================================
local CONFIG_FILE = "criminality_hub_config.json"

local DEFAULTS = {
    ESP      = { Enabled = false, TeamCheck = false, VisibleOnly = false, MaxDistance = 2500 },
    -- Criminality: soft default smoothing (6) + Visible Check on - mods can
    -- spectate in first person and watch the camera/mouse, so the lock must
    -- not look mechanical. TeamCheck off by default (most lobbies are solo).
    Aimbot   = { Enabled = false, Mode = "Hold RMB", FOV = 100, Smoothness = 6,
                 TeamCheck = false, VisibleOnly = true, FOVCircle = true },
    Weapons  = { RecoilPct = 100 },
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

do
    if type(isfile) == "function" and isfile(CONFIG_FILE) and type(readfile) == "function" then
        local ok, decoded = pcall(function()
            return HttpService:JSONDecode(readfile(CONFIG_FILE))
        end)
        if ok and type(decoded) == "table" then
            for section, values in pairs(decoded) do
                if type(Config[section]) == "table" and type(values) == "table" then
                    for k, v in pairs(values) do
                        -- Only accept values matching the default's type, so a
                        -- corrupted config can't break runtime assumptions.
                        if type(v) == type(Config[section][k]) then
                            Config[section][k] = v
                        end
                    end
                end
            end
            if Config.Aimbot.Mode ~= "Hold RMB" and Config.Aimbot.Mode ~= "Always" then
                Config.Aimbot.Mode = "Hold RMB"
            end
        end
    end
end

-- ============================================================
-- UI LIBRARY (uilib.luau, shared with the game scripts)
-- ============================================================
-- Sources arrive from the hub loader (it fetches them and stashes them at
-- getgenv().HAVOC_HUB_SOURCES) - pure loadstring, nothing is written to the
-- executor workspace. Running this script manually falls back to local
-- copies when present.
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

-- Bump on every change so the console / window subtitle prove which
-- build is running (same scheme as the other scripts: uvN / de-vNN).
local SCRIPT_VERSION = "crim-v5"

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
        if UILib.VERSION then
            print("[criminality] uilib " .. tostring(UILib.VERSION) .. " loaded")
        else
            warn("[criminality] uilib.luau has no version marker - it is an OLD build; re-run the loader to update it")
        end
    else
        warn("[Havoc Hub] uilib.luau not loaded (" .. tostring(res) .. ") - settings menu will be skipped")
    end
end

-- ============================================================
-- ESP LIBRARY (esp.luau: engine classes; settings live in this menu)
-- ============================================================
local ESP_FILE = "esp.luau"
local ESPUI
do
    local ok, res = pcall(function()
        local src = moduleSource(ESP_FILE)
        if not src then error("no source (loader stash empty, no local file)") end
        local chunk, compileErr = loadstring(src, "@" .. ESP_FILE)
        if not chunk then error("compile error: " .. tostring(compileErr)) end
        return chunk()
    end)
    if ok and type(res) == "table" then
        ESPUI = res
        ESPUI.fill(Config.ESP)
        ESPUI.sanitize(Config.ESP)
        if ESPUI.VERSION then
            print("[criminality] esp " .. tostring(ESPUI.VERSION) .. " loaded")
        else
            warn("[criminality] esp.luau has no version marker - it is an OLD build; re-run the loader to update it")
        end
    else
        warn("[Havoc Hub] esp.luau not loaded (" .. tostring(res) .. ") - ESP disabled")
    end
end

-- ============================================================
-- SCREEN GUI + TOASTS
-- ============================================================
local screenGui
if UILib then
    screenGui = Instance.new("ScreenGui")
    screenGui.Name = "HavocHubUI"
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

-- Toasts come from the UI library (auto-sized with TextService, so long
-- messages wrap instead of clipping). Falls back to a print when there is
-- no menu available.
local notify
if screenGui and UILib and UILib.makeToaster then
    notify = UILib.makeToaster(screenGui)
else
    notify = function(text) print("[Havoc Hub]", tostring(text)) end
end

-- ============================================================
-- GUI CONTROL REGISTRY + UILIB WIRING
-- ============================================================
local guiControls = {}   -- every widget with an update() receives refreshGUI()
local function refreshGUI()
    for _, e in ipairs(guiControls) do
        if e.update then pcall(e.update) end
    end
end
local function addControl(e)
    table.insert(guiControls, e)
    return e
end

local rebuildKeyMap  -- assigned after the Hotkeys table below

if UILib then
    UILib.init{
        notify        = notify,
        save          = saveConfig,
        saveDebounced = saveConfigDebounced,
        onKeybindToggled = function(entry)
            rebuildKeyMap(); saveConfig(); refreshGUI()
        end,
        onKeybindChanged = function(entry)
            rebuildKeyMap(); saveConfig(); refreshGUI()
            print(("[Havoc Hub] Rebound '%s' to %s"):format(entry.Desc, entry.Key.Name))
        end,
    }
    track(UILib.attachInput())
end

-- ============================================================
-- HOTKEYS  (entries also drive the key chips / rows in the menu)
-- ============================================================
local keyMap = {}

local Hotkeys = {
    { Id = "ToggleMenu", Key = Enum.KeyCode.RightShift, Desc = "Toggle Menu", Enabled = true,
      Action = function()
          if screenGui then screenGui.Enabled = not screenGui.Enabled end
      end },

    { Id = "ToggleAimbot", Key = Enum.KeyCode.LeftAlt, Desc = "Toggle Aimbot", Enabled = true,
      Action = function()
          Config.Aimbot.Enabled = not Config.Aimbot.Enabled
          refreshGUI(); saveConfig()
          notify("Aimbot: " .. (Config.Aimbot.Enabled and "on" or "off"))
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
-- FEATURES: PLAYER ESP  (rendering lives in esp.luau)
-- ============================================================
local espRenderer = ESPUI and ESPUI.newRenderer(function() return Config.ESP end)

local ESP_COLOR_ENEMY = Color3.fromRGB(255, 80, 80)
local ESP_COLOR_ALLY  = Color3.fromRGB(82, 202, 128)

local function colorForPlayer(player)
    -- Criminality: Roblox teams when the mode sets them, otherwise the
    -- CharStats TeamCode (players who teamed up share a code).
    if sameTeam(player) then return ESP_COLOR_ALLY end
    if player.Team and LocalPlayer.Team and player.Team ~= LocalPlayer.Team then
        return player.Team.TeamColor.Color
    end
    return ESP_COLOR_ENEMY
end

-- Raycast helper for the ESP "Visible only" filter.
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

-- Best-effort joint positions for skeleton ESP (R15 names first, R6 after).
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
                local teamBlocked = cfg.TeamCheck and sameTeam(player)
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

    espRenderer:render(targets, cam, UserInputService:GetMouseLocation())
end

-- ============================================================
-- FEATURES: AIMBOT (camera lock)
-- ============================================================
local fovCircle = nil
local fovDrawingBroken = false

local function aimingActive()
    if not Config.Aimbot.Enabled then return false end
    if Config.Aimbot.Mode == "Always" then return true end
    return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
end

local function isVisible(char, camPos, targetPos)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = { char }
    if LocalPlayer.Character then table.insert(ignore, LocalPlayer.Character) end
    local cam = workspace.CurrentCamera
    if cam then table.insert(ignore, cam) end
    params.FilterDescendantsInstances = ignore
    return workspace:Raycast(camPos, targetPos - camPos, params) == nil
end

local function findAimTargetPos(cam, mouse)
    local cfg = Config.Aimbot
    local candidates = {}

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            local char = player.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health > 0 then
                local teamBlocked = cfg.TeamCheck and sameTeam(player)
                if not teamBlocked then
                    local head = char:FindFirstChild("Head")
                    local hrp = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
                    local targetPos = head and head.Position
                        or (hrp and (hrp.Position + Vector3.new(0, 1.5, 0)))
                    if targetPos then
                        local sp, onScreen = cam:WorldToViewportPoint(targetPos)
                        if sp.Z > 0 then
                            local d = (Vector2.new(sp.X, sp.Y) - mouse).Magnitude
                            if d <= cfg.FOV then
                                table.insert(candidates, {
                                    pos = targetPos, char = char, dist = d,
                                    onScreen = onScreen,
                                })
                            end
                        end
                    end
                end
            end
        end
    end

    table.sort(candidates, function(a, b) return a.dist < b.dist end)

    local camPos = cam.CFrame.Position
    for _, c in ipairs(candidates) do
        if not cfg.VisibleOnly then return c.pos end
        local ok, visible = pcall(isVisible, c.char, camPos, c.pos)
        if ok and visible then return c.pos end
    end
    return nil
end

local function updateAimbot(cam, mouse)
    if not aimingActive() then return end
    local targetPos = findAimTargetPos(cam, mouse)
    if not targetPos then return end
    local camCF = cam.CFrame
    local goal = CFrame.lookAt(camCF.Position, targetPos)
    local alpha = 1 / math.clamp(Config.Aimbot.Smoothness, 1, 10)
    cam.CFrame = camCF:Lerp(goal, alpha)
end

local function updateFovCircle(mouse)
    local show = Config.Aimbot.Enabled and Config.Aimbot.FOVCircle
    if not show or fovDrawingBroken then
        if fovCircle then fovCircle.Visible = false end
        return
    end
    if not Drawing then fovDrawingBroken = true; return end
    if not fovCircle then
        local ok, circle = pcall(function()
            local c = Drawing.new("Circle")
            c.Filled = false
            c.NumSides = 64
            c.Thickness = 1
            c.Color = Color3.fromRGB(255, 255, 255)
            c.Transparency = 0.4
            return c
        end)
        if not ok then
            fovDrawingBroken = true
            warn("[Havoc Hub] FOV circle failed: " .. tostring(circle))
            return
        end
        fovCircle = circle
    end
    fovCircle.Position = mouse
    fovCircle.Radius = Config.Aimbot.FOV
    fovCircle.Visible = true
end

-- ============================================================
-- FEATURES: RECOIL  (percentage of the game's own recoil)
-- ============================================================
-- What the dump proves:
--   * the game's shared camera-shake spring is kicked from exactly TWO
--     places in the decompiled client - the damage-hit shake and the
--     flashbang/concussion shake - and both multiply CamShakeConfig
--     (Recoil / Accuracy), at RS.Storage.FrameworkStuff.CamShakeConfig.
--   * the WEAPON recoil itself lives in the gun tools' own Client
--     scripts (not present in the dump); they most likely drive the
--     character's CamShakePart Motor6D (read by the camera loop) or
--     apply a camera kick directly.
-- So the slider scales every live CamShakeConfig copy (require-based -
-- instant), and the probe button collects exactly what the equipped gun
-- carries (module tables + value objects) so the gun's own recoil numbers
-- can be scaled directly next.
local recoilState = { tables = {} }

local function looksLikeCamShake(t)
    return type(t) == "table"
        and type(t.Recoil) == "number" and type(t.RecoilSpeed) == "number"
        and type(t.RecoilDamper) == "number" and type(t.AngleX_Min) == "number"
        and type(t.AngleX_Max) == "number" and type(t.Accuracy) == "number"
end

local function camShakeModule()
    local ok, mod = pcall(function()
        local storage = ReplicatedStorage:FindFirstChild("Storage")
        local fw = storage and storage:FindFirstChild("FrameworkStuff")
        return fw and fw:FindFirstChild("CamShakeConfig")
    end)
    return ok and mod or nil
end

local function applyRecoil()
    local pct = tonumber(Config.Weapons.RecoilPct) or 100
    local mod = camShakeModule()
    if mod then
        local ok, cfg = pcall(require, mod)
        if ok and looksLikeCamShake(cfg) and not recoilState.tables[cfg] then
            recoilState.tables[cfg] = { orig = cfg.Recoil }
        end
    end
    local applied, blocked = 0, 0
    for t, rec in pairs(recoilState.tables) do
        local want = rec.orig * (pct / 100)
        local ok = pcall(function() t.Recoil = want end)
        if ok and t.Recoil == want then
            applied += 1
        else
            blocked += 1
        end
    end
    return applied, blocked
end

-- ============================================================
-- PER-GUN RECOIL (the real lever - probe-confirmed)
-- ============================================================
-- Probe output from the live game: every gun's own Config module carries
-- the actual recoil numbers - G-17 showed Recoil=21, RecoilSpeed=8.5,
-- RecoilDamper=0.9999, RecoilRedution=0, AngleX/Y/Z ranges and
-- CameraRecoilingEnabled=true - while the GLOBAL CamShakeConfig.Recoil is
-- 0 (the shared hit-shake is disabled in this build). So the percentage is
-- applied to each gun's Config.Recoil (the per-shot multiplier; the angle
-- ranges feed through it the same way the dumped damage-shake does:
-- kick = rad(Recoil * RAND(angleMin, angleMax) * ...)).
-- Writes are unprotected (CamShake write test came back OK) and the value
-- is re-applied on every equip + slider change, so cached-at-equip
-- consumers pick it up on the next equip too.
local recoilGun = { tables = {} }

local function looksLikeGunConfig(t)
    return type(t) == "table"
        and type(t.Recoil) == "number" and type(t.RecoilSpeed) == "number"
        and type(t.RecoilDamper) == "number" and type(t.CrossExpansion) == "number"
        and type(t.FireRate) == "number" and type(t.Damage) == "number"
end

local function trackGunCfg(cfg)
    if looksLikeGunConfig(cfg) and not recoilGun.tables[cfg] then
        recoilGun.tables[cfg] = { Recoil = cfg.Recoil }
    end
end

local function equippedToolConfig()
    local ok, cfg = pcall(function()
        local char = LocalPlayer.Character
        local tool = char and char:FindFirstChildOfClass("Tool")
        local mod = tool and tool:FindFirstChild("Config")
        if not mod then return nil end
        return require(mod)
    end)
    if ok and type(cfg) == "table" then return cfg end
    return nil
end

local function applyGunRecoil()
    local pct = tonumber(Config.Weapons.RecoilPct) or 100
    local cfg = equippedToolConfig()
    if cfg then trackGunCfg(cfg) end
    local applied = 0
    for t, rec in pairs(recoilGun.tables) do
        local want = rec.Recoil * (pct / 100)
        local ok = pcall(function() t.Recoil = want end)
        if ok and t.Recoil == want then applied += 1 end
    end
    return applied
end

-- ============================================================
-- SPRING INTERCEPTION (the bulletproof lever)
-- ============================================================
-- Every kick - recoil, shake, crosshair drift - flows through a spring
-- object: the code calls spring:accelerate(Vector3(kick)) and the spring
-- integrates it into its position, which the game applies to the camera.
-- Scaling that Vector3 scales the kick at the LAST possible moment: after
-- any config snapshot and after the angle randomization. Two layers:
--   1) the SpringModule factory/class methods are wrapped once at load
--      (covers springs created afterwards, if the executor shares the
--      game's module cache);
--   2) the Deep apply button wraps live spring INSTANCES it finds (shadows
--      their own accelerate) - covers a split module cache.
-- Wrapped methods read the slider live, so changes apply instantly.
local wrappedSpringFns = {}

local function springFactor()
    return (tonumber(Config.Weapons.RecoilPct) or 100) / 100
end

local function wrapSpringFn(name, fn, owner)
    if type(fn) ~= "function" or wrappedSpringFns[fn] then return false end
    owner[name] = function(self, vec, ...)
        local f = springFactor()
        if f ~= 1 and typeof(vec) == "Vector3" then vec = vec * f end
        return fn(self, vec, ...)
    end
    wrappedSpringFns[fn] = true
    wrappedSpringFns[owner[name]] = true
    return true
end

local function hookSpringClass(class)
    if type(class) ~= "table" then return 0 end
    local wrapped = 0
    for _, name in ipairs({ "accelerate", "impulse", "shove", "push", "add" }) do
        if type(class[name]) == "function" and wrapSpringFn(name, class[name], class) then
            wrapped += 1
        end
    end
    return wrapped
end

local function installSpringHook()
    pcall(function()
        local storage = ReplicatedStorage:FindFirstChild("Storage")
        local fw = storage and storage:FindFirstChild("FrameworkStuff")
        local mod = fw and fw:FindFirstChild("SpringModule")
        if not mod then return end
        local m = require(mod)
        if type(m) ~= "table" then return end
        local wrapped = hookSpringClass(m)
        if type(m.spring) == "table" then wrapped += hookSpringClass(m.spring) end
        for _, v in pairs(m) do
            if type(v) == "table" and type(v.new) == "function" then
                wrapped += hookSpringClass(v)
            end
        end
        if wrapped > 0 then
            print(("[criminality] spring hook: wrapped %d spring method(s)"):format(wrapped))
        else
            print("[criminality] spring hook: no methods found on SpringModule (will rely on Deep apply)")
        end
    end)
end

installSpringHook()

local function looksLikeSpring(t)
    return type(t) == "table" and typeof(t.p) == "Vector3" and typeof(t.v) == "Vector3"
        and type(t.s) == "number" and type(t.d) == "number"
end

local function wrapSpringInstance(obj)
    if type(obj) ~= "table" or obj.__havocSpring then return false end
    local orig = obj.accelerate
    if type(orig) ~= "function" then
        local mt = getmetatable(obj)
        local idx = type(mt) == "table" and mt.__index
        if type(idx) == "table" and type(idx.accelerate) == "function" then orig = idx.accelerate end
    end
    if type(orig) ~= "function" then return false end
    if wrappedSpringFns[orig] then return false end  -- class hook already covers it
    obj.__havocSpring = true
    obj.accelerate = function(self, vec, ...)
        local f = springFactor()
        if f ~= 1 and typeof(vec) == "Vector3" then vec = vec * f end
        return orig(self, vec, ...)
    end
    return true
end

-- One-time fallback scan (button-triggered, NEVER automatic): finds the
-- config tables the weapon scripts actually hold AND every live spring
-- instance, scaling/wrapping both.
local function deepScanAll()
    if type(getgc) ~= "function" then return 0, 0 end
    local cfgs, springs = 0, 0
    local function consider(t)
        if type(t) ~= "table" then return end
        if looksLikeGunConfig(t) and not recoilGun.tables[t] then
            recoilGun.tables[t] = { Recoil = t.Recoil }
            cfgs += 1
        elseif looksLikeSpring(t) and wrapSpringInstance(t) then
            springs += 1
        end
    end
    pcall(function()
        for _, obj in pairs(getgc(true)) do
            if type(obj) == "table" then
                consider(obj)
            elseif type(obj) == "function" then
                pcall(function()
                    local i = 1
                    while true do
                        local name, val = debug.getupvalue(obj, i)
                        if not name then break end
                        consider(val)
                        i += 1
                    end
                end)
            end
        end
    end)
    return cfgs, springs
end

-- Scale the current gun + every gun equipped later (tools move from the
-- backpack into the character when equipped).
local function watchToolsForRecoil(char)
    if not char then return end
    task.delay(0.25, function() pcall(applyGunRecoil) end)
    char.ChildAdded:Connect(function(child)
        if not child:IsA("Tool") then return end
        task.delay(0.25, function() pcall(applyGunRecoil) end)
        pcall(function()
            local values = child:FindFirstChild("Values")
            local eq = values and values:FindFirstChild("Equipped")
            if eq then
                eq.Changed:Connect(function()
                    if eq.Value then
                        task.delay(0.3, function() pcall(applyGunRecoil) end)
                    end
                end)
            end
        end)
    end)
end

if LocalPlayer.Character then watchToolsForRecoil(LocalPlayer.Character) end
LocalPlayer.CharacterAdded:Connect(watchToolsForRecoil)

-- Probe: run it with a gun equipped and copy the console output back.
-- It never fires remotes - it only reads what the tool carries.
local function recoilProbe()
    print("==== [criminality] recoil probe ====")
    local mod = camShakeModule()
    print("CamShakeConfig:", mod and mod:GetFullName() or "NOT FOUND")
    if mod then
        local ok, cfg = pcall(require, mod)
        if ok and type(cfg) == "table" then
            local keys = {}
            for k, v in pairs(cfg) do
                table.insert(keys, ("%s=%s(%s)"):format(tostring(k), tostring(v), type(v)))
            end
            table.sort(keys)
            print("  fields:", table.concat(keys, ", "))
            local orig = cfg.Recoil
            local okW = pcall(function() cfg.Recoil = (tonumber(orig) or 1) * 0.5 end)
            local now = cfg.Recoil
            pcall(function() cfg.Recoil = orig end)
            print(("  write test: %s (orig=%s now=%s, restored)"):format(
                okW and "OK" or "FAILED", tostring(orig), tostring(now)))
        else
            print("  require failed:", tostring(cfg))
        end
    end
    local shake = _G.camShakePart
    print("camShakePart:", tostring(shake), shake and shake:GetFullName() or "")
    pcall(function()
        if shake then
            local m = shake:FindFirstChild("Motor6D")
            print("  Motor6D:", tostring(m), m and ("Transform=" .. tostring(m.Transform)) or "")
        end
    end)
    print("CamShakeCFrameOffset1:", tostring(_G.CamShakeCFrameOffset1))
    pcall(function()
        local storage = ReplicatedStorage:FindFirstChild("Storage")
        local fw = storage and storage:FindFirstChild("FrameworkStuff")
        local mod = fw and fw:FindFirstChild("SpringModule")
        if not mod then return end
        local m = require(mod)
        if type(m) ~= "table" then return end
        local top = {}
        for k, v in pairs(m) do table.insert(top, tostring(k) .. ":" .. type(v)) end
        table.sort(top)
        print("SpringModule fields:", table.concat(top, ", "))
        local class = type(m.spring) == "table" and m.spring or m
        local meth = {}
        for k, v in pairs(class) do
            if type(v) == "function" then table.insert(meth, tostring(k)) end
        end
        table.sort(meth)
        print("  factory members:", #meth > 0 and table.concat(meth, ", ") or "(none at top level)")
    end)
    local char = LocalPlayer.Character
    local tool = char and char:FindFirstChildOfClass("Tool")
    print("equipped tool:", tool and tool.Name or "NONE (equip a gun)")
    if tool then
        for _, d in ipairs(tool:GetDescendants()) do
            if d:IsA("LocalScript") then
                print(("  script present: %s"):format(d.Name))
            elseif d:IsA("ModuleScript") and (d.Name == "Config" or d.Name == "PassConfig") then
                local ok2, res = pcall(require, d)
                if ok2 and type(res) == "table" then
                    local parts = {}
                    for k, v in pairs(res) do
                        local tv = type(v)
                        if tv == "number" or tv == "string" or tv == "boolean" then
                            table.insert(parts, ("%s=%s"):format(tostring(k), tostring(v)))
                        elseif tv == "table" then
                            table.insert(parts, tostring(k) .. "={...}")
                        end
                    end
                    table.sort(parts)
                    print(("  module %s: %s"):format(d.Name, #parts > 0 and table.concat(parts, ", ") or "(no flat fields)"))
                else
                    print(("  module %s: %s"):format(d.Name, ok2 and ("returned " .. type(res)) or ("failed: " .. tostring(res))))
                end
            end
        end
        for _, d in ipairs(tool:GetDescendants()) do
            if d:IsA("ValueBase") then
                print(("  value %s (%s) = %s"):format(d:GetFullName(), d.ClassName, tostring(d.Value)))
            end
        end
    end
    print("==== end recoil probe (send this output back) ====")
end

-- ============================================================
-- INPUT
-- ============================================================
track(UserInputService.InputBegan:Connect(function(input, processed)
    -- Keybind rebinds are captured by uilib: Escape / click-away cancels,
    -- duplicate keys are refused with a toast.
    if UILib and UILib.handleRebindInput(input) then return end
    if processed then return end
    if UserInputService:GetFocusedTextBox() then return end

    local entry = keyMap[input.KeyCode]
    if entry and entry.Action then
        local ok, err = pcall(entry.Action)
        if not ok then warn(("[Havoc Hub] Hotkey '%s' errored: %s"):format(entry.Desc, tostring(err))) end
    end
end))

-- ============================================================
-- MENU
-- ============================================================
local function buildMenu()
    -- Same window sizing as Project Delta: fill most of the viewport with
    -- sane min/max clamps, instead of the old fixed 540x360 (too short -
    -- long pages like ESP ran off the bottom).
    local viewport = (workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize) or Vector2.new(1920, 1080)
    local winW = math.clamp(viewport.X - 60, 380, 500)
    local winH = math.clamp(viewport.Y - 80, 340, 720)
    local win = UILib.makeWindow{
        parent = screenGui,
        name = "Main",
        title = "HAVOC HUB  ·  CRIMINALITY",
        subtitle = "PlaceId " .. tostring(game.PlaceId) .. "  ·  " .. SCRIPT_VERSION,
        size = UDim2.new(0, winW, 0, winH),
        position = UDim2.new(0, 30, 0, 40),
        tabs = { "Aimbot", "ESP", "Weapons", "Misc" },
        controls = guiControls,
        footerHint = "RightShift — show / hide this menu",
        -- The X hides the whole GUI (RightShift brings it back); the
        -- window itself stays visible inside it.
        onClose = function()
            screenGui.Enabled = false
            notify("Menu hidden - press RightShift to reopen")
        end,
    }
    local pages = { win.tab(1), win.tab(2), win.tab(3), win.tab(4) }

    -- Page helpers: every widget goes through a labelled pcall, so one bad
    -- row can never empty the rest of the menu - and the console names
    -- exactly what failed and how many controls actually got built.
    local builtCount = 0
    local function guard(what, fn)
        local ok, e = pcall(fn)
        if ok and type(e) == "table" then
            builtCount = builtCount + 1
            addControl(e)
            return e
        end
        warn(("[criminality] widget '%s' failed: %s"):format(what, tostring(e)))
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
    local function dropdown(page, label, getItems, getSelected, onSelect)
        guard("dropdown " .. label, function()
            return UILib.makeDropdown(page, label, getItems, getSelected, function(v)
                print(("[criminality] %s = %s"):format(label, tostring(v)))
                onSelect(v)
            end, win.popupLayer)
        end)
    end
    local function button(page, text, onClick, opts)
        guard("button " .. text, function() return UILib.makeButton(page, text, onClick, opts) end)
    end
    local function note(page, text) pcall(function() UILib.makeNote(page, text, "auto") end) end
    local function color(page, label, cfgTable, prefix)
        guard("colour " .. label, function()
            return UILib.makeColorPicker(page, label, cfgTable, prefix, saveConfig)
        end)
    end
    local function multiselect(page, text, items, cfgTable, prefix)
        guard("multiselect " .. text, function()
            return UILib.makeMultiSelect(page, text, items,
                function(item) return cfgTable[prefix .. item] == true end,
                function(item, on) cfgTable[prefix .. item] = on end,
                { overlayParent = win.popupLayer })
        end)
    end

    -- ---------------- Aimbot ----------------
    local p1 = pages[1]
    section(p1, "Aimbot")
    toggle(p1, "Aimbot Enabled",
        function() return Config.Aimbot.Enabled end,
        function(v) Config.Aimbot.Enabled = v end,
        hotkeyById.ToggleAimbot)
    local function onAimMode(v)
        -- Picking "Always" should start aiming right away instead of silently
        -- doing nothing while the master toggle is off.
        Config.Aimbot.Mode = v
        if v == "Always" then Config.Aimbot.Enabled = true end
        saveConfig(); refreshGUI()
    end
    dropdown(p1, "Activation",
        function() return { "Hold RMB", "Always" } end,
        function() return Config.Aimbot.Mode end,
        onAimMode)
    slider(p1, "FOV Radius",
        function() return Config.Aimbot.FOV end,
        function(v) Config.Aimbot.FOV = v end, 5, 20, 600)
    slider(p1, "Smoothness",
        function() return Config.Aimbot.Smoothness end,
        function(v) Config.Aimbot.Smoothness = v end, 1, 1, 10)
    toggle(p1, "Show FOV Circle",
        function() return Config.Aimbot.FOVCircle end,
        function(v) Config.Aimbot.FOVCircle = v end)
    toggle(p1, "Team Check",
        function() return Config.Aimbot.TeamCheck end,
        function(v) Config.Aimbot.TeamCheck = v end)
    toggle(p1, "Visible Check",
        function() return Config.Aimbot.VisibleOnly end,
        function(v) Config.Aimbot.VisibleOnly = v end)
    bindrow(p1, hotkeyById.ToggleAimbot)
    note(p1, "Camera aim: locks onto the closest player inside the FOV circle - Hold RMB (or Always). " ..
        "WARNING: moderators can spectate in first person and watch your mouse/camera - keep Smoothness 6+ " ..
        "so the lock looks human, and leave Visible Check on.")

    -- ---------------- ESP ----------------
    local p2 = pages[2]
    section(p2, "Player ESP")
    toggle(p2, "Player ESP",
        function() return Config.ESP.Enabled end,
        function(v) Config.ESP.Enabled = v end,
        hotkeyById.ToggleESP)
    bindrow(p2, hotkeyById.ToggleESP)
    section(p2, "Targeting")
    toggle(p2, "Team Check",
        function() return Config.ESP.TeamCheck end,
        function(v) Config.ESP.TeamCheck = v end)
    toggle(p2, "Visible Only",
        function() return Config.ESP.VisibleOnly end,
        function(v) Config.ESP.VisibleOnly = v end)
    slider(p2, "Max Distance",
        function() return Config.ESP.MaxDistance end,
        function(v) Config.ESP.MaxDistance = v end, 100, 100, 10000)
    section(p2, "Box")
    toggle(p2, "Box",
        function() return Config.ESP.Box end,
        function(v) Config.ESP.Box = v end)
    dropdown(p2, "Box style",
        function() return { "Corner", "Full" } end,
        function() return Config.ESP.BoxStyle end,
        function(v) Config.ESP.BoxStyle = v end)
    slider(p2, "Corner length",
        function() return Config.ESP.BoxCornerLength end,
        function(v) Config.ESP.BoxCornerLength = v end, 1, 0, 40)
    slider(p2, "Box thickness",
        function() return Config.ESP.BoxThickness end,
        function(v) Config.ESP.BoxThickness = v end, 1, 1, 6)
    slider(p2, "Box opacity",
        function() return Config.ESP.BoxTransparency end,
        function(v) Config.ESP.BoxTransparency = v end, 0.05, 0, 1)
    color(p2, "Box colour", Config.ESP, "Box")
    section(p2, "Name")
    toggle(p2, "Name",
        function() return Config.ESP.Name end,
        function(v) Config.ESP.Name = v end)
    dropdown(p2, "Source",
        function() return { "Username", "DisplayName" } end,
        function() return Config.ESP.NameSource end,
        function(v) Config.ESP.NameSource = v end)
    slider(p2, "Name size",
        function() return Config.ESP.NameSize end,
        function(v) Config.ESP.NameSize = v end, 1, 8, 24)
    slider(p2, "Name opacity",
        function() return Config.ESP.NameTransparency end,
        function(v) Config.ESP.NameTransparency = v end, 0.05, 0, 1)
    color(p2, "Name colour", Config.ESP, "Name")
    section(p2, "Health")
    toggle(p2, "Health",
        function() return Config.ESP.Health end,
        function(v) Config.ESP.Health = v end)
    slider(p2, "Health size",
        function() return Config.ESP.HealthSize end,
        function(v) Config.ESP.HealthSize = v end, 1, 8, 24)
    slider(p2, "Health opacity",
        function() return Config.ESP.HealthTransparency end,
        function(v) Config.ESP.HealthTransparency = v end, 0.05, 0, 1)
    section(p2, "Distance")
    toggle(p2, "Distance",
        function() return Config.ESP.Distance end,
        function(v) Config.ESP.Distance = v end)
    slider(p2, "Distance size",
        function() return Config.ESP.DistanceSize end,
        function(v) Config.ESP.DistanceSize = v end, 1, 8, 24)
    slider(p2, "Distance opacity",
        function() return Config.ESP.DistanceTransparency end,
        function(v) Config.ESP.DistanceTransparency = v end, 0.05, 0, 1)
    color(p2, "Distance colour", Config.ESP, "Distance")
    section(p2, "Chams")
    multiselect(p2, "Parts to highlight", { "Head", "Body" }, Config.ESP, "Chams")
    toggle(p2, "Filled",
        function() return Config.ESP.ChamsFilled ~= false end,
        function(v) Config.ESP.ChamsFilled = v end)
    slider(p2, "Fill opacity",
        function() return Config.ESP.ChamsTransparency end,
        function(v) Config.ESP.ChamsTransparency = v end, 0.05, 0, 1)
    color(p2, "Chams colour", Config.ESP, "Chams")
    section(p2, "Tracers")
    toggle(p2, "Tracers",
        function() return Config.ESP.Tracers end,
        function(v) Config.ESP.Tracers = v end)
    dropdown(p2, "Origin",
        function() return { "Bottom", "Center" } end,
        function() return Config.ESP.TracerOrigin end,
        function(v) Config.ESP.TracerOrigin = v end)
    slider(p2, "Tracer thickness",
        function() return Config.ESP.TracerThickness end,
        function(v) Config.ESP.TracerThickness = v end, 1, 1, 5)
    slider(p2, "Tracer opacity",
        function() return Config.ESP.TracerTransparency end,
        function(v) Config.ESP.TracerTransparency = v end, 0.05, 0, 1)
    color(p2, "Tracer colour", Config.ESP, "Tracer")
    note(p2, "Opacity sliders: 1 = fully visible.")

    -- ---------------- Weapons ----------------
    local p3 = pages[3]
    section(p3, "Recoil")
    slider(p3, "Recoil percentage",
        function() return Config.Weapons.RecoilPct end,
        function(v)
            Config.Weapons.RecoilPct = v
            task.spawn(function()
                local applied, blocked = applyRecoil()
                local guns = applyGunRecoil()
                print(("[criminality] recoil %d%% -> gun configs %d, CamShake %d, springs live-scaled%s"):format(
                    math.floor(v + 0.5), guns, applied, blocked > 0 and (" (" .. blocked .. " locked)") or ""))
            end)
        end, 5, 0, 200)
    button(p3, "Probe recoil (console)", function()
        task.spawn(function()
            local applied, blocked = applyRecoil()
            local tracked = 0
            for _ in pairs(recoilState.tables) do tracked += 1 end
            local pct = math.floor((tonumber(Config.Weapons.RecoilPct) or 100) + 0.5)
            notify(("Recoil: %d CamShake copy(ies) tracked, %d scaled%s (set %d%%)"):format(
                tracked, applied, blocked > 0 and (", " .. blocked .. " locked") or "", pct))
            recoilProbe()
        end)
    end)
    button(p3, "Deep apply (one-time scan)", function()
        task.spawn(function()
            local cfgs, springs = deepScanAll()
            local guns = applyGunRecoil()
            local shake = applyRecoil()
            notify(("Deep scan: +%d gun config(s), +%d spring(s) wrapped - shoot to test"):format(cfgs, springs))
            print(("[criminality] deep scan: +%d configs, +%d springs wrapped, %d guns tracked, CamShake %d (pct %d%%)"):format(
                cfgs, springs, guns, shake, math.floor((tonumber(Config.Weapons.RecoilPct) or 100) + 0.5)))
        end)
    end)
    note(p3, "100% = the game's own recoil. Two layers: (1) each gun's own config (Recoil=21 on the G-17) is " ..
        "scaled on equip/slider change; (2) every kick that flows through the spring system is live-scaled, so its " ..
        "amount scales after any snapshot. If shooting still feels the same: equip the gun, hit Deep apply once " ..
        "(one-time scan), shoot again.")

    -- ---------------- Misc ----------------
    local p4 = pages[4]
    section(p4, "World")
    toggle(p4, "Fullbright",
        function() return Config.Misc.Fullbright end,
        function(v) Config.Misc.Fullbright = v; setFullbright(v) end)
    section(p4, "Utility")
    toggle(p4, "Anti-AFK",
        function() return Config.Misc.AntiAFK end,
        function(v) Config.Misc.AntiAFK = v end)
    bindrow(p4, hotkeyById.ToggleMenu, {
        locked = true,
        lockNote = "RightShift is the menu key and stays bound",
    })
    button(p4, "Rejoin Server", function()
        notify("Rejoining…")
        pcall(function() TeleportService:Teleport(game.PlaceId, LocalPlayer) end)
    end, { confirm = true, confirmText = "Click again to rejoin" })
    note(p4, "Criminality: the game renamed ReplicatedStorage ('RepIicatedStorage') and runs client/moderation " ..
        "systems - this script only moves YOUR CAMERA and draws locally, it never touches game remotes. " ..
        "Keep aimbot smoothing high when a moderator could be watching.")

    win.setTab(1)
    print(("[criminality] %s menu built (%d controls)"):format(SCRIPT_VERSION, builtCount))
end

if UILib and screenGui then
    local ok, err = pcall(buildMenu)
    if not ok then
        warn("[Havoc Hub] menu build failed: " .. tostring(err))
    end
end

-- ============================================================
-- CONNECTIONS / BOOT
-- ============================================================
track(RunService.RenderStepped:Connect(function()
    local cam = workspace.CurrentCamera
    if not cam then return end
    local mouse = UserInputService:GetMouseLocation()
    pcall(renderESP, cam)
    pcall(updateFovCircle, mouse)
end))

-- Camera aim runs at Camera priority + 1: the game's camera module rewrites
-- Camera.CFrame every frame, so a plain RenderStepped write is overwritten
-- before it ever renders (same reason Havoc's third person binds here).
RunService:BindToRenderStep("HavocHubAimbot", Enum.RenderPriority.Camera.Value + 1, function()
    local cam = workspace.CurrentCamera
    if not cam then return end
    pcall(updateAimbot, cam, UserInputService:GetMouseLocation())
end)

-- Apply the saved state once on load.
if Config.Misc.Fullbright then pcall(setFullbright, true) end
task.spawn(function()
    local applied = applyRecoil()
    local guns = applyGunRecoil()
    local pct = tonumber(Config.Weapons.RecoilPct) or 100
    if pct ~= 100 then
        print(("[criminality] recoil %d%% active - gun configs %d, CamShake %d, spring hook installed"):format(
            math.floor(pct + 0.5), guns, applied))
    end
end)

print(("[Havoc Hub] Criminality script loaded (PlaceId %d)"):format(game.PlaceId))
notify("Criminality loaded - aimbot + ESP. Keep smoothing high near moderators")
