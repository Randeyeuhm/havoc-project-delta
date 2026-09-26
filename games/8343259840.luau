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
local SCRIPT_VERSION = "crim-v2"

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
-- Criminality applies weapon recoil as CAMERA SHAKE: every shot computes
--   CamShakeConfig.Recoil * shotPower * stateMult
-- and kicks a spring; the render loop then post-multiplies the spring's
-- angles onto the camera. Scaling CamShakeConfig.Recoil scales the whole
-- kick linearly - i.e. a real recoil percentage. The module lives at
-- ReplicatedStorage.Storage.FrameworkStuff.CamShakeConfig (the service is
-- renamed, so GetService is used).
--
-- require() may hand back a separate copy inside an executor, so the LIVE
-- table the weapon code reads is found by scanning GC for closures whose
-- upvalues hold a table with this exact shape - and every copy found is
-- scaled, so whichever one the game reads is covered.
local recoilState = { tables = {} }

local function looksLikeCamShake(t)
    return type(t) == "table"
        and type(t.Recoil) == "number" and type(t.RecoilSpeed) == "number"
        and type(t.RecoilDamper) == "number" and type(t.AngleX_Min) == "number"
        and type(t.AngleX_Max) == "number" and type(t.Accuracy) == "number"
end

local function findCamShakeTables()
    local out = {}
    local function consider(t)
        if looksLikeCamShake(t) and not recoilState.tables[t] then
            table.insert(out, t)
        end
    end
    pcall(function()
        local storage = ReplicatedStorage:FindFirstChild("Storage")
        local fw = storage and storage:FindFirstChild("FrameworkStuff")
        local mod = fw and fw:FindFirstChild("CamShakeConfig")
        if mod then consider(require(mod)) end
    end)
    if type(getgc) == "function" then
        pcall(function()
            for _, obj in pairs(getgc(true)) do
                if type(obj) == "function" then
                    pcall(function()
                        local i = 1
                        while true do
                            local name, val = debug.getupvalue(obj, i)
                            if not name then break end
                            consider(val)
                            i += 1
                        end
                    end)
                elseif type(obj) == "table" then
                    consider(obj)
                end
            end
        end)
    end
    return out
end

local function applyRecoil()
    local pct = tonumber(Config.Weapons.RecoilPct) or 100
    for _, t in ipairs(findCamShakeTables()) do
        recoilState.tables[t] = { orig = t.Recoil }
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

-- keep looking until the config is found (it may load with the first gun)
task.spawn(function()
    while true do
        task.wait(8)
        if (tonumber(Config.Weapons.RecoilPct) or 100) ~= 100 then
            local tracked = 0
            for _ in pairs(recoilState.tables) do tracked += 1 end
            if tracked == 0 then pcall(applyRecoil) end
        end
    end
end)

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
                print(("[criminality] recoil %d%% -> scaled %d config copy(ies)%s"):format(
                    math.floor(v + 0.5), applied, blocked > 0 and (" (" .. blocked .. " locked)") or ""))
            end)
        end, 5, 0, 200)
    button(p3, "Re-detect recoil config", function()
        task.spawn(function()
            local applied, blocked = applyRecoil()
            local tracked = 0
            for _ in pairs(recoilState.tables) do tracked += 1 end
            local pct = math.floor((tonumber(Config.Weapons.RecoilPct) or 100) + 0.5)
            notify(("Recoil: %d config copy(ies) tracked, %d scaled%s - set to %d%%"):format(
                tracked, applied, blocked > 0 and (", " .. blocked .. " locked") or "", pct))
            print(("[criminality] recoil scan: tracked %d, scaled %d, blocked %d, pct %d"):format(
                tracked, applied, blocked, pct))
        end)
    end)
    note(p3, "100% = the game's own recoil. The slider scales the camera-shake value every shot reads " ..
        "(CamShakeConfig.Recoil), so it applies live per shot - 0% = no kick, 200% = double. " ..
        "If a gun ever feels unchanged, hit Re-detect.")

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
    local pct = tonumber(Config.Weapons.RecoilPct) or 100
    if pct ~= 100 then
        print(("[criminality] recoil %d%% active - %d config copy(ies) scaled"):format(
            math.floor(pct + 0.5), applied))
    end
end)

print(("[Havoc Hub] Criminality script loaded (PlaceId %d)"):format(game.PlaceId))
notify("Criminality loaded - aimbot + ESP. Keep smoothing high near moderators")
