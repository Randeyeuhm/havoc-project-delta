--[[
    ============================================
    HAVOC HUB - ESP LIBRARY  (esp.luau)
    ============================================

    ONE file, everything ESP: the engine (ported from Project Delta's ESP
    class) AND its two-window customizer. Every game script in the hub can
    use this directly:

        local esp = ESP.new(function() return Config.ESP end)
        esp:Ensure(model)     -- start tracking a model (idempotent)
        esp:Prune(seenSet)    -- drop everything not in the set
        esp:Render(camera)    -- draw one frame

        ESP.open{ cfg, uilib, screenGui, save?, notify? }   -- customizer

    RULE: every ESP feature/option lives in THIS file. Any new UI widget
    or generic UI option belongs in uilib.luau instead - this customizer
    only uses the uilib factories (makeToggle / makeSlider / makeDropdown
    / makeColorPicker / makeButton / makeNote / makeSectionHeader /
    makeWindow).

    What it draws (Project Delta's look):
      - corner box: 8 Line segments, fixed corner length capped at 30% of
        the box's short side
      - name / health / distance labels (outlined Text)
      - Highlights (chams) - one picker chooses the part (Head / Body /
        Both), with shared colour, opacity and hollow settings

    Health works for player rigs (Humanoid) AND vehicle-style NPCs that
    keep health as an attribute on the model / PrimaryPart / Chassis.

    Transparency rules: every "*Transparency" field is OPACITY
    (1 = fully visible). This executor's Drawing alpha is INVERTED
    (1 = visible), so opacity passes through as-is (drawT); Highlight
    instances and GUI frames are standard engine objects and get the
    usual 1 - opacity conversion (guiT).

    ESP.fill(cfg)     injects defaults + strips keys from the old
                      espui schema so saved configs start clean
    ESP.sanitize(cfg) clamps numbers and repairs enum values

    ESP.newRenderer(getCfg) returns the host adapter:
        { render(targets, cam, mouse), release(key), clear() }
    Hosts keep their target loops (they still handle the Visible-only
    raycast etc.); the adapter syncs the target models into the engine.
]]

local Players     = game:GetService("Players")
local RunService  = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

local ESP = {}
ESP.VERSION = "esp-v3-chams-picker"

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

    -- chams (Highlight) - ONE picker decides what gets highlighted; the
    -- colour/opacity/hollow settings are shared by whatever part(s) are on
    ChamsPart = "None",   -- None | Head | Body | Both
    ChamsHollow = false,
    ChamsTransparency = 0.7,
    ChamsR = 255, ChamsG = 80, ChamsB = 80,
}
ESP.DEFAULTS = DEFAULTS

local CHOICES = {
    NameSource = { ["Username"] = true, ["DisplayName"] = true },
    ChamsPart = { ["None"] = true, ["Head"] = true, ["Body"] = true, ["Both"] = true },
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
    -- the split head/body chams of esp-v1/v2 (migrated into ChamsPart in fill)
    "HeadHighlight", "HeadHighlightHollow", "HeadHighlightTransparency",
    "HeadHighlightR", "HeadHighlightG", "HeadHighlightB",
    "BodyHighlight", "BodyHighlightHollow", "BodyHighlightTransparency",
    "BodyHighlightR", "BodyHighlightG", "BodyHighlightB",
}

function ESP.fill(cfg)
    if type(cfg) ~= "table" then return cfg end
    -- Migrate the old split head/body chams into the single ChamsPart picker
    -- (must run BEFORE the defaults injection below).
    if cfg.ChamsPart == nil and (cfg.HeadHighlight ~= nil or cfg.BodyHighlight ~= nil) then
        local wasHead = cfg.HeadHighlight == true
        local wasBody = cfg.BodyHighlight == true
        if wasHead and wasBody then cfg.ChamsPart = "Both"
        elseif wasHead then cfg.ChamsPart = "Head"
        elseif wasBody then cfg.ChamsPart = "Body"
        else cfg.ChamsPart = "None" end
        local src = wasBody and "Body" or "Head"
        cfg.ChamsHollow = cfg[src .. "HighlightHollow"] == true
        cfg.ChamsTransparency = cfg[src .. "HighlightTransparency"] or 0.7
        cfg.ChamsR = cfg[src .. "HighlightR"] or 255
        cfg.ChamsG = cfg[src .. "HighlightG"] or 80
        cfg.ChamsB = cfg[src .. "HighlightB"] or 80
    end
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
    cfg.ChamsTransparency = num(cfg.ChamsTransparency, 0, 1, 0.7)
    if CHOICES.NameSource[cfg.NameSource] ~= true then cfg.NameSource = "Username" end
    if CHOICES.ChamsPart[cfg.ChamsPart] ~= true then cfg.ChamsPart = "None" end
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
-- Highlight instances and GUI frames use standard engine transparency.
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

