--[[
    ============================================
    HAVOC HUB - UNIVERSAL SCRIPT
    ============================================
    The fallback that loads when the hub has no game-specific script for the
    current PlaceId. Generic tools that work across most Roblox games:

      • Camera aimbot   - FOV circle, smoothing, team / visibility checks
      • Player ESP      - boxes, names, health, distance, tracers (Drawing)
      • Movement        - walk speed, jump power, infinite jump, fly
      • Misc            - fullbright, anti-AFK, rejoin server

    Requires uilib.luau next to this file in the executor's workspace folder;
    without it every feature still runs, only the settings menu is skipped.

    Menu key: RightShift (locked). Config: universal_hub_config.json.
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
-- CONFIG  (persisted to universal_hub_config.json)
-- ============================================================
local CONFIG_FILE = "universal_hub_config.json"

local DEFAULTS = {
    ESP      = { Enabled = false, Box = true, Name = true, Health = true,
                 Distance = true, Tracers = false, TeamCheck = true, MaxDistance = 2000 },
    Aimbot   = { Enabled = false, Mode = "Hold RMB", FOV = 120, Smoothness = 4,
                 TeamCheck = true, VisibleOnly = false, FOVCircle = true },
    Movement = { WalkSpeed = 16, JumpPower = 50, InfJump = false, Fly = false, FlySpeed = 60 },
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
local UILIB_FILE = "uilib.luau"
local UILib
do
    local ok, res = pcall(function()
        local src = readfile(UILIB_FILE)
        if type(src) ~= "string" or src == "" then error("empty file") end
        local chunk, compileErr = loadstring(src, "@" .. UILIB_FILE)
        if not chunk then error("compile error: " .. tostring(compileErr)) end
        return chunk()
    end)
    if ok and type(res) == "table" then
        UILib = res
    else
        warn("[Havoc Hub] uilib.luau not loaded (" .. tostring(res) .. ") - settings menu will be skipped")
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

local toastSlots = {}

-- Small top-centre toast used for hotkey feedback and widget warnings.
-- Falls back to a print when the menu isn't available.
local function notify(text)
    text = tostring(text)
    if not (screenGui and UILib) then
        print("[Havoc Hub]", text)
        return
    end

    local slot
    for i = 1, 4 do
        if not toastSlots[i] then slot = i; break end
    end
    if not slot then
        slot = 1
        local old = toastSlots[1]
        if old then old:Destroy() end
    end

    local frame = Instance.new("Frame")
    frame.Size = UDim2.fromOffset(280, 30)
    frame.Position = UDim2.new(0.5, -140, 0, -38)  -- starts above the screen
    frame.BackgroundColor3 = UILib.THEME.HEADER
    frame.BorderSizePixel = 0
    frame.BackgroundTransparency = 1
    frame.Parent = screenGui
    UILib.corner(frame, 6)
    UILib.stroke(frame, UILib.THEME.STROKE)

    local bar = Instance.new("Frame")
    bar.Size = UDim2.new(0, 3, 1, -10)
    bar.Position = UDim2.new(0, 7, 0.5, -5)
    bar.BackgroundColor3 = UILib.THEME.ACCENT
    bar.BorderSizePixel = 0
    bar.Parent = frame
    UILib.corner(bar, 2)

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -24, 1, 0)
    lbl.Position = UDim2.new(0, 18, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = text
    lbl.TextColor3 = UILib.THEME.TEXT
    lbl.TextSize = 12
    lbl.Font = UILib.FONTS.MEDIUM
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.TextTruncate = Enum.TextTruncate.AtEnd
    lbl.Parent = frame

    toastSlots[slot] = frame
    local targetY = 8 + (slot - 1) * 36
    UILib.tween(frame, 0.2, {
        Position = UDim2.new(0.5, -140, 0, targetY),
        BackgroundTransparency = 0,
    })
    task.delay(2.6, function()
        if frame.Parent then
            UILib.tween(frame, 0.25, {
                Position = UDim2.new(0.5, -140, 0, targetY - 14),
                BackgroundTransparency = 1,
            })
            task.delay(0.3, function() if frame.Parent then frame:Destroy() end end)
        end
        if toastSlots[slot] == frame then toastSlots[slot] = nil end
    end)
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
-- FEATURES: MOVEMENT
-- ============================================================
local function getHumanoid()
    local char = LocalPlayer.Character
    return char and char:FindFirstChildOfClass("Humanoid") or nil
end

local function applyWalkSpeed()
    local hum = getHumanoid()
    if hum then pcall(function() hum.WalkSpeed = Config.Movement.WalkSpeed end) end
end

local function applyJumpPower()
    local hum = getHumanoid()
    if hum then
        pcall(function()
            hum.UseJumpPower = true
            hum.JumpPower = Config.Movement.JumpPower
        end)
    end
end

local function applyMovementConfig()
    applyWalkSpeed()
    applyJumpPower()
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
-- FEATURES: PLAYER ESP (Drawing)
-- ============================================================
local espCache = {}
local drawingBroken = false

local ESP_COLOR_ENEMY = Color3.fromRGB(255, 80, 80)
local ESP_COLOR_ALLY  = Color3.fromRGB(82, 202, 128)

local function colorForPlayer(player)
    if player.Team and LocalPlayer.Team and player.Team ~= LocalPlayer.Team then
        return player.Team.TeamColor.Color
    end
    if player.Team and player.Team == LocalPlayer.Team then
        return ESP_COLOR_ALLY
    end
    return ESP_COLOR_ENEMY
end

local function hideEsp(e)
    if e.box then e.box.Visible = false end
    if e.name then e.name.Visible = false end
    if e.dist then e.dist.Visible = false end
    if e.tracer then e.tracer.Visible = false end
end

local function destroyEsp(e)
    for _, obj in pairs(e) do
        if obj and obj.Remove then pcall(function() obj:Remove() end) end
    end
end

local function makeEspEntry()
    local e = {}
    -- "Square" is the rectangle primitive of Potassium's Drawing library -
    -- there is no "Rectangle" type, and asking for one errors and disables
    -- every Drawing feature in this script.
    e.box = Drawing.new("Square")
    e.box.Thickness = 1
    e.box.Filled = false
    e.name = Drawing.new("Text")
    e.name.Size = 13
    e.name.Center = true
    e.name.Outline = true
    e.name.OutlineColor = Color3.new(0, 0, 0)
    e.dist = Drawing.new("Text")
    e.dist.Size = 12
    e.dist.Center = true
    e.dist.Outline = true
    e.dist.OutlineColor = Color3.new(0, 0, 0)
    e.tracer = Drawing.new("Line")
    e.tracer.Thickness = 1
    e.tracer.Transparency = 0.35
    return e
end

local function renderESP(cam)
    if drawingBroken then return end
    if not Drawing then drawingBroken = true; return end
    if not Config.ESP.Enabled then
        for _, e in pairs(espCache) do hideEsp(e) end
        return
    end

    local viewport = cam.ViewportSize
    local camPos = cam.CFrame.Position
    local used = {}
    local cfg = Config.ESP

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            local char = player.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            local hrp = char and (char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart)
            local head = char and char:FindFirstChild("Head")

            local show = false
            local topP, botP
            local dist = 0
            if hum and hum.Health > 0 and hrp then
                local teamBlocked = cfg.TeamCheck and player.Team and LocalPlayer.Team
                    and player.Team == LocalPlayer.Team
                dist = (hrp.Position - camPos).Magnitude
                if not teamBlocked and dist <= cfg.MaxDistance then
                    local headPos = head and head.Position or (hrp.Position + Vector3.new(0, 1.5, 0))
                    local topWorld = headPos + Vector3.new(0, 0.6, 0)
                    local botWorld = hrp.Position - Vector3.new(0, 3.2, 0)
                    local tp, onTop = cam:WorldToViewportPoint(topWorld)
                    local bp, onBot = cam:WorldToViewportPoint(botWorld)
                    if tp.Z > 0 and bp.Z > 0 and (onTop or onBot) then
                        topP, botP = tp, bp
                        show = true
                    end
                end
            end

            local e = espCache[player]
            if show then
                if not e then
                    local ok, made = pcall(makeEspEntry)
                    if not ok then
                        drawingBroken = true
                        warn("[Havoc Hub] ESP drawing failed: " .. tostring(made))
                        return
                    end
                    e = made
                    espCache[player] = e
                end

                used[player] = true
                local color = colorForPlayer(player)

                local topY = math.min(topP.Y, botP.Y)
                local botY = math.max(topP.Y, botP.Y)
                local height = math.max(botY - topY, 8)
                local width = math.max(height * 0.55, 6)
                local cx = (topP.X + botP.X) / 2

                if cfg.Box then
                    e.box.Visible = true
                    e.box.Color = color
                    e.box.Position = Vector2.new(cx - width / 2, topY)
                    e.box.Size = Vector2.new(width, height)
                else
                    e.box.Visible = false
                end

                if cfg.Name then
                    local text = player.Name
                    if cfg.Health then
                        text = text .. " [" .. tostring(math.floor(hum.Health + 0.5)) .. "]"
                    end
                    e.name.Visible = true
                    e.name.Color = Color3.fromRGB(235, 235, 245)
                    e.name.Position = Vector2.new(cx, topY - 16)
                    e.name.Text = text
                else
                    e.name.Visible = false
                end

                if cfg.Distance then
                    e.dist.Visible = true
                    e.dist.Color = Color3.fromRGB(180, 180, 195)
                    e.dist.Position = Vector2.new(cx, botY + 3)
                    e.dist.Text = tostring(math.floor(dist + 0.5)) .. "m"
                else
                    e.dist.Visible = false
                end

                if cfg.Tracers then
                    e.tracer.Visible = true
                    e.tracer.Color = color
                    e.tracer.From = Vector2.new(viewport.X / 2, viewport.Y)
                    e.tracer.To = Vector2.new(cx, botY)
                else
                    e.tracer.Visible = false
                end
            elseif e then
                hideEsp(e)
                if not player.Parent then
                    espCache[player] = nil
                    destroyEsp(e)
                end
            end
        end
    end

    -- Anything not drawn this frame (out of range, dead, team) is hidden.
    for player, e in pairs(espCache) do
        if not used[player] then
            hideEsp(e)
            if not player.Parent then
                espCache[player] = nil
                destroyEsp(e)
            end
        end
    end
end

-- ============================================================
-- FEATURES: AIMBOT (camera lock)
-- ============================================================
local fovCircle = nil

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
                local teamBlocked = cfg.TeamCheck and player.Team and LocalPlayer.Team
                    and player.Team == LocalPlayer.Team
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
    if not show or drawingBroken then
        if fovCircle then fovCircle.Visible = false end
        return
    end
    if not Drawing then drawingBroken = true; return end
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
            drawingBroken = true
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
-- FEATURES: FLY
-- ============================================================
local function updateFly(cam)
    if not Config.Movement.Fly then return end
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end

    local dir = Vector3.zero
    if UserInputService:IsKeyDown(Enum.KeyCode.W) then dir += cam.CFrame.LookVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.S) then dir -= cam.CFrame.LookVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.A) then dir -= cam.CFrame.RightVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.D) then dir += cam.CFrame.RightVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.Space) then dir += Vector3.new(0, 1, 0) end
    if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then dir -= Vector3.new(0, 1, 0) end

    if dir.Magnitude > 0 then dir = dir.Unit end
    pcall(function()
        hrp.Velocity = dir * Config.Movement.FlySpeed
    end)
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

    if Config.Movement.InfJump and input.KeyCode == Enum.KeyCode.Space then
        local char = LocalPlayer.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if hrp then
            pcall(function()
                hrp.Velocity = Vector3.new(hrp.Velocity.X, 50, hrp.Velocity.Z)
            end)
        end
    end

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
    local create, corner, stroke = UILib.create, UILib.corner, UILib.stroke
    local THEME, FONTS = UILib.THEME, UILib.FONTS

    local main = create("Frame", {
        Name = "Main",
        Size = UDim2.new(0, 540, 0, 360),
        Position = UDim2.new(0, 30, 0, 40),
        BackgroundColor3 = THEME.BG,
        BorderSizePixel = 0,
        Active = true,
        Draggable = true,
        Parent = screenGui,
    })
    corner(main, 10); stroke(main, THEME.STROKE)

    -- Header: title bar + accent rule, matching the Havoc window style.
    local header = create("Frame", {
        Size = UDim2.new(1, 0, 0, 36),
        BackgroundColor3 = THEME.HEADER,
        BorderSizePixel = 0,
        Parent = main,
    })
    corner(header, 10)
    create("Frame", {
        Size = UDim2.new(1, 0, 0, 10),
        Position = UDim2.new(0, 0, 1, -10),
        BackgroundColor3 = THEME.HEADER,
        BorderSizePixel = 0,
        Parent = header,
    })
    create("Frame", {
        Size = UDim2.new(1, 0, 0, 2),
        Position = UDim2.new(0, 0, 0, 36),
        BackgroundColor3 = THEME.ACCENT,
        BorderSizePixel = 0,
        ZIndex = 2,
        Parent = main,
    })
    local dot = create("Frame", {
        Size = UDim2.fromOffset(8, 8),
        Position = UDim2.new(0, 14, 0.5, -4),
        BackgroundColor3 = THEME.ACCENT,
        BorderSizePixel = 0,
        Parent = header,
    })
    corner(dot, 4)
    create("TextLabel", {
        Size = UDim2.new(1, -320, 1, 0),
        Position = UDim2.fromOffset(30, 0),
        BackgroundTransparency = 1,
        Text = "HAVOC HUB  ·  UNIVERSAL",
        TextColor3 = THEME.TEXT,
        TextSize = 13,
        Font = FONTS.BOLD,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = header,
    })
    create("TextLabel", {
        Size = UDim2.fromOffset(150, 12),
        Position = UDim2.new(1, -200, 0.5, -6),
        BackgroundTransparency = 1,
        Text = "PlaceId " .. tostring(game.PlaceId),
        TextColor3 = THEME.TEXT_DIM,
        TextSize = 10,
        Font = FONTS.MEDIUM,
        TextXAlignment = Enum.TextXAlignment.Right,
        Parent = header,
    })

    local closeBtn = create("TextButton", {
        Size = UDim2.fromOffset(24, 24),
        Position = UDim2.new(1, -36, 0.5, -12),
        BackgroundColor3 = THEME.RED,
        BorderSizePixel = 0,
        Text = "",
        AutoButtonColor = false,
        Parent = header,
    })
    corner(closeBtn, 6)
    for i = 1, 2 do
        local arm = create("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.new(0.5, 0, 0.5, 0),
            Size = UDim2.new(0, 12, 0, 2),
            BackgroundColor3 = Color3.fromRGB(255, 255, 255),
            BorderSizePixel = 0,
            Rotation = (i == 1) and 45 or -45,
            Parent = closeBtn,
        })
        corner(arm, 1)
    end
    closeBtn.MouseEnter:Connect(function() UILib.tween(closeBtn, 0.1, { BackgroundColor3 = THEME.RED_HI }) end)
    closeBtn.MouseLeave:Connect(function() UILib.tween(closeBtn, 0.1, { BackgroundColor3 = THEME.RED }) end)
    closeBtn.MouseButton1Click:Connect(function()
        screenGui.Enabled = false
        notify("Menu hidden - press RightShift to reopen")
    end)

    -- Tab rail + one scrolling page per tab.
    local tabDefs = { "Aimbot", "ESP", "Movement", "Misc" }
    local tabRail = create("Frame", {
        Size = UDim2.new(1, -24, 0, 30),
        Position = UDim2.new(0, 12, 0, 46),
        BackgroundColor3 = THEME.RAIL,
        BorderSizePixel = 0,
        Parent = main,
    })
    corner(tabRail, 8); stroke(tabRail, THEME.STROKE)
    local railLayout = create("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        Padding = UDim.new(0, 4),
        VerticalAlignment = Enum.VerticalAlignment.Center,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent = tabRail,
    })
    create("UIPadding", {
        PaddingLeft = UDim.new(0, 4),
        Parent = tabRail,
    })

    local pages, tabButtons = {}, {}
    for i, name in ipairs(tabDefs) do
        local page = create("ScrollingFrame", {
            Size = UDim2.new(1, -24, 1, -96),
            Position = UDim2.new(0, 12, 0, 92),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            ScrollBarThickness = 5,
            ScrollBarImageColor3 = THEME.STROKE,
            ScrollBarImageTransparency = 0.2,
            CanvasSize = UDim2.new(0, 0, 0, 0),
            AutomaticCanvasSize = Enum.AutomaticSize.Y,
            Visible = false,
            Parent = main,
        })
        create("UIListLayout", {
            Padding = UDim.new(0, 6),
            SortOrder = Enum.SortOrder.LayoutOrder,
            Parent = page,
        })
        create("UIPadding", {
            PaddingBottom = UDim.new(0, 10),
            Parent = page,
        })
        pages[i] = page

        local btn = create("TextButton", {
            Size = UDim2.fromOffset(112, 22),
            LayoutOrder = i,
            BackgroundColor3 = THEME.PANEL,
            BorderSizePixel = 0,
            AutoButtonColor = false,
            Text = name,
            TextColor3 = THEME.TEXT,
            TextSize = 12,
            Font = FONTS.MEDIUM,
            Parent = tabRail,
        })
        corner(btn, 6)
        tabButtons[i] = btn
    end

    local activeTab = 0
    local function setTab(idx)
        activeTab = idx
        for i, page in ipairs(pages) do page.Visible = (i == idx) end
        for i, btn in ipairs(tabButtons) do
            btn.BackgroundColor3 = (i == idx) and THEME.ACCENT or THEME.PANEL
        end
    end
    for i, btn in ipairs(tabButtons) do
        btn.MouseEnter:Connect(function()
            if activeTab ~= i then UILib.tween(btn, 0.1, { BackgroundColor3 = THEME.PANEL_HI }) end
        end)
        btn.MouseLeave:Connect(function()
            if activeTab ~= i then UILib.tween(btn, 0.1, { BackgroundColor3 = THEME.PANEL }) end
        end)
        btn.MouseButton1Click:Connect(function() setTab(i) end)
    end

    -- Page helpers: everything registered so refreshGUI() can sync it.
    local function section(page, text) addControl(UILib.makeSectionHeader(page, text)) end
    local function toggle(page, text, getter, setter, hkEntry)
        addControl(UILib.makeToggle(page, text, getter, setter, hkEntry))
    end
    local function slider(page, text, getter, setter, step, min, max)
        addControl(UILib.makeSlider(page, text, getter, setter, step, min, max))
    end
    local function bindrow(page, entry, opts) addControl(UILib.makeKeybindRow(page, entry, opts)) end
    local function dropdown(page, label, getItems, getSelected, onSelect)
        addControl(UILib.makeDropdown(page, label, getItems, getSelected, onSelect, main))
    end
    local function button(page, text, onClick, opts) addControl(UILib.makeButton(page, text, onClick, opts)) end
    local function note(page, text) UILib.makeNote(page, text, "auto") end

    -- ---------------- Aimbot ----------------
    local p1 = pages[1]
    section(p1, "Aimbot")
    toggle(p1, "Aimbot Enabled",
        function() return Config.Aimbot.Enabled end,
        function(v) Config.Aimbot.Enabled = v end,
        hotkeyById.ToggleAimbot)
    dropdown(p1, "Activation",
        function() return { "Hold RMB", "Always" } end,
        function() return Config.Aimbot.Mode end,
        function(v) Config.Aimbot.Mode = v end)
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
    note(p1, "Camera aim: locks onto the closest player inside the FOV circle. " ..
        "Hold RMB (or use Always), and raise Smoothness for a softer lock.")

    -- ---------------- ESP ----------------
    local p2 = pages[2]
    section(p2, "Player ESP")
    toggle(p2, "Player ESP",
        function() return Config.ESP.Enabled end,
        function(v) Config.ESP.Enabled = v end,
        hotkeyById.ToggleESP)
    toggle(p2, "Boxes",
        function() return Config.ESP.Box end,
        function(v) Config.ESP.Box = v end)
    toggle(p2, "Names",
        function() return Config.ESP.Name end,
        function(v) Config.ESP.Name = v end)
    toggle(p2, "Health",
        function() return Config.ESP.Health end,
        function(v) Config.ESP.Health = v end)
    toggle(p2, "Distance",
        function() return Config.ESP.Distance end,
        function(v) Config.ESP.Distance = v end)
    toggle(p2, "Tracers",
        function() return Config.ESP.Tracers end,
        function(v) Config.ESP.Tracers = v end)
    toggle(p2, "Team Check",
        function() return Config.ESP.TeamCheck end,
        function(v) Config.ESP.TeamCheck = v end)
    slider(p2, "Max Distance",
        function() return Config.ESP.MaxDistance end,
        function(v) Config.ESP.MaxDistance = v end, 100, 100, 10000)
    bindrow(p2, hotkeyById.ToggleESP)
    note(p2, "Box ESP for every player, drawn over the game with team-aware " ..
        "colours. No game-specific code - works anywhere the character has a head and torso.")

    -- ---------------- Movement ----------------
    local p3 = pages[3]
    section(p3, "Movement")
    slider(p3, "Walk Speed",
        function() return Config.Movement.WalkSpeed end,
        function(v) Config.Movement.WalkSpeed = v; applyWalkSpeed() end, 1, 0, 300)
    slider(p3, "Jump Power",
        function() return Config.Movement.JumpPower end,
        function(v) Config.Movement.JumpPower = v; applyJumpPower() end, 5, 0, 500)
    toggle(p3, "Infinite Jump",
        function() return Config.Movement.InfJump end,
        function(v) Config.Movement.InfJump = v end)
    section(p3, "Flight")
    toggle(p3, "Fly",
        function() return Config.Movement.Fly end,
        function(v) Config.Movement.Fly = v end)
    slider(p3, "Fly Speed",
        function() return Config.Movement.FlySpeed end,
        function(v) Config.Movement.FlySpeed = v end, 5, 10, 400)
    note(p3, "Fly: WASD to move, Space to rise, Left Ctrl to descend.")

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
    note(p4, ("Havoc Hub - universal fallback script. PlaceId %d has no " ..
        "game-specific script yet."):format(game.PlaceId))

    setTab(1)
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
    pcall(updateAimbot, cam, mouse)
    pcall(updateFovCircle, mouse)
    pcall(updateFly, cam)
end))

track(LocalPlayer.CharacterAdded:Connect(function(char)
    task.spawn(function()
        local hum = char:WaitForChild("Humanoid", 10)
        if hum then
            applyMovementConfig()
        end
    end)
end))

-- Apply the saved state once on load.
task.spawn(applyMovementConfig)
if Config.Misc.Fullbright then pcall(setFullbright, true) end

print(("[Havoc Hub] Universal script loaded (PlaceId %d)"):format(game.PlaceId))
notify("Universal loaded - no game-specific script for this PlaceId")
