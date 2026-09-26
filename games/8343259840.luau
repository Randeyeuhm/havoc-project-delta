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
local SCRIPT_VERSION = "crim-v9"

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
        recoilGun.tables[cfg] = {
            Recoil = cfg.Recoil,
            Speed = tonumber(cfg.RecoilSpeed),
            Damper = tonumber(cfg.RecoilDamper),
            Redution = tonumber(cfg.RecoilRedution),
        }
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
        -- the kit also carries an intended reduction factor (RecoilRedution)
        -- - set it from the same slider so whichever value the client reads
        -- (live or at load) lands on the percentage.
        if type(t.RecoilRedution) == "number" then
            pcall(function() t.RecoilRedution = math.clamp(1 - pct / 100, 0, 1) end)
        end
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

local wrapSpringInstance  -- assigned below; the factory wrapper uses it

local function installSpringHook()
    pcall(function()
        local storage = ReplicatedStorage:FindFirstChild("Storage")
        local fw = storage and storage:FindFirstChild("FrameworkStuff")
        local mod = fw and fw:FindFirstChild("SpringModule")
        if not mod then return end
        local m = require(mod)
        if type(m) ~= "table" then return end
        local detail = {}
        -- the factory (probe: SpringModule = {mt=table, new=function}): wrap
        -- new so every spring created afterwards gets its accelerate wrapped
        if type(m.new) == "function" and not wrappedSpringFns[m.new] then
            local origNew = m.new
            m.new = function(...)
                local inst = origNew(...)
                if wrapSpringInstance then pcall(wrapSpringInstance, inst) end
                return inst
            end
            wrappedSpringFns[origNew] = true
            wrappedSpringFns[m.new] = true
            table.insert(detail, "new")
        end
        -- class methods live on mt / its __index (and legacy module shapes)
        local function wrapMethods(tbl, label)
            if type(tbl) ~= "table" then return end
            for _, name in ipairs({ "accelerate", "impulse", "shove", "push", "add" }) do
                if type(tbl[name]) == "function" and wrapSpringFn(name, tbl[name], tbl) then
                    table.insert(detail, label .. "." .. name)
                end
            end
        end
        wrapMethods(m, "self")
        wrapMethods(m.mt, "mt")
        if type(m.mt) == "table" and type(m.mt.__index) == "table" then
            wrapMethods(m.mt.__index, "mt.__index")
        end
        if type(m.spring) == "table" then
            wrapMethods(m.spring, "spring")
            if type(m.spring.mt) == "table" then wrapMethods(m.spring.mt, "spring.mt") end
        end
        if #detail > 0 then
            print(("[criminality] spring hook: wrapped %s"):format(table.concat(detail, ", ")))
        else
            local names = {}
            if type(m.mt) == "table" then
                for k, v in pairs(m.mt) do table.insert(names, tostring(k) .. ":" .. type(v)) end
            end
            table.sort(names)
            print(("[criminality] spring hook: nothing obvious to wrap (mt: %s)"):format(
                #names > 0 and table.concat(names, ", ") or "empty"))
        end
    end)
end

installSpringHook()

local function looksLikeSpring(t)
    return type(t) == "table" and typeof(t.p) == "Vector3" and typeof(t.v) == "Vector3"
        and type(t.s) == "number" and type(t.d) == "number"
end

wrapSpringInstance = function(obj)
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

-- ============================================================
-- SNAPSHOT PATCHING (slider changes without re-picking the gun)
-- ============================================================
-- The gun Client script copies Config values into locals when it loads
-- (confirmed live: a scaled table does nothing to a gun that loaded before
-- the change, while a freshly picked gun obeys). Those copies live on as
-- UPVALUES of the script's closures - this layer finds them by name
-- (Recoil / RecoilRedution) through getscriptclosure and rewrites them on
-- every slider move, so changing the percentage behaves exactly like a
-- drop + pickup.
local recoilSnapshots = { list = {}, seen = {} }

local function classifyRecoilUpvalue(name)
    local ln = string.lower(tostring(name))
    if ln == "recoil" then return "amount" end
    if string.find(ln, "recoil", 1, true) then
        if string.find(ln, "speed", 1, true) or string.find(ln, "damper", 1, true) then return nil end
        if string.find(ln, "reduc", 1, true) or string.find(ln, "redut", 1, true) then return "reduction" end
    end
    return nil
end

local function addSnapshot(fn, idx, name, value, base)
    local key = tostring(fn) .. "#" .. tostring(idx)
    if recoilSnapshots.seen[key] then return false end
    local kind = classifyRecoilUpvalue(name)
    if not kind or type(value) ~= "number" then return false end
    recoilSnapshots.seen[key] = true
    local orig = (kind == "amount" and tonumber(base)) or tonumber(value) or 0
    table.insert(recoilSnapshots.list, { fn = fn, idx = idx, kind = kind, orig = orig, name = tostring(name) })
    return true
end

local function applySnapshotPatches()
    local pct = tonumber(Config.Weapons.RecoilPct) or 100
    local n = 0
    for _, p in ipairs(recoilSnapshots.list) do
        local want
        if p.kind == "amount" then
            want = p.orig * (pct / 100)
        else
            want = math.clamp(1 - pct / 100, 0, 1)
        end
        local ok = pcall(debug.setupvalue, p.fn, p.idx, want)
        if ok then n += 1 end
    end
    return n
end

-- ============================================================
-- ANCHORED PATCHING (finds the copies the name search misses)
-- ============================================================
-- Functions that touch the recoil fields name them in their string
-- constants ("Recoil" / "RecoilRedution" appear as indexing constants).
-- Any table those functions hold with a numeric Recoil field (state
-- caches, weapon-service copies) is tracked like a config and scaled;
-- number upvalues that match the gun's original Recoil are patched
-- directly. The Deep apply button also runs this over the whole weapon
-- service bundle (PlayerScripts E2CJMS/XIIX).
local recoilNumbers = { list = {}, seen = {} }
local ANCHOR_FIELDS = { Recoil = true, RecoilRedution = true }

local function fnTouchesRecoil(fn)
    local ok, consts = pcall(debug.getconstants, fn)
    if not ok or type(consts) ~= "table" then return false end
    for _, c in ipairs(consts) do
        if type(c) == "string" and ANCHOR_FIELDS[c] then return true end
    end
    return false
end

local function scanAnchoredClosure(fn, seen, budget, baseOrig, out)
    if type(fn) ~= "function" or seen[fn] or budget.count > budget.max then return end
    seen[fn] = true
    budget.count += 1
    if fnTouchesRecoil(fn) then
        out.anchors += 1
        pcall(function()
            local pct = tonumber(Config.Weapons.RecoilPct) or 100
            local i = 1
            while true do
                local name, val = debug.getupvalue(fn, i)
                if not name then break end
                if type(val) == "table" then
                    if type(val.Recoil) == "number" and not recoilGun.tables[val] then
                        local orig = val.Recoil
                        if baseOrig then
                            local scaled = baseOrig * (pct / 100)
                            if math.abs(orig - scaled) < 0.51 then orig = baseOrig end
                        end
                        recoilGun.tables[val] = { Recoil = orig }
                        out.tables += 1
                    end
                elseif typeof(val) == "number" and baseOrig then
                    local scaled = baseOrig * (pct / 100)
                    if math.abs(val - baseOrig) < 0.51 or math.abs(val - scaled) < 0.51 then
                        local key = tostring(fn) .. "#" .. tostring(i)
                        if not recoilNumbers.seen[key] then
                            recoilNumbers.seen[key] = true
                            table.insert(recoilNumbers.list, { fn = fn, idx = i, base = baseOrig, name = tostring(name) })
                            out.numbers += 1
                        end
                    end
                end
                i += 1
            end
        end)
    end
    pcall(function()
        for _, proto in ipairs(debug.getprotos(fn)) do
            scanAnchoredClosure(proto, seen, budget, baseOrig, out)
        end
    end)
end

local function anchoredBaseOrig(tool)
    local base = nil
    pcall(function()
        local mod = tool and tool:FindFirstChild("Config")
        if not mod then return end
        local cfg = require(mod)
        if type(cfg) == "table" and recoilGun.tables[cfg] then base = recoilGun.tables[cfg].Recoil end
    end)
    return base
end

local function scanAnchoredAll()
    local out = { anchors = 0, tables = 0, numbers = 0 }
    if type(getscriptclosure) ~= "function" then return out end
    local char = LocalPlayer.Character
    local tool = char and char:FindFirstChildOfClass("Tool")
    if not tool then return out end
    local baseOrig = anchoredBaseOrig(tool)
    local seen, budget = {}, { count = 0, max = 600 }
    pcall(function()
        for _, name in ipairs({ "Client", "PassClient" }) do
            local scr = tool:FindFirstChild(name)
            if scr and scr:IsA("LocalScript") then
                local ok, closure = pcall(getscriptclosure, scr)
                if ok and type(closure) == "function" then
                    scanAnchoredClosure(closure, seen, budget, baseOrig, out)
                end
            end
        end
    end)
    return out
end

local function scanAnchoredBundle()
    local out = { anchors = 0, tables = 0, numbers = 0 }
    if type(getscriptclosure) ~= "function" then return out end
    pcall(function()
        local char = LocalPlayer.Character
        local tool = char and char:FindFirstChildOfClass("Tool")
        local baseOrig = anchoredBaseOrig(tool)
        local ps = LocalPlayer:FindFirstChild("PlayerScripts")
        local bundle = ps and ps:FindFirstChild("E2CJMS")
        local x = bundle and bundle:FindFirstChild("XIIX")
        if not x then return end
        local ok, closure = pcall(getscriptclosure, x)
        if ok and type(closure) == "function" then
            local seen, budget = {}, { count = 0, max = 3000 }
            scanAnchoredClosure(closure, seen, budget, baseOrig, out)
        end
    end)
    return out
end

local function applyAnchoredPatches()
    local pct = tonumber(Config.Weapons.RecoilPct) or 100
    local n = 0
    for _, p in ipairs(recoilNumbers.list) do
        local want = p.base * (pct / 100)
        if pcall(debug.setupvalue, p.fn, p.idx, want) then n += 1 end
    end
    return n
end

-- ============================================================
-- VALUE HUNT (ungated: finds copies by their NUMBERS, no names needed)
-- ============================================================
-- The identifier-based sweeps can come up empty (stripped names, no
-- indexing constants, an executor without getconstants). This one needs
-- NOTHING but the numbers: it walks the equipped gun's own script
-- closures and flags upvalue numbers equal to the gun's original Recoil
-- (21 on a G-17) or its currently-scaled value, any upvalue TABLE with a
-- numeric Recoil field, and tables carrying the kit's distinctive
-- RecoilSpeed / RecoilDamper numbers (8.5 / 0.9999) - recoil state under
-- ANY field naming. Candidates are patched live; every scan reports the
-- equipped tool + counts so nothing stays guesswork.
local recoilCandidates = { numbers = { list = {}, seen = {} }, fields = { list = {}, seen = {} } }

local function nearVal(a, b)
    return type(a) == "number" and type(b) == "number" and math.abs(a - b) < 0.01
end

local function scanValueClosure(fn, seen, budget, ctx, out)
    if type(fn) ~= "function" or seen[fn] or budget.count > budget.max then return end
    seen[fn] = true
    budget.count += 1
    pcall(function()
        local i = 1
        while true do
            local name, val = debug.getupvalue(fn, i)
            if not name then break end
            if typeof(val) == "number" then
                out.numbers_seen += 1
                if ctx.orig and (nearVal(val, ctx.orig) or nearVal(val, ctx.orig * ctx.pct / 100)) then
                    local lname = string.lower(tostring(name))
                    local blocked = string.find(lname, "damage", 1, true) or string.find(lname, "health", 1, true)
                        or string.find(lname, "armor", 1, true) or string.find(lname, "range", 1, true)
                    if blocked then
                        out.number_blocked += 1
                    else
                        local key = tostring(fn) .. "#" .. tostring(i)
                        if not recoilCandidates.numbers.seen[key] then
                            recoilCandidates.numbers.seen[key] = true
                            table.insert(recoilCandidates.numbers.list, { fn = fn, idx = i, base = ctx.orig, name = tostring(name) })
                            out.number_patches += 1
                        end
                    end
                end
                if ctx.speed and nearVal(val, ctx.speed) then out.speed_hits += 1 end
                if ctx.damper and nearVal(val, ctx.damper) then out.damper_hits += 1 end
            elseif type(val) == "table" then
                local t = val
                if type(t.Recoil) == "number" and not recoilGun.tables[t] then
                    local orig = t.Recoil
                    if ctx.orig and (nearVal(orig, ctx.orig) or nearVal(orig, ctx.orig * ctx.pct / 100)) then orig = ctx.orig end
                    recoilGun.tables[t] = { Recoil = orig }
                    out.table_hits += 1
                end
                local combo = false
                local scanned = 0
                for _, v in pairs(t) do
                    scanned += 1
                    if scanned > 60 then break end
                    if typeof(v) == "number" and ctx.orig and
                        ((ctx.speed and nearVal(v, ctx.speed)) or (ctx.damper and nearVal(v, ctx.damper)) or nearVal(v, ctx.orig)) then
                        combo = true
                    end
                end
                if combo and not recoilGun.tables[t] then
                    out.combo_tables += 1
                    for k, v in pairs(t) do
                        if typeof(v) == "number" and ctx.orig and (nearVal(v, ctx.orig) or nearVal(v, ctx.orig * ctx.pct / 100)) then
                            local key = tostring(t) .. "." .. tostring(k)
                            if not recoilCandidates.fields.seen[key] then
                                recoilCandidates.fields.seen[key] = true
                                table.insert(recoilCandidates.fields.list, { tbl = t, key = k, base = ctx.orig, name = tostring(k) })
                                out.field_patches += 1
                            end
                        end
                    end
                end
            end
            i += 1
        end
    end)
    pcall(function()
        for _, proto in ipairs(debug.getprotos(fn)) do
            scanValueClosure(proto, seen, budget, ctx, out)
        end
    end)
end

local function valueCtx(tool)
    local ctx = { tool = tool and tool.Name or nil, orig = nil, speed = nil, damper = nil, pct = tonumber(Config.Weapons.RecoilPct) or 100 }
    pcall(function()
        local mod = tool and tool:FindFirstChild("Config")
        if not mod then return end
        local cfg = require(mod)
        local rec = type(cfg) == "table" and recoilGun.tables[cfg]
        if rec then
            ctx.orig = tonumber(rec.Recoil)
            ctx.speed = tonumber(rec.Speed)
            ctx.damper = tonumber(rec.Damper)
        end
    end)
    return ctx
end

local function newScanOut()
    return { tool = "NONE", scripts = 0, numbers_seen = 0, number_patches = 0, number_blocked = 0,
        table_hits = 0, combo_tables = 0, field_patches = 0, speed_hits = 0, damper_hits = 0, getconstants = "n/a" }
end

local function scanValuesTool()
    local out = newScanOut()
    if type(getscriptclosure) ~= "function" then return out end
    local char = LocalPlayer.Character
    local tool = char and char:FindFirstChildOfClass("Tool")
    out.tool = tool and tool.Name or "NONE"
    if not tool then return out end
    local ctx = valueCtx(tool)
    local seen, budget = {}, { count = 0, max = 1200 }
    pcall(function()
        local scr = tool:FindFirstChild("Client")
        if scr and scr:IsA("LocalScript") then
            out.scripts += 1
            local ok, closure = pcall(getscriptclosure, scr)
            if ok and type(closure) == "function" then
                local okc, consts = pcall(debug.getconstants, closure)
                out.getconstants = okc and ("ok(" .. tostring(type(consts) == "table" and #consts or 0) .. ")") or "unavailable"
                scanValueClosure(closure, seen, budget, ctx, out)
            end
        end
        local scr2 = tool:FindFirstChild("PassClient")
        if scr2 and scr2:IsA("LocalScript") then
            out.scripts += 1
            local ok, closure = pcall(getscriptclosure, scr2)
            if ok and type(closure) == "function" then
                scanValueClosure(closure, seen, budget, ctx, out)
            end
        end
    end)
    return out
end

local function scanValuesBundle()
    local out = newScanOut()
    if type(getscriptclosure) ~= "function" then return out end
    pcall(function()
        local char = LocalPlayer.Character
        local tool = char and char:FindFirstChildOfClass("Tool")
        out.tool = tool and tool.Name or "NONE"
        if not tool then return end
        local ctx = valueCtx(tool)
        local ps = LocalPlayer:FindFirstChild("PlayerScripts")
        local bundle = ps and ps:FindFirstChild("E2CJMS")
        local x = bundle and bundle:FindFirstChild("XIIX")
        if not x then return end
        local ok, closure = pcall(getscriptclosure, x)
        if ok and type(closure) == "function" then
            out.scripts = 1
            local seen, budget = {}, { count = 0, max = 3000 }
            scanValueClosure(closure, seen, budget, ctx, out)
        end
    end)
    return out
end

local function applyCandidates()
    local pct = tonumber(Config.Weapons.RecoilPct) or 100
    local n = 0
    for _, c in ipairs(recoilCandidates.numbers.list) do
        if pcall(debug.setupvalue, c.fn, c.idx, c.base * (pct / 100)) then n += 1 end
    end
    for _, c in ipairs(recoilCandidates.fields.list) do
        local want = c.base * (pct / 100)
        if pcall(function() c.tbl[c.key] = want end) and c.tbl[c.key] == want then n += 1 end
    end
    return n
end

-- Closure scan of the equipped gun's own script: the Client LocalScript
-- holds ITS config table (and any snapshotted numbers) as upvalues. This
-- finds them via getscriptclosure - the table found here is the exact one
-- the script reads, so scaling it always lands.
local function closureScanEquipped()
    local report = { scripts = 0, newTables = 0, numbers = {}, snapshots = 0, available = true, baseRecoil = nil }
    if type(getscriptclosure) ~= "function" then
        report.available = false
        return report
    end
    local char = LocalPlayer.Character
    local tool = char and char:FindFirstChildOfClass("Tool")
    if not tool then return report end
    -- base value for amount snapshots: the gun table's ORIGINAL Recoil
    pcall(function()
        local mod = tool:FindFirstChild("Config")
        if not mod then return end
        local cfg = require(mod)
        if type(cfg) == "table" and recoilGun.tables[cfg] then
            report.baseRecoil = recoilGun.tables[cfg].Recoil
        end
    end)
    local seen = {}
    local budget = 0
    local function visit(fn, idx, name, val)
        if type(val) == "table" then
            if looksLikeGunConfig(val) and not recoilGun.tables[val] then
                recoilGun.tables[val] = { Recoil = val.Recoil }
                report.newTables += 1
            end
        elseif typeof(val) == "number" then
            local key = tostring(val)
            report.numbers[key] = (report.numbers[key] or 0) + 1
        end
        if type(name) == "string" and addSnapshot(fn, idx, name, val, report.baseRecoil) then
            report.snapshots += 1
        end
    end
    local function walk(fn)
        if type(fn) ~= "function" or seen[fn] or budget > 500 then return end
        seen[fn] = true
        budget += 1
        pcall(function()
            local i = 1
            while true do
                local name, val = debug.getupvalue(fn, i)
                if not name then break end
                visit(fn, i, name, val)
                i += 1
            end
        end)
        pcall(function()
            for _, proto in ipairs(debug.getprotos(fn)) do
                walk(proto)
            end
        end)
    end
    for _, name in ipairs({ "Client", "PassClient" }) do
        local scr = tool:FindFirstChild(name)
        if scr and scr:IsA("LocalScript") then
            report.scripts += 1
            local ok, closure = pcall(getscriptclosure, scr)
            if ok and type(closure) == "function" then
                walk(closure)
            end
        end
    end
    return report
end

-- One-time fallback scan (button-triggered, NEVER automatic): finds the
-- config tables the weapon scripts actually hold AND every live spring
-- instance, scaling/wrapping both. Also runs the closure scan.
local function deepScanAll()
    local cfgs, springs = 0, 0
    if type(getgc) == "function" then
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
    end
    local closure = nil
    pcall(function() closure = closureScanEquipped() end)
    return cfgs, springs, closure
end

-- Scale the current gun + every gun equipped later (tools move from the
-- backpack into the character when equipped).
local function rescaleAndPatch()
    pcall(applyGunRecoil)
    pcall(function() closureScanEquipped() end)
    pcall(applySnapshotPatches)
    pcall(applyAnchoredPatches)
    pcall(scanValuesTool)
    pcall(applyCandidates)
end

local function watchToolsForRecoil(char)
    if not char then return end
    task.delay(0.25, rescaleAndPatch)
    char.ChildAdded:Connect(function(child)
        if not child:IsA("Tool") then return end
        task.delay(0.25, rescaleAndPatch)
        pcall(function()
            local values = child:FindFirstChild("Values")
            local eq = values and values:FindFirstChild("Equipped")
            if eq then
                eq.Changed:Connect(function()
                    if eq.Value then
                        task.delay(0.3, rescaleAndPatch)
                    end
                end)
            end
        end)
    end)
end

if LocalPlayer.Character then watchToolsForRecoil(LocalPlayer.Character) end
LocalPlayer.CharacterAdded:Connect(watchToolsForRecoil)

-- Guns snapshot their config when they ARRIVE (their Client script starts
-- then, not on equip), so scale each one the moment it shows up in the
-- backpack - before the script's first read - and again shortly after.
local function scaleOneTool(tool)
    if not tool or not tool.Parent then return end
    pcall(function()
        local mod = tool:FindFirstChild("Config")
        if mod then trackGunCfg(require(mod)) end
    end)
    pcall(applyGunRecoil)
end

local function watchBackpackForRecoil(bp)
    if not bp then return end
    bp.ChildAdded:Connect(function(child)
        if not child:IsA("Tool") then return end
        scaleOneTool(child)
        task.delay(0.05, function() scaleOneTool(child) end)
        task.delay(0.25, function() scaleOneTool(child) end)
        task.delay(0.75, function() scaleOneTool(child) end)
    end)
    for _, child in ipairs(bp:GetChildren()) do
        if child:IsA("Tool") then scaleOneTool(child) end
    end
end
if LocalPlayer.Backpack then watchBackpackForRecoil(LocalPlayer.Backpack) end
LocalPlayer.ChildAdded:Connect(function(child)
    if child.Name == "Backpack" then watchBackpackForRecoil(child) end
end)

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
        local function memberList(tbl, label)
            if type(tbl) ~= "table" then return end
            local names = {}
            for k, v in pairs(tbl) do table.insert(names, tostring(k) .. ":" .. type(v)) end
            table.sort(names)
            print(("  %s: %s"):format(label, #names > 0 and table.concat(names, ", ") or "(empty)"))
        end
        memberList(m.mt, "mt members")
        if type(m.mt) == "table" and type(m.mt.__index) == "table" then
            memberList(m.mt.__index, "mt.__index members")
        end
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
                pcall(function() closureScanEquipped() end)
                local snaps = applySnapshotPatches()
                local scan = nil
                pcall(function() scan = scanValuesTool() end)
                local anchored = applyAnchoredPatches()
                local cands = applyCandidates()
                print(("[criminality] recoil %d%% -> configs %d, CamShake %d, snapshots %d | tool %s: +%d num, +%d fld, combo %d, spd %d, dmp %d | anchored %d, candidates %d%s"):format(
                    math.floor(v + 0.5), guns, applied, snaps,
                    scan and scan.tool or "?", scan and scan.number_patches or 0, scan and scan.field_patches or 0,
                    scan and scan.combo_tables or 0, scan and scan.speed_hits or 0, scan and scan.damper_hits or 0,
                    anchored, cands,
                    blocked > 0 and (" (" .. blocked .. " locked)") or ""))
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
            local cfgs, springs, closure = deepScanAll()
            local guns = applyGunRecoil()
            local shake = applyRecoil()
            local snaps = applySnapshotPatches()
            local scanTool = nil
            pcall(function() scanTool = scanValuesTool() end)
            local scanBundle = nil
            pcall(function() scanBundle = scanValuesBundle() end)
            local anchored = applyAnchoredPatches()
            local cands = applyCandidates()
            notify(("Deep scan: tool %s: +%d num, +%d fld | service: +%d num, +%d fld - shoot to test"):format(
                scanTool and scanTool.tool or "?",
                scanTool and scanTool.number_patches or 0, scanTool and scanTool.field_patches or 0,
                scanBundle and scanBundle.number_patches or 0, scanBundle and scanBundle.field_patches or 0))
            print(("[criminality] deep scan: +%d configs, +%d springs, %d guns, snapshots %d | tool %s: +%d num, +%d fld, combo %d, spd %d, dmp %d, gc %s | service: +%d num, +%d fld, combo %d, spd %d, dmp %d | candidates %d, anchored %d (pct %d%%)"):format(
                cfgs, springs, guns, snaps,
                scanTool and scanTool.tool or "?", scanTool and scanTool.number_patches or 0,
                scanTool and scanTool.field_patches or 0, scanTool and scanTool.combo_tables or 0,
                scanTool and scanTool.speed_hits or 0, scanTool and scanTool.damper_hits or 0,
                scanTool and scanTool.getconstants or "?",
                scanBundle and scanBundle.number_patches or 0, scanBundle and scanBundle.field_patches or 0,
                scanBundle and scanBundle.combo_tables or 0, scanBundle and scanBundle.speed_hits or 0,
                scanBundle and scanBundle.damper_hits or 0,
                cands, anchored, math.floor((tonumber(Config.Weapons.RecoilPct) or 100) + 0.5)))
            if closure then
                local nums2 = {}
                for k, v in pairs(closure.numbers) do table.insert(nums2, ("%sx%d"):format(k, v)) end
                table.sort(nums2)
                local shown = {}
                for i = 1, math.min(#nums2, 10) do table.insert(shown, nums2[i]) end
                print(("[criminality] closure scan: %s, scripts %d, +%d config tables, +%d snapshots, numbers: %s"):format(
                    closure.available and "ok" or "getscriptclosure missing",
                    closure.scripts, closure.newTables, closure.snapshots, table.concat(shown, ", ")))
            end
        end)
    end)
    note(p3, "100% = the game's own recoil. The config is scaled when a gun arrives, and every copy the weapon " ..
        "scripts cached from it is patched LIVE on each slider move (found by name AND by the field names their code " ..
        "touches - Deep apply scans the whole weapon service for anything left). Last resort: drop & pick the gun.")

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