-- Shared chams updater: creates the Highlight on first use, then keeps its
-- colour / opacity / hollow in sync every frame.
local function applyCham(d, cfg, field, name, adornee, parent)
    local hl = d[field]
    if not hl then
        hl = Instance.new("Highlight")
        hl.Name = name
        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        hl.Adornee, hl.Parent = adornee, parent
        d[field] = hl
    end
    local t = guiT(cfg.ChamsTransparency)
    hl.FillColor = rgb(cfg.ChamsR, cfg.ChamsG, cfg.ChamsB)
    hl.OutlineColor = hl.FillColor
    hl.FillTransparency = cfg.ChamsHollow and 1 or t
    hl.OutlineTransparency = t
    hl.Enabled = true
end

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

    -- Chams (Highlight): ONE picker (ChamsPart) decides which part(s) get
    -- highlighted; colour, opacity and hollow are shared.
    local chams = cfg.ChamsPart
    if chams == "Head" or chams == "Both" then
        applyCham(d, cfg, "HeadHighlight", "HavocESPHeadCham", head, head)
    elseif d.HeadHighlight then
        d.HeadHighlight.Enabled = false
    end
    if chams == "Body" or chams == "Both" then
        applyCham(d, cfg, "BodyHighlight", "HavocESPBodyCham", model, model)
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

-- ============================================================
-- HOST ADAPTER
-- ============================================================
-- Hosts keep building their target lists each frame ({key, model, ...});
-- everything visual is derived by the engine from the model itself.
function ESP.newRenderer(getCfg)
    local engine = ESP.new(getCfg)
    local R = { cfg = getCfg, engine = engine }

    function R:render(targets, cam, mouse)
        local cfg = getCfg and getCfg() or nil
        if type(cfg) ~= "table" or not cfg.Enabled then
            engine:HideAll()
            return
        end
        targets = targets or {}
        local seen = {}
        for i = 1, #targets do
            local m = targets[i] and targets[i].model
            if typeof(m) == "Instance" and m.Parent then
                seen[m] = true
                engine:Ensure(m)
            end
        end
        engine:Prune(seen)
        engine:Render(cam or workspace.CurrentCamera)
    end

    function R:release(key)
        engine:Remove(key)
    end

    function R:clear()
        engine:Clear()
    end

    return R
end

