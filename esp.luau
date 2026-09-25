--[[
    ============================================
    HAVOC HUB - SHARED ESP ENGINE  (esp.luau)
    ============================================

    The hub-wide entity ESP, ported from Project Delta's ESP class and
    generalized so every game script can share it:

        local esp = ESP.new(function() return Config.ESP end)
        esp:Ensure(model)     -- start tracking a model (idempotent)
        esp:Prune(seenSet)    -- drop everything not in the set
        esp:Render(camera)    -- draw one frame

    What it draws (Project Delta's look):
      - corner box: 8 Line segments, fixed corner length capped at 30% of
        the box's short side
      - name / health / distance labels (outlined Text)
      - head + body Highlight chams (hollow = outline only)

    Health works for player rigs (Humanoid) AND vehicle-style NPCs that
    keep health as an attribute on the model / PrimaryPart / Chassis.

    Transparency rules: every "*Transparency" field is OPACITY
    (1 = fully visible). This executor's Drawing alpha is INVERTED
    (1 = visible), so opacity passes through as-is (drawT); Highlight
    instances are standard engine objects and get the usual 1 - opacity
    conversion (guiT).

    ESP.fill(cfg)     injects defaults + strips keys from the old espui
                      schema so saved configs start clean
    ESP.sanitize(cfg) clamps numbers and repairs enum values
]]

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local ESP = {}
ESP.VERSION = "esp-v1-pd-core"

-- ============================================================
-- SCHEMA
-- ============================================================
-- "*Transparency" = OPACITY (1 = fully visible). The converters below map
-- to the two rendering systems (see the header note).
local DEFAULTS = {
    -- master + filters
    Enabled = false,
    TeamCheck = false,
    VisibleOnly = false,   -- consumed by the host render loops
    MaxDistance = 2000,

    -- corner box
    Box = true,
    BoxCornerLength = 6,   -- px, capped at 30% of the box's short side
    BoxThickness = 2,
    BoxTransparency = 1,   -- opacity
    BoxR = 255, BoxG = 80, BoxB = 80,

    -- name
    Name = true,
    NameSource = "Username",   -- Username | DisplayName
    NameSize = 13,
    NameTransparency = 1,
    NameR = 255, NameG = 255, NameB = 255,

    -- health (number above the box, colour scales with HP)
    Health = true,
    HealthSize = 11,
    HealthTransparency = 1,

    -- distance (metres, below the box)
    Distance = true,
    DistanceSize = 12,
    DistanceTransparency = 1,
    DistanceR = 200, DistanceG = 200, DistanceB = 200,

    -- highlight chams
    HeadHighlight = false,
    HeadHighlightHollow = false,
    HeadHighlightTransparency = 0.7,
    HeadHighlightR = 255, HeadHighlightG = 80, HeadHighlightB = 80,

    BodyHighlight = false,
    BodyHighlightHollow = false,
    BodyHighlightTransparency = 0.7,
    BodyHighlightR = 255, BodyHighlightG = 80, BodyHighlightB = 80,
}
ESP.DEFAULTS = DEFAULTS

local CHOICES = {
    NameSource = { ["Username"] = true, ["DisplayName"] = true },
}

-- Old espui schema fields. The customizer no longer reads them, so they
-- are stripped on fill instead of lingering in saved configs forever.
local LEGACY_KEYS = {
    "UpdateRate", "RainbowSpeed",
    "BoxStyle", "BoxOutline", "BoxFill", "BoxFillTransparency",
    "BoxColorMode",
    "NameAnchor", "NameOffsetX", "NameOffsetY", "NameOutline",
    "NameColorMode",
    "HealthStyle", "HealthBarAnchor", "HealthBarWidth", "HealthBarHeight",
    "HealthBarOutline", "HealthBarTransparency", "HealthColorMode",
    "HealthR", "HealthG", "HealthB",
    "HealthTextAnchor", "HealthTextOffsetX", "HealthTextOffsetY",
    "HealthTextSize", "HealthTextFormat", "HealthTextOutline",
    "HealthTextColorMode", "HealthTextR", "HealthTextG", "HealthTextB",
    "DistanceAnchor", "DistanceOffsetX", "DistanceOffsetY", "DistanceUnit",
    "DistanceDecimals", "DistanceOutline", "DistanceColorMode",
    "Tracers", "TracerOrigin", "TracerOffsetX", "TracerOffsetY",
    "TracerThickness", "TracerTransparency", "TracerColorMode",
    "TracerR", "TracerG", "TracerB",
    "HeadDot", "HeadDotSize", "HeadDotColorMode",
    "HeadDotR", "HeadDotG", "HeadDotB",
    "Skeleton", "SkeletonThickness", "SkeletonTransparency",
    "SkeletonColorMode", "SkeletonR", "SkeletonG", "SkeletonB",
    "LookLine", "LookLineLength", "LookLineThickness", "LookLineTransparency",
    "LookLineColorMode", "LookLineR", "LookLineG", "LookLineB",
    "Arrow", "ArrowSize", "ArrowRadius", "ArrowThickness", "ArrowTransparency",
    "ArrowColorMode", "ArrowR", "ArrowG", "ArrowB",
    "Chams", "ChamsAlwaysOnTop", "ChamsFillTransparency",
    "ChamsOutlineTransparency", "ChamsFillR", "ChamsFillG", "ChamsFillB",
    "ChamsOutlineR", "ChamsOutlineG", "ChamsOutlineB",
}

function ESP.fill(cfg)
    if type(cfg) ~= "table" then return cfg end
    for k, v in pairs(DEFAULTS) do
        if cfg[k] == nil then cfg[k] = v end
    end
    for i = 1, #LEGACY_KEYS do
        cfg[LEGACY_KEYS[i]] = nil
    end
    return cfg
end

function ESP.sanitize(cfg)
    if type(cfg) ~= "table" then return cfg end
    local function num(v, a, b, fallback)
        v = tonumber(v)
        if not v then return fallback end
        return math.clamp(v, a, b)
    end
    cfg.MaxDistance = num(cfg.MaxDistance, 100, 10000, 2000)
    cfg.BoxCornerLength = num(cfg.BoxCornerLength, 0, 40, 6)
    cfg.BoxThickness = num(cfg.BoxThickness, 1, 6, 2)
    cfg.NameSize = num(cfg.NameSize, 8, 24, 13)
    cfg.HealthSize = num(cfg.HealthSize, 8, 24, 11)
    cfg.DistanceSize = num(cfg.DistanceSize, 8, 24, 12)
    cfg.BoxTransparency = num(cfg.BoxTransparency, 0, 1, 1)
    cfg.NameTransparency = num(cfg.NameTransparency, 0, 1, 1)
    cfg.HealthTransparency = num(cfg.HealthTransparency, 0, 1, 1)
    cfg.DistanceTransparency = num(cfg.DistanceTransparency, 0, 1, 1)
    cfg.HeadHighlightTransparency = num(cfg.HeadHighlightTransparency, 0, 1, 0.7)
    cfg.BodyHighlightTransparency = num(cfg.BodyHighlightTransparency, 0, 1, 0.7)
    if CHOICES.NameSource[cfg.NameSource] ~= true then cfg.NameSource = "Username" end
    return cfg
end

-- ============================================================
-- HELPERS
-- ============================================================
local HC_GREEN = Color3.fromRGB(82, 202, 128)
local HC_YELLOW = Color3.fromRGB(230, 210, 60)
local HC_ORANGE = Color3.fromRGB(240, 150, 50)
local HC_RED = Color3.fromRGB(235, 70, 70)

function ESP.healthColor(frac)
    frac = tonumber(frac) or 1
    if frac > 0.75 then return HC_GREEN
    elseif frac > 0.5 then return HC_YELLOW
    elseif frac > 0.25 then return HC_ORANGE
    else return HC_RED end
end

local function rgb(r, g, b)
    return Color3.fromRGB(
        math.clamp(tonumber(r) or 255, 0, 255),
        math.clamp(tonumber(g) or 255, 0, 255),
        math.clamp(tonumber(b) or 255, 0, 255))
end

-- Drawing alpha on this executor is inverted (1 = visible) - opacity is
-- passed through untouched.
local function drawT(opacity)
    return math.clamp(tonumber(opacity) or 1, 0, 1)
end
-- Highlight instances use standard engine transparency.
local function guiT(opacity)
    return 1 - math.clamp(tonumber(opacity) or 1, 0, 1)
end

-- Root part for any entity: player rigs have HumanoidRootPart/Torso, the
-- vehicle NPCs (heli/tank/car) have a PrimaryPart (Chassis) or loose parts.
local function npcRoot(inst)
    local r = inst:FindFirstChild("HumanoidRootPart")
        or inst:FindFirstChild("Torso")
        or inst.PrimaryPart
        or inst:FindFirstChild("Chassis")
    if r then return r end
    for _, d in ipairs(inst:GetChildren()) do
        if d:IsA("BasePart") then return d end
    end
    return nil
end
ESP.npcRoot = npcRoot

local function entityName(model, nameSource)
    local p = Players:GetPlayerFromCharacter(model)
    if p then
        if nameSource == "DisplayName" then return p.DisplayName end
        return p.Name
    end
    return "NPC: " .. model.Name
end
ESP.entityName = entityName

-- Humanoid first; vehicle NPCs keep health as an attribute on the model,
-- the primary part (Chassis on the MI24V) or a collision part.
local function entityHealth(model)
    local h = model:FindFirstChildOfClass("Humanoid")
    if h then return h.Health, h.MaxHealth end
    local hp = model:GetAttribute("Health")
    if typeof(hp) == "number" then
        return hp, model:GetAttribute("MaxHealth") or hp
    end
    local pp = model.PrimaryPart
    if pp then
        local h2 = pp:GetAttribute("Health")
        if typeof(h2) == "number" then
            return h2, pp:GetAttribute("MaxHealth") or h2
        end
    end
    local ch = model:FindFirstChild("Chassis")
    if ch and ch:IsA("BasePart") then
        local h3 = ch:GetAttribute("Health")
        if typeof(h3) == "number" then
            return h3, ch:GetAttribute("MaxHealth") or h3
        end
    end
    for _, d in ipairs(model:GetChildren()) do
        if d:IsA("BasePart") then
            local h4 = d:GetAttribute("Health")
            if typeof(h4) == "number" then return h4, h4 end
        end
    end
    return 0, 0
end
ESP.entityHealth = entityHealth

-- ============================================================
-- DRAW OBJECTS
-- ============================================================
local LABEL_KEYS = {
    "TL_V", "TL_H", "TR_V", "TR_H", "BL_V", "BL_H", "BR_V", "BR_H",
    "NameLabel", "DistanceLabel", "HealthLabel",
}

local function newLine()
    local ok, l = pcall(Drawing.new, "Line")
    if not ok or not l then return nil end
    l.Visible, l.Thickness, l.Transparency, l.ZIndex = false, 2, 1, 2
    return l
end

local function newText()
    local ok, t = pcall(Drawing.new, "Text")
    if not ok or not t then return nil end
    t.Visible, t.Font, t.Size = false, Drawing.Fonts.UI, 16
    t.Outline, t.OutlineColor, t.Center = true, Color3.fromRGB(0, 0, 0), false
    return t
end

local function hideData(d)
    for i = 1, #LABEL_KEYS do
        local o = d[LABEL_KEYS[i]]
        if o then o.Visible = false end
    end
    if d.HeadHighlight then d.HeadHighlight.Enabled = false end
    if d.BodyHighlight then d.BodyHighlight.Enabled = false end
end

local function destroyData(d)
    for i = 1, #LABEL_KEYS do
        local o = d[LABEL_KEYS[i]]
        if o then pcall(function() o:Remove() end) end
    end
    if d.HeadHighlight then pcall(function() d.HeadHighlight:Destroy() end) end
    if d.BodyHighlight then pcall(function() d.BodyHighlight:Destroy() end) end
end

-- Scratch table for the corner segments (single-threaded render, reused
-- every frame like Project Delta does).
local LINE_TEMPLATE = {
    { "TL_V", 0, 0, 0, 0 }, { "TL_H", 0, 0, 0, 0 },
    { "TR_V", 0, 0, 0, 0 }, { "TR_H", 0, 0, 0, 0 },
    { "BL_V", 0, 0, 0, 0 }, { "BL_H", 0, 0, 0, 0 },
    { "BR_V", 0, 0, 0, 0 }, { "BR_H", 0, 0, 0, 0 },
}

-- ============================================================
-- PER-TARGET RENDER (one frame)
-- ============================================================
local function renderOne(cfg, model, d, cam, maxDist, viewportH, fovTan, localRoot)
    if not model or not model.Parent then return false end
    if model == LocalPlayer.Character then hideData(d); return true end

    if cfg.TeamCheck then
        local p = Players:GetPlayerFromCharacter(model)
        if p and p.Team and LocalPlayer.Team and p.Team == LocalPlayer.Team then
            hideData(d)
            return true
        end
    end

    local root = npcRoot(model)
    if not root then hideData(d); return true end
    local head = model:FindFirstChild("Head") or root

    local rootPos, visible = cam:WorldToViewportPoint(root.Position)
    if not visible or rootPos.Z <= 0 then hideData(d); return true end

    local distance = math.huge
    if localRoot then distance = (localRoot.Position - root.Position).Magnitude end
    if distance > maxDist then hideData(d); return true end

    -- Projection: Project Delta's fixed world-size box (4.5 x 6.5 studs)
    -- through the camera's real vertical FOV and viewport height.
    local pxPerStud = viewportH / (2 * rootPos.Z * fovTan)
    local width  = 4.5 * pxPerStud
    local height = 6.5 * pxPerStud
    local screenX, screenY = math.floor(rootPos.X), math.floor(rootPos.Y)
    local boxX = math.floor(screenX - width * 0.5)
    local boxY = math.floor(screenY - height * 0.5 + 0.5 * pxPerStud)
    local hRight  = boxX + width
    local hBottom = boxY + height

    -- Corner box (Project Delta's exact 8-segment template).
    if cfg.Box then
        local cornerLen = math.min(tonumber(cfg.BoxCornerLength) or 6, math.min(width, height) * 0.3)
        local th = tonumber(cfg.BoxThickness) or 2
        local color = rgb(cfg.BoxR, cfg.BoxG, cfg.BoxB)
        local transp = drawT(cfg.BoxTransparency)
        local L = LINE_TEMPLATE
        L[1][2], L[1][3], L[1][4], L[1][5] = boxX, boxY + cornerLen, boxX, boxY
        L[2][2], L[2][3], L[2][4], L[2][5] = boxX, boxY, boxX + cornerLen, boxY
        L[3][2], L[3][3], L[3][4], L[3][5] = hRight, boxY + cornerLen, hRight, boxY
        L[4][2], L[4][3], L[4][4], L[4][5] = hRight - cornerLen, boxY, hRight, boxY
        L[5][2], L[5][3], L[5][4], L[5][5] = boxX, hBottom, boxX, hBottom - cornerLen
        L[6][2], L[6][3], L[6][4], L[6][5] = boxX, hBottom, boxX + cornerLen, hBottom
        L[7][2], L[7][3], L[7][4], L[7][5] = hRight, hBottom, hRight, hBottom - cornerLen
        L[8][2], L[8][3], L[8][4], L[8][5] = hRight - cornerLen, hBottom, hRight, hBottom
        for i = 1, 8 do
            local e = L[i]
            local line = d[e[1]]
            if line then
                line.From = Vector2.new(e[2], e[3])
                line.To = Vector2.new(e[4], e[5])
                line.Color = color
                line.Transparency = transp
                line.Thickness = th
                line.Visible = true
            end
        end
    else
        for i = 1, 8 do
            local line = d[LABEL_KEYS[i]]
            if line then line.Visible = false end
        end
    end

    -- Head + body Highlight chams.
    if cfg.HeadHighlight then
        local hl = d.HeadHighlight
        if not hl then
            hl = Instance.new("Highlight")
            hl.Name = "HavocESPHead"
            hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
            hl.Adornee, hl.Parent = head, head
            d.HeadHighlight = hl
        end
        local t = guiT(cfg.HeadHighlightTransparency)
        hl.FillColor = rgb(cfg.HeadHighlightR, cfg.HeadHighlightG, cfg.HeadHighlightB)
        hl.OutlineColor = hl.FillColor
        hl.FillTransparency = cfg.HeadHighlightHollow and 1 or t
        hl.OutlineTransparency = t
        hl.Enabled = true
    elseif d.HeadHighlight then
        d.HeadHighlight.Enabled = false
    end

    if cfg.BodyHighlight then
        local hl = d.BodyHighlight
        if not hl then
            hl = Instance.new("Highlight")
            hl.Name = "HavocESPBody"
            hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
            hl.Adornee, hl.Parent = model, model
            d.BodyHighlight = hl
        end
        local t = guiT(cfg.BodyHighlightTransparency)
        hl.FillColor = rgb(cfg.BodyHighlightR, cfg.BodyHighlightG, cfg.BodyHighlightB)
        hl.OutlineColor = hl.FillColor
        hl.FillTransparency = cfg.BodyHighlightHollow and 1 or t
        hl.OutlineTransparency = t
        hl.Enabled = true
    elseif d.BodyHighlight then
        d.BodyHighlight.Enabled = false
    end

    -- Name - above the box, like Project Delta.
    if cfg.Name and d.NameLabel then
        local l = d.NameLabel
        l.Text = entityName(model, cfg.NameSource)
        l.Size = tonumber(cfg.NameSize) or 13
        l.Color = rgb(cfg.NameR, cfg.NameG, cfg.NameB)
        l.Transparency = drawT(cfg.NameTransparency)
        l.Position = Vector2.new(math.floor(screenX - l.TextBounds.X / 2), boxY - 20)
        l.Visible = true
    elseif d.NameLabel then
        d.NameLabel.Visible = false
    end

    -- Distance - metres, below the box, like Project Delta.
    if cfg.Distance and d.DistanceLabel then
        local l = d.DistanceLabel
        l.Text = ("%dm"):format(math.floor(distance))
        l.Size = tonumber(cfg.DistanceSize) or 12
        l.Color = rgb(cfg.DistanceR, cfg.DistanceG, cfg.DistanceB)
        l.Transparency = drawT(cfg.DistanceTransparency)
        l.Position = Vector2.new(math.floor(screenX - l.TextBounds.X / 2), hBottom + 2)
        l.Visible = true
    elseif d.DistanceLabel then
        d.DistanceLabel.Visible = false
    end

    -- Health - the number above the name, coloured by fraction.
    if cfg.Health and d.HealthLabel then
        local l = d.HealthLabel
        local hp, maxHp = entityHealth(model)
        local frac = (maxHp and maxHp > 0) and math.clamp(hp / maxHp, 0, 1) or 1
        l.Text = tostring(math.floor(hp))
        l.Size = tonumber(cfg.HealthSize) or 11
        l.Color = ESP.healthColor(frac)
        l.Transparency = drawT(cfg.HealthTransparency)
        l.Position = Vector2.new(math.floor(screenX - l.TextBounds.X / 2), boxY - 30)
        l.Visible = true
    elseif d.HealthLabel then
        d.HealthLabel.Visible = false
    end

    return true
end

-- ============================================================
-- ESP CLASS
-- ============================================================
local ESPClass = {}
ESPClass.__index = ESPClass

function ESP.new(settings)
    return setmetatable({
        cfg = settings or {},
        Objects = {},
    }, ESPClass)
end

-- Resolution helper: the config can be a live table or a getter function.
function ESPClass:Settings()
    local s = self.cfg
    if type(s) == "function" then
        local ok, res = pcall(s)
        return ok and res or nil
    end
    return s
end

-- Start tracking a model (idempotent). Call every frame or once - both
-- work; Prune() handles the removal side.
function ESPClass:Ensure(model)
    if not model or typeof(model) ~= "Instance" or not model.Parent then return nil end
    local d = self.Objects[model]
    if d then return d end
    d = {
        model = model,
        TL_V = newLine(), TL_H = newLine(), TR_V = newLine(), TR_H = newLine(),
        BL_V = newLine(), BL_H = newLine(), BR_V = newLine(), BR_H = newLine(),
        NameLabel = newText(),
        DistanceLabel = newText(),
        HealthLabel = newText(),
    }
    self.Objects[model] = d
    return d
end

function ESPClass:Remove(model)
    local d = self.Objects[model]
    if not d then return end
    destroyData(d)
    self.Objects[model] = nil
end

function ESPClass:Clear()
    for model in pairs(self.Objects) do
        self:Remove(model)
    end
end

-- Drop everything not present in the `seen` set (or already unparented).
function ESPClass:Prune(seen)
    local removals = nil
    for model in pairs(self.Objects) do
        if (not seen or not seen[model]) or not model.Parent then
            removals = removals or {}
            table.insert(removals, model)
        end
    end
    if removals then
        for i = 1, #removals do
            self:Remove(removals[i])
        end
    end
end

function ESPClass:HideAll()
    for _, d in pairs(self.Objects) do
        hideData(d)
    end
end

function ESPClass:IsEnemy(model)
    if not model or model == LocalPlayer.Character then return false end
    local cfg = self:Settings()
    if type(cfg) == "table" and cfg.TeamCheck then
        local p = Players:GetPlayerFromCharacter(model)
        if p and p.Team and LocalPlayer.Team and p.Team == LocalPlayer.Team then
            return false
        end
    end
    return true
end

function ESPClass:GetDistance(model)
    local lr = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    local tr = model and npcRoot(model)
    if not lr or not tr then return math.huge end
    return (lr.Position - tr.Position).Magnitude
end

-- Draw one frame for every tracked model.
function ESPClass:Render(cam)
    local cfg = self:Settings()
    if type(cfg) ~= "table" then return end
    cam = cam or workspace.CurrentCamera
    if not cam then return end

    if not cfg.Enabled then
        self:HideAll()
        return
    end

    local maxDist = tonumber(cfg.MaxDistance) or 2000
    local viewportH = cam.ViewportSize.Y
    local fovTan = math.tan(math.rad(cam.FieldOfView) * 0.5)
    local localRoot = LocalPlayer.Character
        and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")

    local removals = nil
    for model, d in pairs(self.Objects) do
        local ok, keep = pcall(renderOne, cfg, model, d, cam, maxDist, viewportH, fovTan, localRoot)
        if not ok or keep == false then
            removals = removals or {}
            table.insert(removals, model)
        end
    end
    if removals then
        for i = 1, #removals do
            self:Remove(removals[i])
        end
    end
end

return ESP