-- ============================================================
-- DIAGNOSTICS
-- ============================================================
-- Draws one of each shape with a number for 12 seconds - whatever is
-- missing from the screenshot is what this client cannot render.
function ESP.primitiveTest()
    local objs = {}
    local function keep(o)
        if o then table.insert(objs, o) end
    end
    local function numLabel(text, x, y)
        local ok, t = pcall(Drawing.new, "Text")
        if not ok or not t then return end
        t.Text = text
        t.Size = 16
        t.Color = Color3.fromRGB(255, 255, 255)
        t.Position = Vector2.new(x, y)
        t.Outline = true
        t.Center = false
        t.Visible = true
        keep(t)
    end
    local white = Color3.fromRGB(255, 255, 255)
    local y = math.max(140, math.floor((workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize.Y or 600) * 0.22))

    do -- 1: filled Square
        local ok, sq = pcall(Drawing.new, "Square")
        if ok and sq then
            sq.Filled = true
            sq.Size = Vector2.new(60, 60)
            sq.Position = Vector2.new(60, y)
            sq.Color = Color3.fromRGB(255, 80, 80)
            sq.Transparency = 1
            sq.Visible = true
            keep(sq)
        end
        numLabel("1 square", 60, y - 22)
    end
    do -- 2: line rectangle (4 Line objects)
        local pts = {
            { 160, y, 220, y }, { 220, y, 220, y + 60 },
            { 220, y + 60, 160, y + 60 }, { 160, y + 60, 160, y },
        }
        for i = 1, 4 do
            local ok, l = pcall(Drawing.new, "Line")
            if ok and l then
                l.From = Vector2.new(pts[i][1], pts[i][2])
                l.To = Vector2.new(pts[i][3], pts[i][4])
                l.Color = white
                l.Thickness = 2
                l.Transparency = 1
                l.Visible = true
                keep(l)
            end
        end
        numLabel("2 lines", 160, y - 22)
    end
    do -- 3: filled Circle
        local ok, c = pcall(Drawing.new, "Circle")
        if ok and c then
            c.Filled = true
            c.NumSides = 64
            c.Radius = 30
            c.Position = Vector2.new(320, y + 30)
            c.Color = Color3.fromRGB(80, 180, 255)
            c.Transparency = 1
            c.Visible = true
            keep(c)
        end
        numLabel("3 circle", 290, y - 22)
    end
    do -- 4: filled Triangle
        local ok, tr = pcall(Drawing.new, "Triangle")
        if ok and tr then
            tr.PointA = Vector2.new(400, y)
            tr.PointB = Vector2.new(370, y + 60)
            tr.PointC = Vector2.new(430, y + 60)
            tr.Color = Color3.fromRGB(120, 255, 120)
            tr.Transparency = 1
            tr.Visible = true
            keep(tr)
        end
        numLabel("4 triangle", 370, y - 22)
    end
    numLabel("5 text + outline", 470, y)

    print(("[esp] primitive test drawn (build %s) - screenshot the numbered shapes"):format(ESP.VERSION))
    task.spawn(function()
        task.wait(12)
        for i = 1, #objs do
            local o = objs[i]
            pcall(function() o:Remove() end)
        end
    end)
end

-- ============================================================
-- CUSTOMIZER - PREVIEW WINDOW
-- ============================================================
local OPEN = { ui = nil }

local function buildPreviewWindow(ctx, THEME, FONTS)
    local UILib = ctx.uilib
    local cfg = ctx.cfg
    local create, corner, stroke = UILib.create, UILib.corner, UILib.stroke

    local win = UILib.makeWindow{
        parent = ctx.screenGui,
        name = "ESPPreview",
        title = "ESP PREVIEW",
        size = UDim2.new(0, 300, 0, 430),
        position = UDim2.new(0, 604, 0, 40),
        zindex = 20,
    }
    local preview = win.frame

    local vp = create("ViewportFrame", {
        Size = UDim2.new(1, -16, 0, 310),
        Position = UDim2.fromOffset(8, 44),
        BackgroundColor3 = Color3.fromRGB(24, 24, 30),
        BorderSizePixel = 0,
        ZIndex = 1,
        Parent = preview,
    })
    corner(vp, 8)
    stroke(vp, THEME.STROKE)

    local vpCam = create("Camera", {})

    -- Overlay: the same elements the engine draws in-game, laid over the
    -- viewport so the preview reads like a live screenshot.
    local overlay = create("Frame", {
        Size = vp.Size,
        Position = vp.Position,
        BackgroundTransparency = 1,
        ZIndex = 5,
        Parent = preview,
    })

    -- Build the dummy: a clone of the local character when possible,
    -- otherwise a classic blocky stand-in.
    local model
    do
        local char = LocalPlayer.Character
        if char then
            local ok, clone = pcall(function() return char:Clone() end)
            if ok and clone then model = clone end
        end
        if not model then
            model = Instance.new("Model")
            local function part(name, size, color, pos)
                local p = Instance.new("Part")
                p.Name = name
                p.Size = size
                p.Color = color
                p.Anchored = true
                p.CanCollide = false
                p.CFrame = CFrame.new(pos)
                p.Parent = model
                return p
            end
            local skin = Color3.fromRGB(245, 205, 48)
            part("Head", Vector3.new(1.4, 1.2, 1.4), skin, Vector3.new(0, 4.8, 0))
            part("Torso", Vector3.new(2, 2, 1), Color3.fromRGB(13, 105, 172), Vector3.new(0, 3, 0))
            part("Left Arm", Vector3.new(1, 2, 1), skin, Vector3.new(-1.5, 3, 0))
            part("Right Arm", Vector3.new(1, 2, 1), skin, Vector3.new(1.5, 3, 0))
            part("Left Leg", Vector3.new(1, 2, 1), Color3.fromRGB(75, 151, 75), Vector3.new(-0.5, 1, 0))
            part("Right Leg", Vector3.new(1, 2, 1), Color3.fromRGB(75, 151, 75), Vector3.new(0.5, 1, 0))
        end
        for _, d in ipairs(model:GetDescendants()) do
            if d:IsA("LuaSourceContainer") or d:IsA("Sound") or d:IsA("ParticleEmitter")
                or d:IsA("Trail") or d:IsA("Beam") then
                pcall(function() d:Destroy() end)
            elseif d:IsA("BasePart") then
                d.Anchored = true
                d.CanCollide = false
            end
        end
        pcall(function() model:PivotTo(CFrame.new(0, 0, 0)) end)
        model.Parent = vp
    end

    -- Frame the dummy: measure it once, then aim a pinhole camera at its
    -- centre from the front. ViewportFrame cameras do not map their
    -- WorldToViewportPoint to frame pixels, so the overlay projection
    -- below is done manually with this camera instead.
    local modelCF, modelSize
    do
        local ok, cf, sz = pcall(function()
            local a, b = model:GetBoundingBox()
            return a, b
        end)
        if ok and cf then
            modelCF, modelSize = cf, sz
            local center = cf.Position
            local dist = sz.Y * 1.35 + 1.5
            vpCam.CFrame = CFrame.lookAt(center + Vector3.new(0, sz.Y * 0.12, -dist), center)
        end
    end
    vp.CurrentCamera = vpCam

    local function projectPoint(world)
        if not modelCF then return nil end
        local szp = vp.AbsoluteSize
        if szp.Y < 10 then return nil end
        local rel = vpCam.CFrame:PointToObjectSpace(world)
        if rel.Z >= -0.05 then return nil end
        local focal = (szp.Y / 2) / math.tan(math.rad(vpCam.FieldOfView / 2))
        return Vector2.new(
            szp.X / 2 + (rel.X / -rel.Z) * focal,
            szp.Y / 2 - (rel.Y / -rel.Z) * focal
        )
    end

    -- Element frames (positioned every update with the same maths as the
    -- engine).
    local el = { corners = {} }
    local function mkFrame(extra)
        local f = create("Frame", extra)
        f.Visible = false
        return f
    end
    local function mkLabel(text, size)
        local l = create("TextLabel", {
            Text = text,
            TextSize = size,
            BackgroundTransparency = 1,
            AnchorPoint = Vector2.new(0.5, 0),
            Font = FONTS.MEDIUM,
            ZIndex = 6,
            Parent = overlay,
        })
        l.Visible = false
        stroke(l, Color3.new(0, 0, 0))
        return l
    end
    for i = 1, 8 do
        el.corners[i] = mkFrame({
            BorderSizePixel = 0,
            BackgroundColor3 = Color3.fromRGB(255, 80, 80),
            ZIndex = 6,
            Parent = overlay,
        })
    end
    el.name = mkLabel("DemoPlayer", 13)
    el.health = mkLabel("72", 11)
    el.dist = mkLabel("42m", 12)

    local function updatePreview()
        -- Box rect: project the dummy's bounding box through the preview
        -- camera (manual pinhole projection - see projectPoint above).
        local rect
        if modelCF and modelSize then
            local top = projectPoint(modelCF.Position + Vector3.new(0, modelSize.Y / 2, 0))
            local bot = projectPoint(modelCF.Position - Vector3.new(0, modelSize.Y / 2, 0))
            if top and bot then
                local h = math.max(bot.Y - top.Y, 40)
                -- Project Delta's box proportions: 4.5 wide x 6.5 tall.
                local w = h * (4.5 / 6.5)
                rect = { x = (top.X + bot.X) / 2 - w / 2, y = top.Y, w = w, h = h }
            end
        end
        if not rect then
            local szp = vp.AbsoluteSize
            local h = math.max(szp.Y * 0.62, 60)
            local w = h * (4.5 / 6.5)
            rect = { x = szp.X / 2 - w / 2, y = szp.Y * 0.16, w = w, h = h }
        end

        local boxColor = rgb(cfg.BoxR, cfg.BoxG, cfg.BoxB)

        -- Corner box: the engine's exact 8-segment template, as pixel rects.
        if cfg.Box then
            local L = math.min(tonumber(cfg.BoxCornerLength) or 6, math.min(rect.w, rect.h) * 0.3)
            local th = tonumber(cfg.BoxThickness) or 2
            local cx, cy = rect.x + rect.w, rect.y + rect.h
            local specs = {
                { rect.x - th / 2, rect.y, th, L },        -- TL vertical
                { rect.x, rect.y - th / 2, L, th },        -- TL horizontal
                { cx - th / 2, rect.y, th, L },            -- TR vertical
                { cx - L, rect.y - th / 2, L, th },        -- TR horizontal
                { rect.x - th / 2, cy - L, th, L },        -- BL vertical
                { rect.x, cy - th / 2, L, th },            -- BL horizontal
                { cx - th / 2, cy - L, th, L },            -- BR vertical
                { cx - L, cy - th / 2, L, th },            -- BR horizontal
            }
            for i = 1, 8 do
                local c = el.corners[i]
                local s = specs[i]
                c.Visible = true
                c.Position = UDim2.fromOffset(s[1], s[2])
                c.Size = UDim2.fromOffset(s[3], s[4])
                c.BackgroundColor3 = boxColor
                c.BackgroundTransparency = guiT(cfg.BoxTransparency)
            end
        else
            for i = 1, 8 do el.corners[i].Visible = false end
        end

        -- Name above the box, health above the name, distance below the
        -- box - the same anchors the engine uses.
        local midX = rect.x + rect.w / 2
        el.name.Visible = cfg.Name and true or false
        if cfg.Name then
            el.name.Text = "DemoPlayer"
            el.name.TextSize = tonumber(cfg.NameSize) or 13
            el.name.TextColor3 = rgb(cfg.NameR, cfg.NameG, cfg.NameB)
            el.name.TextTransparency = guiT(cfg.NameTransparency)
            el.name.Position = UDim2.fromOffset(midX, rect.y - 20)
        end
        el.health.Visible = cfg.Health and true or false
        if cfg.Health then
            el.health.Text = "72"
            el.health.TextSize = tonumber(cfg.HealthSize) or 11
            el.health.TextColor3 = ESP.healthColor(0.72)
            el.health.TextTransparency = guiT(cfg.HealthTransparency)
            el.health.Position = UDim2.fromOffset(midX, rect.y - 30)
        end
        el.dist.Visible = cfg.Distance and true or false
        if cfg.Distance then
            el.dist.Text = "42m"
            el.dist.TextSize = tonumber(cfg.DistanceSize) or 12
            el.dist.TextColor3 = rgb(cfg.DistanceR, cfg.DistanceG, cfg.DistanceB)
            el.dist.TextTransparency = guiT(cfg.DistanceTransparency)
            el.dist.Position = UDim2.fromOffset(midX, rect.y + rect.h + 2)
        end
    end

    RunService.RenderStepped:Connect(function()
        if preview.Visible then
            pcall(updatePreview)
        end
    end)

    return preview
end

-- ============================================================
-- CUSTOMIZER - SETTINGS WINDOW
-- ============================================================
local function buildOptionsWindow(ctx, THEME, FONTS)
    local UILib = ctx.uilib
    local cfg = ctx.cfg
    local save = ctx.save
    local function persist()
        if save then pcall(save) end
    end

    local win = UILib.makeWindow{
        parent = ctx.screenGui,
        name = "ESPCustomizer",
        title = "ESP CUSTOMIZER",
        size = UDim2.new(0, 560, 0, 470),
        position = UDim2.new(0, 30, 0, 40),
        -- Above the preview window (20) so its popup layer beats everything
        -- when the two windows are dragged over each other.
        zindex = 21,
        tabs = { "General", "Box", "Name", "Health", "Distance", "Chams" },
    }
    local options = win.frame
    local pages = { win.tab(1), win.tab(2), win.tab(3), win.tab(4), win.tab(5), win.tab(6) }
    local popupLayer = win.popupLayer

    local controls = {}
    local function refresh()
        for _, e in ipairs(controls) do
            if e.update then pcall(e.update) end
        end
    end
    -- Every widget goes through a labelled pcall: one bad row must never
    -- empty a whole tab, and the console names exactly what failed.
    local function guard(what, fn)
        local ok, e = pcall(fn)
        if ok and type(e) == "table" then
            table.insert(controls, e)
            return e
        end
        warn(("[esp] widget '%s' failed: %s"):format(what, tostring(e)))
        return nil
    end
    local function section(page, text)
        guard("section " .. text, function() return UILib.makeSectionHeader(page, text) end)
    end
    local function note(page, text)
        pcall(function() UILib.makeNote(page, text, "auto") end)
    end
    local function toggle(page, text, key)
        guard("toggle " .. text, function()
            return UILib.makeToggle(page, text,
                function() return cfg[key] end,
                function(v)
                    cfg[key] = v
                    persist()
                end)
        end)
    end
    local function slider(page, text, key, step, mn, mx)
        guard("slider " .. text, function()
            return UILib.makeSlider(page, text,
                function() return cfg[key] end,
                function(v)
                    cfg[key] = v
                    persist()
                end, step, mn, mx)
        end)
    end
    local function dropdown(page, text, key, items)
        guard("dropdown " .. text, function()
            return UILib.makeDropdown(page, text,
                function() return items end,
                function() return cfg[key] end,
                function(v)
                    cfg[key] = v
                    persist()
                    refresh()
                end, popupLayer)
        end)
    end
    local function colorpicker(page, label, prefix)
        guard("colour " .. label, function()
            return UILib.makeColorPicker(page, label, cfg, prefix, persist)
        end)
    end
    local function button(page, text, fn, opts)
        guard("button " .. text, function() return UILib.makeButton(page, text, fn, opts) end)
    end

    -- ---------------- General ----------------
    local p1 = pages[1]
    section(p1, "Master")
    toggle(p1, "ESP enabled", "Enabled")
    note(p1, "Opacity sliders everywhere: 1 = fully visible.")
    section(p1, "Targeting")
    toggle(p1, "Team check", "TeamCheck")
    toggle(p1, "Visible only (raycast)", "VisibleOnly")
    slider(p1, "Max distance", "MaxDistance", 100, 100, 10000)
    section(p1, "Reset")
    button(p1, "Reset ESP settings to defaults", function()
        for k, v in pairs(ESP.DEFAULTS) do
            if k ~= "Enabled" then cfg[k] = v end
        end
        refresh()
        persist()
        if ctx.notify then pcall(ctx.notify, "ESP settings reset to defaults") end
    end, { confirm = true, confirmText = "Click again to reset" })
    section(p1, "Diagnostics")
    button(p1, "Drawing primitive test (12s)", function()
        ESP.primitiveTest()
        if ctx.notify then pcall(ctx.notify, "Primitive test drawn - screenshot the numbered shapes") end
    end)

    -- ---------------- Box ----------------
    local p2 = pages[2]
    section(p2, "Corner box")
    toggle(p2, "Corner box", "Box")
    slider(p2, "Corner length", "BoxCornerLength", 1, 0, 40)
    slider(p2, "Thickness", "BoxThickness", 1, 1, 6)
    slider(p2, "Opacity", "BoxTransparency", 0.05, 0, 1)
    colorpicker(p2, "Box colour", "Box")
    note(p2, "Corner length caps at 30% of the box's short side.")

    -- ---------------- Name ----------------
    local p3 = pages[3]
    section(p3, "Name")
    toggle(p3, "Name", "Name")
    dropdown(p3, "Source", "NameSource", { "Username", "DisplayName" })
    slider(p3, "Text size", "NameSize", 1, 8, 24)
    slider(p3, "Opacity", "NameTransparency", 0.05, 0, 1)
    colorpicker(p3, "Name colour", "Name")
    note(p3, "Drawn above the box.")

    -- ---------------- Health ----------------
    local p4 = pages[4]
    section(p4, "Health")
    toggle(p4, "Health", "Health")
    slider(p4, "Text size", "HealthSize", 1, 8, 24)
    slider(p4, "Opacity", "HealthTransparency", 0.05, 0, 1)
    note(p4, "Number above the box - colour scales with HP.")

    -- ---------------- Distance ----------------
    local p5 = pages[5]
    section(p5, "Distance")
    toggle(p5, "Distance", "Distance")
    slider(p5, "Text size", "DistanceSize", 1, 8, 24)
    slider(p5, "Opacity", "DistanceTransparency", 0.05, 0, 1)
    colorpicker(p5, "Distance colour", "Distance")
    note(p5, "Metres, below the box.")

    -- ---------------- Chams ----------------
    local p6 = pages[6]
    section(p6, "Chams (Highlight)")
    dropdown(p6, "Part to highlight", "ChamsPart", { "None", "Head", "Body", "Both" })
    toggle(p6, "Hollow (outline only)", "ChamsHollow")
    slider(p6, "Opacity", "ChamsTransparency", 0.05, 0, 1)
    colorpicker(p6, "Chams colour", "Chams")
    note(p6, "Chams can't render in the preview window - check them in-game.")

    win.setTab(1)
    print("[esp] settings built (" .. tostring(#controls) .. " controls)")

    return options, refresh
end

-- ============================================================
-- CUSTOMIZER - OPEN / TOGGLE
-- ============================================================
function ESP.open(ctx)
    if type(ctx) ~= "table" or not ctx.cfg or not ctx.uilib or not ctx.screenGui then
        return false, "esp.open needs { cfg, uilib, screenGui }"
    end
    -- Called from a click callback: restore the executor thread identity
    -- before any window building happens (see uilib.restoreIdentity).
    if ctx.uilib.restoreIdentity then ctx.uilib.restoreIdentity() end
    if OPEN.ui and OPEN.ui.screenGui == ctx.screenGui then
        local ui = OPEN.ui
        local showing = ui.preview.Visible or ui.options.Visible
        ui.preview.Visible = not showing
        ui.options.Visible = not showing
        if not showing then ui.refresh() end
        return true
    end
    local THEME, FONTS = ctx.uilib.THEME, ctx.uilib.FONTS
    -- Build independently: a failure in one window must not stop the other,
    -- and both failures are reported with their real error text.
    local okP, previewFrame = pcall(buildPreviewWindow, ctx, THEME, FONTS)
    if not okP then
        warn("[esp] preview build failed: " .. tostring(previewFrame))
        previewFrame = nil
    end
    local okO, optionsFrame, refreshFn = pcall(buildOptionsWindow, ctx, THEME, FONTS)
    if not okO then
        warn("[esp] options build failed: " .. tostring(optionsFrame))
        optionsFrame, refreshFn = nil, nil
    end
    if not (previewFrame and optionsFrame) then
        if previewFrame then pcall(function() previewFrame:Destroy() end) end
        if optionsFrame then pcall(function() optionsFrame:Destroy() end) end
        return false, "customizer build failed"
    end
    OPEN.ui = {
        screenGui = ctx.screenGui,
        options = optionsFrame,
        preview = previewFrame,
        refresh = refreshFn,
    }
    return true
end

print(("[esp] %s loaded (one-file library: engine + customizer, opacity: 1 = fully visible)"):format(ESP.VERSION))

return ESP
