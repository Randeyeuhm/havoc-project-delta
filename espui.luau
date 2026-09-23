--[[
    ============================================
    ESP CUSTOMIZER + RENDERER  (espui.luau)
    ============================================

    Shared by every Havoc Hub script. Two parts:

    • RENDERER - ESPUI.newRenderer(getCfg) returns a renderer that draws a
      full player ESP (boxes, fills, corners, names, health bars/text,
      distance, tracers, head dots, skeletons, look lines, off-screen
      arrows and Highlight chams) from a flat config table. Hosts build a
      target list each frame and call render(targets, cam, mouse).

    • CUSTOMIZER UI - ESPUI.open{ cfg, uilib, screenGui, save?, notify? }
      opens two windows: a PREVIEW window (a real clone of the local
      character in a ViewportFrame with every ESP element drawn over it,
      scaled and positioned exactly like in-game) and a SETTINGS window
      (Box / Name / Health / Distance / Extras / Filters tabs, every option
      a live row, colour pickers and offsets included).

    Hosts own persistence: ESPUI.fill(cfg) injects defaults for missing
    keys and ESPUI.sanitize(cfg) repairs invalid enum values.

    Target spec (per frame):
      { key = <unique>, model = <Model|nil>, name = <string>,
        health = <number>, maxHealth = <number>,
        headPos/topPos/bottomPos = <Vector3>, distance = <number>,
        teamColor = <Color3|nil>, lookDir = <Vector3|nil>,
        skel = { Head=, Torso=, LeftHand=, RightHand=, LeftFoot=, RightFoot= } }
]]

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")

local ESPUI = {}

-- Bumped whenever behaviour changes. Printed here on load and reported by
-- the loader, so "is my copy actually the new one?" is always answerable
-- from the console.
ESPUI.VERSION = "v4-opacity-unified"

-- ============================================================
-- SCHEMA  (flat table; colours stored as R/G/B numbers so uilib's
-- makeColorPicker can edit them directly via prefix)
-- ============================================================
-- NOTE: every "*Transparency" field below is actually OPACITY (1 = fully
-- visible, 0 = invisible). The in-game renderer and the preview BOTH convert
-- through the shared tex() helper below, so the two views can never disagree.
-- Sliders are labelled "Opacity" to match.
local DEFAULTS = {
    -- master + filters
    Enabled = false, TeamCheck = false, VisibleOnly = false,
    MaxDistance = 2000, UpdateRate = 1, RainbowSpeed = 1,

    -- box
    Box = true, BoxStyle = "Full", BoxOutline = true, BoxFill = false,
    BoxThickness = 1, BoxTransparency = 1, BoxFillTransparency = 0.65,
    BoxCornerLength = 6,
    BoxColorMode = "Static", BoxR = 255, BoxG = 80, BoxB = 80,

    -- name
    Name = true, NameAnchor = "Above", NameOffsetX = 0, NameOffsetY = 0,
    NameSize = 13, NameSource = "Username", NameShowHealth = true, NameOutline = true,
    NameColorMode = "Static", NameR = 235, NameG = 235, NameB = 245,

    -- health
    Health = true, HealthStyle = "Bar",
    HealthBarAnchor = "Left", HealthBarWidth = 2, HealthBarHeight = 0,
    HealthBarOutline = true, HealthBarTransparency = 1,
    HealthColorMode = "Gradient", HealthR = 82, HealthG = 202, HealthB = 128,
    HealthTextAnchor = "Below", HealthTextOffsetX = 0, HealthTextOffsetY = 0,
    HealthTextSize = 11, HealthTextFormat = "Value", HealthTextOutline = true,
    HealthTextColorMode = "Gradient", HealthTextR = 255, HealthTextG = 255, HealthTextB = 255,

    -- distance
    Distance = true, DistanceAnchor = "Below", DistanceOffsetX = 0, DistanceOffsetY = 0,
    DistanceSize = 12, DistanceUnit = "Meters", DistanceDecimals = 0, DistanceOutline = true,
    DistanceColorMode = "Static", DistanceR = 180, DistanceG = 180, DistanceB = 195,

    -- tracers
    Tracers = false, TracerOrigin = "Bottom", TracerOffsetX = 0, TracerOffsetY = 0,
    TracerThickness = 1, TracerTransparency = 0.65,
    TracerColorMode = "Static", TracerR = 255, TracerG = 80, TracerB = 80,

    -- extras
    HeadDot = false, HeadDotSize = 4,
    HeadDotColorMode = "Static", HeadDotR = 255, HeadDotG = 255, HeadDotB = 255,

    Skeleton = false, SkeletonThickness = 1, SkeletonTransparency = 0.8,
    SkeletonColorMode = "Static", SkeletonR = 255, SkeletonG = 255, SkeletonB = 255,

    LookLine = false, LookLineLength = 60, LookLineThickness = 1, LookLineTransparency = 0.5,
    LookLineColorMode = "Static", LookLineR = 96, LookLineG = 132, LookLineB = 218,

    Arrow = false, ArrowSize = 10, ArrowRadius = 170, ArrowThickness = 1, ArrowTransparency = 0.7,
    ArrowColorMode = "Static", ArrowR = 255, ArrowG = 80, ArrowB = 80,

    Chams = false, ChamsAlwaysOnTop = true,
    ChamsFillTransparency = 0.4, ChamsOutlineTransparency = 0.7,
    ChamsFillR = 255, ChamsFillG = 80, ChamsFillB = 80,
    ChamsOutlineR = 255, ChamsOutlineG = 120, ChamsOutlineB = 120,
}
ESPUI.DEFAULTS = DEFAULTS

local CHOICES = {
    BoxStyle = { ["Full"] = true, ["Corners"] = true, ["Fill"] = true },
    BoxColorMode = { ["Static"] = true, ["Team"] = true, ["Rainbow"] = true },
    NameAnchor = { ["Above"] = true, ["Below"] = true, ["Inside"] = true, ["Left"] = true, ["Right"] = true },
    NameSource = { ["Username"] = true, ["DisplayName"] = true },
    NameColorMode = { ["Static"] = true, ["Team"] = true, ["Rainbow"] = true },
    HealthStyle = { ["Bar"] = true, ["Text"] = true, ["Both"] = true },
    HealthBarAnchor = { ["Left"] = true, ["Right"] = true, ["Top"] = true, ["Bottom"] = true },
    HealthColorMode = { ["Gradient"] = true, ["Static"] = true, ["Team"] = true, ["Rainbow"] = true },
    HealthTextAnchor = { ["Above"] = true, ["Below"] = true, ["Inside"] = true, ["Left"] = true, ["Right"] = true },
    HealthTextFormat = { ["Value"] = true, ["Percent"] = true, ["Value/Max"] = true },
    HealthTextColorMode = { ["Gradient"] = true, ["Static"] = true, ["Team"] = true, ["Rainbow"] = true },
    DistanceAnchor = { ["Above"] = true, ["Below"] = true, ["Inside"] = true, ["Left"] = true, ["Right"] = true },
    DistanceUnit = { ["Meters"] = true, ["Studs"] = true, ["Km"] = true },
    DistanceColorMode = { ["Static"] = true, ["Rainbow"] = true },
    TracerOrigin = { ["Bottom"] = true, ["Top"] = true, ["Left"] = true, ["Right"] = true, ["Mouse"] = true },
    TracerColorMode = { ["Static"] = true, ["Team"] = true, ["Rainbow"] = true },
    HeadDotColorMode = { ["Static"] = true, ["Team"] = true, ["Rainbow"] = true },
    SkeletonColorMode = { ["Static"] = true, ["Team"] = true, ["Rainbow"] = true },
    LookLineColorMode = { ["Static"] = true, ["Team"] = true, ["Rainbow"] = true },
    ArrowColorMode = { ["Static"] = true, ["Team"] = true, ["Rainbow"] = true },
}

-- Injects any schema key the config is missing (existing values are kept,
-- so older configs migrate in place).
function ESPUI.fill(cfg)
    for k, v in pairs(DEFAULTS) do
        if cfg[k] == nil then cfg[k] = v end
    end
    return cfg
end

-- Repairs invalid enum values (e.g. a hand-edited config).
function ESPUI.sanitize(cfg)
    for field, allowed in pairs(CHOICES) do
        if not allowed[cfg[field]] then cfg[field] = DEFAULTS[field] end
    end
    return cfg
end

-- ============================================================
-- SHARED COLOUR / FORMAT HELPERS  (renderer + preview use the same ones,
-- so the preview matches the game pixel-for-pixel)
-- ============================================================
function ESPUI.healthColor(frac)
    frac = math.clamp(frac or 1, 0, 1)
    return Color3.fromRGB(
        math.floor((1 - frac) * 255 + 0.5),
        math.floor(frac * 255 + 0.5),
        60
    )
end

-- Converts a config opacity (1 = fully visible) into the transparency value
-- Drawing/GUI objects expect (1 = invisible). The preview and the in-game
-- renderer both go through this one function, so they can never drift apart.
local function tex(value)
    return 1 - math.clamp(value or 1, 0, 1)
end

-- mode: "Static" | "Team" | "Rainbow" | "Gradient"
-- hue: current rainbow hue (caller adds a per-element offset)
-- frac: health fraction for Gradient mode
function ESPUI.colorFor(mode, r, g, b, teamColor, hue, frac)
    if mode == "Team" and teamColor then return teamColor end
    if mode == "Rainbow" and hue then return Color3.fromHSV(hue % 1, 0.85, 1) end
    if mode == "Gradient" then return ESPUI.healthColor(frac) end
    return Color3.fromRGB(r or 255, g or 255, b or 255)
end

local function formatHealthText(fmt, health, max)
    health = math.floor((health or 0) + 0.5)
    if fmt == "Percent" then
        local pct = (max and max > 0) and (health / max * 100) or 0
        return tostring(math.floor(pct + 0.5)) .. "%"
    elseif fmt == "Value/Max" then
        return tostring(health) .. "/" .. tostring(math.floor((max or 0) + 0.5))
    end
    return tostring(health)
end

local function formatDistance(cfg, dist)
    dist = dist or 0
    if cfg.DistanceUnit == "Km" then
        return string.format("%.2f km", dist / 1000)
    end
    local dec = math.clamp(math.floor(cfg.DistanceDecimals or 0), 0, 2)
    local num = string.format("%." .. tostring(dec) .. "f", dist)
    return num .. (cfg.DistanceUnit == "Studs" and " studs" or "m")
end

-- Text centre point for an anchor around box rect r (text elements use
-- Center=true / AnchorPoint 0.5,0.5, so this returns the centre).
local function textCenter(anchor, r, offX, offY)
    local cx, cy = r.x + r.w / 2, r.y + r.h / 2
    offX, offY = offX or 0, offY or 0
    if anchor == "Above" then return cx + offX, r.y - 13 + offY end
    if anchor == "Below" then return cx + offX, r.y + r.h + 5 + offY end
    if anchor == "Inside" then return cx + offX, r.y + 9 + offY end
    if anchor == "Left" then return r.x - 40 + offX, cy + offY end
    if anchor == "Right" then return r.x + r.w + 40 + offX, cy + offY end
    return cx + offX, r.y - 9 + offY
end

-- Background + fill rectangles for the health bar. Returns bg, fill.
local function healthBarRects(cfg, r, frac)
    local vertical = (cfg.HealthBarAnchor == "Left" or cfg.HealthBarAnchor == "Right")
    local w, h
    if vertical then
        w = cfg.HealthBarWidth
        h = (cfg.HealthBarHeight and cfg.HealthBarHeight > 0) and cfg.HealthBarHeight or r.h
    else
        w = r.w
        h = cfg.HealthBarWidth
    end
    local x, y
    if cfg.HealthBarAnchor == "Left" then x = r.x - 4 - w; y = r.y
    elseif cfg.HealthBarAnchor == "Right" then x = r.x + r.w + 4; y = r.y
    elseif cfg.HealthBarAnchor == "Top" then x = r.x; y = r.y - 4 - h
    else x = r.x; y = r.y + r.h + 4 end

    frac = math.clamp(frac or 1, 0, 1)
    local fx, fy, fw, fh
    if vertical then
        fh = h * frac; fw = w; fx = x; fy = y + (h - fh)
    else
        fw = w * frac; fh = h; fx = x; fy = y
    end
    return { x = x, y = y, w = w, h = h }, { x = fx, y = fy, w = fw, h = fh }
end

-- The eight bar segments for the "Corners" box style: {x, y, w, h} each,
-- in TL, TR, BL, BR order (horizontal bar then vertical bar per corner).
local function cornerSpecs(r, cl, t)
    return {
        { r.x, r.y, cl, t }, { r.x, r.y, t, cl },
        { r.x + r.w - cl, r.y, cl, t }, { r.x + r.w - t, r.y, t, cl },
        { r.x, r.y + r.h - t, cl, t }, { r.x, r.y + r.h - cl, t, cl },
        { r.x + r.w - cl, r.y + r.h - t, cl, t }, { r.x + r.w - t, r.y + r.h - cl, t, cl },
    }
end

-- ============================================================
-- RENDERER
-- ============================================================
local HIDE_FIELDS = {
    "boxFill", "boxOutline", "name", "dist",
    "healthBg", "healthFill", "healthBorder", "healthText",
    "headDot", "tracer", "lookLine", "arrow",
    "corner1", "corner2", "corner3", "corner4",
    "corner5", "corner6", "corner7", "corner8",
}
local SKEL_PAIRS = {
    { "Head", "Torso" }, { "Torso", "LeftHand" }, { "Torso", "RightHand" },
    { "Torso", "LeftFoot" }, { "Torso", "RightFoot" },
}

function ESPUI.newRenderer(getCfg)
    local R = { cfg = getCfg, cache = {}, broken = false, frame = 0 }

    local function hideDrawing(o)
        if o and o.Visible ~= nil then o.Visible = false end
    end

    local function hideEntry(e)
        for _, f in ipairs(HIDE_FIELDS) do hideDrawing(e[f]) end
        if e.skel then
            for _, o in ipairs(e.skel) do hideDrawing(o) end
        end
    end

    local function destroyEntry(e)
        for _, f in ipairs(HIDE_FIELDS) do
            local o = e[f]
            if o and o.Remove then pcall(function() o:Remove() end) end
        end
        if e.skel then
            for _, o in ipairs(e.skel) do
                if o and o.Remove then pcall(function() o:Remove() end) end
            end
        end
        if e.highlight then pcall(function() e.highlight:Destroy() end) end
    end

    function R:release(key)
        local e = R.cache[key]
        if e then
            destroyEntry(e)
            R.cache[key] = nil
        end
    end

    local function getObj(e, field, ctor)
        if R.broken then return nil end
        if e[field] then return e[field] end
        local ok, obj = pcall(ctor)
        if not ok then
            R.broken = true
            warn("[espui] Drawing failed: " .. tostring(obj))
            return nil
        end
        e[field] = obj
        return obj
    end

    local function applySquare(e, field, x, y, w, h, color, transparency, filled, thickness)
        local o = getObj(e, field, function() return Drawing.new("Square") end)
        if not o then return end
        o.Visible = true
        o.Position = Vector2.new(x, y)
        o.Size = Vector2.new(math.max(w, 0), math.max(h, 0))
        o.Color = color
        o.Transparency = transparency
        o.Filled = filled and true or false
        o.Thickness = thickness or 1
    end

    local function applyText(e, field, x, y, text, size, color, outline)
        local o = getObj(e, field, function()
            local lbl = Drawing.new("Text")
            lbl.Center = true
            lbl.OutlineColor = Color3.new(0, 0, 0)
            return lbl
        end)
        if not o then return end
        o.Visible = true
        o.Text = text
        o.Size = size
        o.Color = color
        o.Outline = outline and true or false
        o.Position = Vector2.new(x, y)
    end

    local function applyLine(e, field, ax, ay, bx, by, color, thickness, transparency)
        local o = getObj(e, field, function() return Drawing.new("Line") end)
        if not o then return end
        o.Visible = true
        o.From = Vector2.new(ax, ay)
        o.To = Vector2.new(bx, by)
        o.Color = color
        o.Thickness = thickness or 1
        o.Transparency = transparency or 1
    end

    local function updateChams(e, model, cfg)
        if cfg.Chams and model and model.Parent then
            if not e.highlight then
                local ok, hl = pcall(function()
                    local h = Instance.new("Highlight")
                    h.Name = "HavocHubCham"
                    return h
                end)
                if not ok then return end
                e.highlight = hl
            end
            local hl = e.highlight
            hl.Adornee = model
            if hl.Parent ~= model then hl.Parent = model end
            hl.FillColor = Color3.fromRGB(cfg.ChamsFillR, cfg.ChamsFillG, cfg.ChamsFillB)
            hl.FillTransparency = tex(cfg.ChamsFillTransparency)
            hl.OutlineColor = Color3.fromRGB(cfg.ChamsOutlineR, cfg.ChamsOutlineG, cfg.ChamsOutlineB)
            hl.OutlineTransparency = tex(cfg.ChamsOutlineTransparency)
            hl.DepthMode = cfg.ChamsAlwaysOnTop
                and Enum.HighlightDepthMode.AlwaysOnTop
                or Enum.HighlightDepthMode.Occluded
        elseif e.highlight then
            pcall(function() e.highlight:Destroy() end)
            e.highlight = nil
        end
    end

    -- targets: list of target tables (see header). cam: workspace.CurrentCamera.
    function R:render(targets, cam, mouse)
        local cfg = R.cfg()
        if R.broken then return end
        if not cfg or not cfg.Enabled then
            for _, e in pairs(R.cache) do
                hideEntry(e)
                updateChams(e, nil, { Chams = false })
            end
            return
        end

        R.frame = R.frame + 1
        local rate = math.clamp(math.floor(cfg.UpdateRate or 1), 1, 4)
        if rate > 1 and R.frame % rate ~= 0 then return end

        local now = os.clock() * 0.18 * (cfg.RainbowSpeed or 1)
        local viewport = cam.ViewportSize
        local seen = {}
        local style = cfg.BoxStyle

        for i, t in ipairs(targets) do
            local e = R.cache[t.key]
            if not e then
                e = {}
                R.cache[t.key] = e
            end
            seen[t.key] = true
            e.misses = 0

            local hue = now + i * 0.07
            updateChams(e, t.model, cfg)

            local tp, onTop = cam:WorldToViewportPoint(t.topPos)
            local bp, onBot = cam:WorldToViewportPoint(t.bottomPos)
            local onScreen = tp.Z > 0 and bp.Z > 0 and (onTop or onBot)

            if not onScreen then
                -- Off-screen: hide everything but the direction arrow.
                hideEntry(e)
                if cfg.Arrow then
                    local rel = cam.CFrame:PointToObjectSpace(t.topPos)
                    local dir = Vector2.new(rel.X, -rel.Y)
                    if dir.Magnitude > 0.001 then
                        dir = dir.Unit
                        local maxR = math.min(viewport.X, viewport.Y) / 2 - 12
                        local radius = math.clamp(cfg.ArrowRadius, 30, math.max(maxR, 40))
                        local center = Vector2.new(viewport.X / 2, viewport.Y / 2) + dir * radius
                        local perp = Vector2.new(-dir.Y, dir.X)
                        local size = cfg.ArrowSize
                        local arrowColor = ESPUI.colorFor(cfg.ArrowColorMode,
                            cfg.ArrowR, cfg.ArrowG, cfg.ArrowB, t.teamColor, hue)
                        local o = getObj(e, "arrow", function()
                            local a = Drawing.new("Triangle")
                            a.Filled = true
                            return a
                        end)
                        if o then
                            o.Visible = true
                            o.PointA = center + dir * size
                            o.PointB = center - dir * size * 0.4 + perp * size * 0.7
                            o.PointC = center - dir * size * 0.4 - perp * size * 0.7
                            o.Color = arrowColor
                            o.Transparency = tex(cfg.ArrowTransparency)
                            o.Thickness = cfg.ArrowThickness
                        end
                    end
                end
            else
                local topY = math.min(tp.Y, bp.Y)
                local botY = math.max(tp.Y, bp.Y)
                local height = math.max(botY - topY, 8)
                local width = math.max(height * 0.55, 6)
                local rect = { x = (tp.X + bp.X) / 2 - width / 2, y = topY, w = width, h = height }

                local boxColor = ESPUI.colorFor(cfg.BoxColorMode,
                    cfg.BoxR, cfg.BoxG, cfg.BoxB, t.teamColor, hue)
                local frac = t.maxHealth and t.maxHealth > 0
                    and math.clamp(t.health / t.maxHealth, 0, 1) or 1

                -- Box: hide every variant first, then draw what the style needs.
                hideDrawing(e.boxFill); hideDrawing(e.boxOutline)
                for c = 1, 8 do hideDrawing(e["corner" .. c]) end

                if cfg.Box then
                    if style == "Corners" then
                        local cl, th = cfg.BoxCornerLength, cfg.BoxThickness
                        local specs = cornerSpecs(rect, cl, th)
                        for c = 1, 8 do
                            local s = specs[c]
                            applySquare(e, "corner" .. c, s[1], s[2], s[3], s[4],
                                boxColor, tex(cfg.BoxTransparency), true, 1)
                        end
                    else
                        local wantFill = (style == "Fill") or (style == "Full" and cfg.BoxFill)
                        if wantFill then
                            applySquare(e, "boxFill", rect.x, rect.y, rect.w, rect.h,
                                boxColor, tex(cfg.BoxFillTransparency), true, 1)
                        end
                        if cfg.BoxOutline then
                            applySquare(e, "boxOutline", rect.x, rect.y, rect.w, rect.h,
                                boxColor, tex(cfg.BoxTransparency), false, cfg.BoxThickness)
                        end
                    end
                end

                -- Name
                if cfg.Name then
                    local text = t.name or "?"
                    if cfg.NameShowHealth then
                        text = text .. " [" .. formatHealthText("Value", t.health, t.maxHealth) .. "]"
                    end
                    local nx, ny = textCenter(cfg.NameAnchor, rect, cfg.NameOffsetX, cfg.NameOffsetY)
                    local nameColor = ESPUI.colorFor(cfg.NameColorMode,
                        cfg.NameR, cfg.NameG, cfg.NameB, t.teamColor, hue)
                    applyText(e, "name", nx, ny, text, cfg.NameSize, nameColor, cfg.NameOutline)
                else
                    hideDrawing(e.name)
                end

                -- Health bar + text
                if cfg.Health and (cfg.HealthStyle == "Bar" or cfg.HealthStyle == "Both") then
                    local bg, fill = healthBarRects(cfg, rect, frac)
                    local barColor = ESPUI.colorFor(cfg.HealthColorMode,
                        cfg.HealthR, cfg.HealthG, cfg.HealthB, t.teamColor, hue, frac)
                    applySquare(e, "healthBg", bg.x, bg.y, bg.w, bg.h,
                        Color3.new(0, 0, 0), 0.5, true, 1)
                    applySquare(e, "healthFill", fill.x, fill.y, fill.w, fill.h,
                        barColor, tex(cfg.HealthBarTransparency), true, 1)
                    if cfg.HealthBarOutline then
                        applySquare(e, "healthBorder", bg.x, bg.y, bg.w, bg.h,
                            Color3.new(0, 0, 0), 0.3, false, 1)
                    else
                        hideDrawing(e.healthBorder)
                    end
                else
                    hideDrawing(e.healthBg); hideDrawing(e.healthFill); hideDrawing(e.healthBorder)
                end

                if cfg.Health and (cfg.HealthStyle == "Text" or cfg.HealthStyle == "Both") then
                    local hx, hy = textCenter(cfg.HealthTextAnchor, rect,
                        cfg.HealthTextOffsetX, cfg.HealthTextOffsetY)
                    local text = formatHealthText(cfg.HealthTextFormat, t.health, t.maxHealth)
                    local txtColor = ESPUI.colorFor(cfg.HealthTextColorMode,
                        cfg.HealthTextR, cfg.HealthTextG, cfg.HealthTextB, t.teamColor, hue, frac)
                    applyText(e, "healthText", hx, hy, text, cfg.HealthTextSize, txtColor, cfg.HealthTextOutline)
                else
                    hideDrawing(e.healthText)
                end

                -- Distance
                if cfg.Distance then
                    local dx, dy = textCenter(cfg.DistanceAnchor, rect, cfg.DistanceOffsetX, cfg.DistanceOffsetY)
                    local distColor = ESPUI.colorFor(cfg.DistanceColorMode,
                        cfg.DistanceR, cfg.DistanceG, cfg.DistanceB, nil, hue)
                    applyText(e, "dist", dx, dy, formatDistance(cfg, t.distance),
                        cfg.DistanceSize, distColor, cfg.DistanceOutline)
                else
                    hideDrawing(e.dist)
                end

                -- Tracer
                if cfg.Tracers then
                    local origin
                    if cfg.TracerOrigin == "Mouse" and mouse then
                        origin = mouse
                    elseif cfg.TracerOrigin == "Top" then
                        origin = Vector2.new(viewport.X / 2, 0)
                    elseif cfg.TracerOrigin == "Left" then
                        origin = Vector2.new(0, viewport.Y / 2)
                    elseif cfg.TracerOrigin == "Right" then
                        origin = Vector2.new(viewport.X, viewport.Y / 2)
                    else
                        origin = Vector2.new(viewport.X / 2, viewport.Y)
                    end
                    origin = origin + Vector2.new(cfg.TracerOffsetX, cfg.TracerOffsetY)
                    local tracerColor = ESPUI.colorFor(cfg.TracerColorMode,
                        cfg.TracerR, cfg.TracerG, cfg.TracerB, t.teamColor, hue)
                    applyLine(e, "tracer", origin.X, origin.Y,
                        rect.x + rect.w / 2, rect.y + rect.h,
                        tracerColor, cfg.TracerThickness, tex(cfg.TracerTransparency))
                else
                    hideDrawing(e.tracer)
                end

                -- Head dot
                if cfg.HeadDot then
                    local hp = cam:WorldToViewportPoint(t.headPos)
                    local o = getObj(e, "headDot", function()
                        local c = Drawing.new("Circle")
                        c.Filled = true
                        c.NumSides = 20
                        return c
                    end)
                    if o then
                        if hp.Z > 0 then
                            o.Visible = true
                            o.Position = Vector2.new(hp.X, hp.Y)
                            o.Radius = cfg.HeadDotSize
                            o.Color = ESPUI.colorFor(cfg.HeadDotColorMode,
                                cfg.HeadDotR, cfg.HeadDotG, cfg.HeadDotB, t.teamColor, hue)
                            o.Transparency = 0
                        else
                            o.Visible = false
                        end
                    end
                else
                    hideDrawing(e.headDot)
                end

                -- Skeleton
                if cfg.Skeleton and t.skel then
                    local joints = {}
                    for j, world in pairs(t.skel) do
                        local sp = cam:WorldToViewportPoint(world)
                        if sp.Z > 0 then joints[j] = sp end
                    end
                    e.skel = e.skel or {}
                    local skelColor = ESPUI.colorFor(cfg.SkeletonColorMode,
                        cfg.SkeletonR, cfg.SkeletonG, cfg.SkeletonB, t.teamColor, hue)
                    for li, pair in ipairs(SKEL_PAIRS) do
                        local a, b = joints[pair[1]], joints[pair[2]]
                        if a and b then
                            local ln = e.skel[li]
                            if not ln then
                                ln = getObj(e, "skelLine" .. li, function()
                                    return Drawing.new("Line")
                                end)
                                e.skel[li] = ln
                            end
                            if ln then
                                ln.Visible = true
                                ln.From = Vector2.new(a.X, a.Y)
                                ln.To = Vector2.new(b.X, b.Y)
                                ln.Color = skelColor
                                ln.Thickness = cfg.SkeletonThickness
                                ln.Transparency = tex(cfg.SkeletonTransparency)
                            end
                        elseif e.skel[li] then
                            hideDrawing(e.skel[li])
                        end
                    end
                elseif e.skel then
                    for _, o in ipairs(e.skel) do hideDrawing(o) end
                end

                -- Look line
                if cfg.LookLine and t.lookDir and t.headPos then
                    local a = cam:WorldToViewportPoint(t.headPos)
                    local b = cam:WorldToViewportPoint(t.headPos + t.lookDir * cfg.LookLineLength)
                    if a.Z > 0 and b.Z > 0 then
                        local lookColor = ESPUI.colorFor(cfg.LookLineColorMode,
                            cfg.LookLineR, cfg.LookLineG, cfg.LookLineB, t.teamColor, hue)
                        applyLine(e, "lookLine", a.X, a.Y, b.X, b.Y,
                            lookColor, cfg.LookLineThickness, tex(cfg.LookLineTransparency))
                    else
                        hideDrawing(e.lookLine)
                    end
                else
                    hideDrawing(e.lookLine)
                end

                hideDrawing(e.arrow)
            end
        end

        -- Anything not in this frame's list: hide, and recycle after a while.
        for key, e in pairs(R.cache) do
            if not seen[key] then
                hideEntry(e)
                updateChams(e, nil, { Chams = false })
                e.misses = (e.misses or 0) + 1
                if e.misses > 300 then R:release(key) end
            end
        end
    end

    function R:clear()
        for key in pairs(R.cache) do R:release(key) end
    end

    return R
end

-- ============================================================
-- INLINE SELECTOR  (replaces floating dropdowns: the option list expands
-- INSIDE the row, so its clicks can never fall through to the window below)
-- ============================================================
local openSelector = nil  -- { close = fn } of the currently expanded one

-- File-scope local so the customizer below can call it directly; exported
-- on the table as well for host scripts (a bare call to a table-defined
-- function would be a nil global - that exact bug hid here once).
local function makeSelector(uilib, parent, label, getItems, getSelected, onSelect)
    local create, corner, stroke, tween = uilib.create, uilib.corner, uilib.stroke, uilib.tween
    local THEME, FONTS = uilib.THEME, uilib.FONTS
    local ITEM_H, GAP = 24, 2

    -- Build on uilib's own row: correct styling and page layout order for
    -- free, with no probe/destroy tricks in between.
    local row = uilib.makeRow(parent, 30)

    create("TextLabel", {
        Size = UDim2.new(1, -164, 1, 0),
        Position = UDim2.fromOffset(12, 0),
        BackgroundTransparency = 1,
        Text = label,
        TextColor3 = THEME.TEXT,
        TextSize = 12,
        Font = FONTS.MEDIUM,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = row,
    })

    local valueChip = create("Frame", {
        Size = UDim2.fromOffset(128, 22),
        Position = UDim2.new(1, -140, 0.5, -11),
        BackgroundColor3 = THEME.PANEL_HI,
        BorderSizePixel = 0,
        Parent = row,
    })
    corner(valueChip, 4); stroke(valueChip, THEME.STROKE)
    local valueLbl = create("TextLabel", {
        Size = UDim2.new(1, -26, 1, 0),
        Position = UDim2.fromOffset(8, 0),
        BackgroundTransparency = 1,
        Text = "—",
        TextColor3 = THEME.TEXT,
        TextSize = 11,
        Font = FONTS.MEDIUM,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = valueChip,
    })
    local arrow = create("TextLabel", {
        Size = UDim2.fromOffset(12, 22),
        Position = UDim2.new(1, -18, 0, 0),
        BackgroundTransparency = 1,
        Text = "▼",
        TextColor3 = THEME.TEXT_DIM,
        TextSize = 8,
        TextXAlignment = Enum.TextXAlignment.Center,
        Parent = valueChip,
    })

    -- The expanding list, clipped by this body while the row tweens open.
    local body = create("Frame", {
        Size = UDim2.new(1, -16, 0, 0),
        Position = UDim2.fromOffset(8, 34),
        BackgroundTransparency = 1,
        ClipsDescendants = true,
        Visible = false,
        Parent = row,
    })
    create("UIListLayout", {
        Padding = UDim.new(0, GAP),
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent = body,
    })

    local headHit = create("TextButton", {
        Size = UDim2.new(1, 0, 0, 30),
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Text = "",
        Parent = row,
    })

    local itemButtons, itemNames = {}, {}
    local open = false
    local collapse

    local function update()
        local sel = getSelected()
        local text = (sel ~= nil and sel ~= "") and tostring(sel) or "—"
        if valueLbl.Text ~= text then valueLbl.Text = text end
        if open then
            for i, b in ipairs(itemButtons) do
                b.BackgroundColor3 = (itemNames[i] == sel) and THEME.ACCENT or THEME.PANEL_HI
            end
        end
    end

    local function buildItems()
        for _, b in ipairs(itemButtons) do b:Destroy() end
        itemButtons, itemNames = {}, {}
        local items = getItems() or {}
        for i, name in ipairs(items) do
            local isSel = (name == getSelected())
            local b = create("TextButton", {
                Size = UDim2.new(1, 0, 0, ITEM_H),
                LayoutOrder = i,
                BackgroundColor3 = isSel and THEME.ACCENT or THEME.PANEL_HI,
                BorderSizePixel = 0,
                AutoButtonColor = false,
                Text = tostring(name),
                TextColor3 = THEME.TEXT,
                TextSize = 11,
                Font = FONTS.MEDIUM,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
                Parent = body,
            })
            corner(b, 4)
            create("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 6), Parent = b })
            b.MouseButton1Click:Connect(function()
                onSelect(name)
                collapse()
                update()
            end)
            itemButtons[i] = b
            itemNames[i] = name
        end
        return #items
    end

    collapse = function()
        if not open then return end
        open = false
        body.Visible = false
        tween(row, 0.15, { Size = UDim2.new(1, 0, 0, 30) })
        tween(arrow, 0.12, { Rotation = 0 })
        if openSelector and openSelector.close == collapse then openSelector = nil end
    end

    local function expand()
        if openSelector and openSelector.close ~= collapse then
            openSelector.close()
        end
        local n = buildItems()
        if n == 0 then return end
        local h = n * ITEM_H + math.max(n - 1, 0) * GAP + 8
        body.Size = UDim2.new(1, -16, 0, h)
        body.Visible = true
        open = true
        openSelector = { close = collapse }
        tween(row, 0.15, { Size = UDim2.new(1, 0, 0, 40 + h) })
        tween(arrow, 0.12, { Rotation = 180 })
    end

    headHit.MouseButton1Click:Connect(function()
        if open then collapse() else expand() end
    end)
    headHit.MouseEnter:Connect(function() tween(row, 0.1, { BackgroundColor3 = THEME.PANEL_HI }) end)
    headHit.MouseLeave:Connect(function() tween(row, 0.1, { BackgroundColor3 = THEME.PANEL }) end)

    pcall(update)
    return { update = update, row = row, searchText = label }
end
ESPUI.makeSelector = makeSelector

-- ============================================================
-- CUSTOMIZER UI  (preview window + settings window)
-- ============================================================
local OPEN = { ui = nil }

local function buildPreviewWindow(ctx, THEME, FONTS)
    local UILib = ctx.uilib
    local cfg = ctx.cfg
    local create, corner, stroke = UILib.create, UILib.corner, UILib.stroke

    local preview = create("Frame", {
        Name = "ESPPreview",
        Size = UDim2.new(0, 300, 0, 430),
        Position = UDim2.new(0, 604, 0, 40),
        BackgroundColor3 = THEME.BG,
        BorderSizePixel = 0,
        Active = true,
        Draggable = true,
        ZIndex = 20,
        Parent = ctx.screenGui,
    })
    corner(preview, 10); stroke(preview, THEME.STROKE)

    local header = create("Frame", {
        Size = UDim2.new(1, 0, 0, 36),
        BackgroundColor3 = THEME.HEADER,
        BorderSizePixel = 0,
        Parent = preview,
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
        Parent = preview,
    })
    create("TextLabel", {
        Size = UDim2.new(1, -60, 1, 0),
        Position = UDim2.fromOffset(14, 0),
        BackgroundTransparency = 1,
        Text = "ESP PREVIEW",
        TextColor3 = THEME.TEXT,
        TextSize = 13,
        Font = FONTS.BOLD,
        TextXAlignment = Enum.TextXAlignment.Left,
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
    closeBtn.MouseButton1Click:Connect(function() preview.Visible = false end)

    local vp = create("ViewportFrame", {
        Size = UDim2.new(1, -16, 0, 310),
        Position = UDim2.fromOffset(8, 44),
        BackgroundColor3 = Color3.fromRGB(24, 24, 30),
        BorderSizePixel = 0,
        ZIndex = 1,
        Parent = preview,
    })
    corner(vp, 8); stroke(vp, THEME.STROKE)

    local vpCam = create("Camera", {})

    -- Overlay: every ESP element, drawn over the viewport like it would be
    -- over the game.
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
        local char = Players.LocalPlayer.Character
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
    -- WorldToViewportPoint to frame pixels, so the overlay projection below
    -- is done manually with this camera instead.
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

    -- Element frames (positioned every update from the shared layout math).
    local el = {}
    local function mkFrame(extra)
        local f = create("Frame", extra)
        f.Visible = false
        return f
    end
    local function mkLabel(extra)
        local l = create("TextLabel", extra)
        l.BackgroundTransparency = 1
        l.AnchorPoint = Vector2.new(0.5, 0.5)
        l.Font = FONTS.MEDIUM
        l.Visible = false
        return l
    end

    el.fill = mkFrame({ BorderSizePixel = 0, BackgroundColor3 = THEME.PANEL, Parent = overlay })
    corner(el.fill, 2)
    el.strokeFrame = mkFrame({ BackgroundTransparency = 1, Parent = overlay })
    el.stroke = UILib.stroke(el.strokeFrame, THEME.TEXT)
    el.corners = {}
    for i = 1, 8 do
        el.corners[i] = mkFrame({ BorderSizePixel = 0, BackgroundColor3 = THEME.TEXT, Parent = overlay })
    end
    el.name = mkLabel({ Text = "DemoPlayer", TextSize = 13, Parent = overlay })
    el.nameStroke = stroke(el.name, Color3.new(0, 0, 0))
    el.dist = mkLabel({ Text = "42m", TextSize = 12, Parent = overlay })
    el.distStroke = stroke(el.dist, Color3.new(0, 0, 0))
    el.healthBg = mkFrame({ BorderSizePixel = 0, BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.5, Parent = overlay })
    el.healthFill = mkFrame({ BorderSizePixel = 0, BackgroundColor3 = THEME.GREEN, Parent = overlay })
    el.healthBorder = mkFrame({ BackgroundTransparency = 1, Parent = overlay })
    el.healthBorderStroke = stroke(el.healthBorder, Color3.new(0, 0, 0))
    el.healthText = mkLabel({ Text = "72", TextSize = 11, Parent = overlay })
    el.healthTextStroke = stroke(el.healthText, Color3.new(0, 0, 0))
    el.dot = mkFrame({ BorderSizePixel = 0, Parent = overlay })
    corner(el.dot, UDim.new(0.5, 0))
    el.tracer = mkFrame({ BorderSizePixel = 0, Parent = overlay })
    el.skel = {}
    for i = 1, 5 do
        el.skel[i] = mkFrame({ BorderSizePixel = 0, Parent = overlay })
    end

    local function placeLine(frame, ax, ay, bx, by, thickness, color, transparency)
        local dx, dy = bx - ax, by - ay
        local len = math.sqrt(dx * dx + dy * dy)
        frame.AnchorPoint = Vector2.new(0, 0.5)
        frame.Position = UDim2.fromOffset(ax, ay)
        frame.Size = UDim2.fromOffset(len, thickness)
        frame.Rotation = math.deg(math.atan2(dy, dx))
        frame.BackgroundColor3 = color
        frame.BackgroundTransparency = transparency
    end

    local function updatePreview()
        local lp = Players.LocalPlayer
        local demoTeam = (lp.Team and lp.Team.TeamColor.Color) or Color3.fromRGB(255, 80, 80)
        local now = os.clock() * 0.18 * (cfg.RainbowSpeed or 1)

        -- Box rect: project the dummy's bounding box through the preview
        -- camera (manual pinhole projection - ViewportFrame cameras don't
        -- map WorldToViewportPoint to frame pixels).
        local rect
        if modelCF and modelSize then
            local top = projectPoint(modelCF.Position + Vector3.new(0, modelSize.Y / 2, 0))
            local bot = projectPoint(modelCF.Position - Vector3.new(0, modelSize.Y / 2, 0))
            if top and bot then
                local h = math.max(bot.Y - top.Y, 40)
                local w = h * (modelSize.X / math.max(modelSize.Y, 0.01))
                rect = { x = (top.X + bot.X) / 2 - w / 2, y = top.Y, w = w, h = h }
            end
        end
        if not rect then
            local szp = vp.AbsoluteSize
            local h = math.max(szp.Y * 0.62, 60)
            local w = h * 0.55
            rect = { x = szp.X / 2 - w / 2, y = szp.Y * 0.16, w = w, h = h }
        end

        local style = cfg.BoxStyle
        local boxColor = ESPUI.colorFor(cfg.BoxColorMode, cfg.BoxR, cfg.BoxG, cfg.BoxB, demoTeam, now)

        -- Box
        local showFill = cfg.Box and (style == "Fill" or (style == "Full" and cfg.BoxFill))
        el.fill.Visible = showFill
        if showFill then
            el.fill.Position = UDim2.fromOffset(rect.x, rect.y)
            el.fill.Size = UDim2.fromOffset(rect.w, rect.h)
            el.fill.BackgroundColor3 = boxColor
            el.fill.BackgroundTransparency = tex(cfg.BoxFillTransparency)
        end
        local showOutline = cfg.Box and cfg.BoxOutline and style ~= "Corners"
        el.strokeFrame.Visible = showOutline
        if showOutline then
            el.strokeFrame.Position = UDim2.fromOffset(rect.x, rect.y)
            el.strokeFrame.Size = UDim2.fromOffset(rect.w, rect.h)
            el.stroke.Color = boxColor
            el.stroke.Thickness = cfg.BoxThickness
            el.stroke.Transparency = tex(cfg.BoxTransparency)
        end
        local showCorners = cfg.Box and style == "Corners"
        if showCorners then
            local specs = cornerSpecs(rect, cfg.BoxCornerLength, cfg.BoxThickness)
            for i = 1, 8 do
                local c = el.corners[i]
                local s = specs[i]
                c.Visible = true
                c.Position = UDim2.fromOffset(s[1], s[2])
                c.Size = UDim2.fromOffset(s[3], s[4])
                c.BackgroundColor3 = boxColor
                c.BackgroundTransparency = tex(cfg.BoxTransparency)
            end
        else
            for i = 1, 8 do el.corners[i].Visible = false end
        end

        -- Name
        el.name.Visible = cfg.Name
        if cfg.Name then
            local text = "DemoPlayer"
            if cfg.NameShowHealth then text = text .. " [72]" end
            el.name.Text = text
            el.name.TextSize = cfg.NameSize
            el.name.TextColor3 = ESPUI.colorFor(cfg.NameColorMode,
                cfg.NameR, cfg.NameG, cfg.NameB, demoTeam, now)
            el.nameStroke.Enabled = cfg.NameOutline and true or false
            local nx, ny = textCenter(cfg.NameAnchor, rect, cfg.NameOffsetX, cfg.NameOffsetY)
            el.name.Position = UDim2.fromOffset(nx, ny)
        end

        -- Health (demo: 72 / 100)
        local frac = 0.72
        local showBar = cfg.Health and (cfg.HealthStyle == "Bar" or cfg.HealthStyle == "Both")
        el.healthBg.Visible = showBar
        el.healthFill.Visible = showBar
        el.healthBorder.Visible = showBar and cfg.HealthBarOutline
        if showBar then
            local bg, fill = healthBarRects(cfg, rect, frac)
            local barColor = ESPUI.colorFor(cfg.HealthColorMode,
                cfg.HealthR, cfg.HealthG, cfg.HealthB, demoTeam, now, frac)
            el.healthBg.Position = UDim2.fromOffset(bg.x, bg.y)
            el.healthBg.Size = UDim2.fromOffset(bg.w, bg.h)
            el.healthFill.Position = UDim2.fromOffset(fill.x, fill.y)
            el.healthFill.Size = UDim2.fromOffset(fill.w, fill.h)
            el.healthFill.BackgroundColor3 = barColor
            el.healthFill.BackgroundTransparency = tex(cfg.HealthBarTransparency)
            el.healthBorder.Position = UDim2.fromOffset(bg.x, bg.y)
            el.healthBorder.Size = UDim2.fromOffset(bg.w, bg.h)
        end
        local showHealthText = cfg.Health and (cfg.HealthStyle == "Text" or cfg.HealthStyle == "Both")
        el.healthText.Visible = showHealthText
        if showHealthText then
            el.healthText.Text = formatHealthText(cfg.HealthTextFormat, 72, 100)
            el.healthText.TextSize = cfg.HealthTextSize
            el.healthText.TextColor3 = ESPUI.colorFor(cfg.HealthTextColorMode,
                cfg.HealthTextR, cfg.HealthTextG, cfg.HealthTextB, demoTeam, now, frac)
            el.healthTextStroke.Enabled = cfg.HealthTextOutline and true or false
            local hx, hy = textCenter(cfg.HealthTextAnchor, rect, cfg.HealthTextOffsetX, cfg.HealthTextOffsetY)
            el.healthText.Position = UDim2.fromOffset(hx, hy)
        end

        -- Distance
        el.dist.Visible = cfg.Distance
        if cfg.Distance then
            el.dist.Text = formatDistance(cfg, 42)
            el.dist.TextSize = cfg.DistanceSize
            el.dist.TextColor3 = ESPUI.colorFor(cfg.DistanceColorMode,
                cfg.DistanceR, cfg.DistanceG, cfg.DistanceB, nil, now)
            el.distStroke.Enabled = cfg.DistanceOutline and true or false
            local dx, dy = textCenter(cfg.DistanceAnchor, rect, cfg.DistanceOffsetX, cfg.DistanceOffsetY)
            el.dist.Position = UDim2.fromOffset(dx, dy)
        end

        -- Tracer (origin mirrors the in-game screen edges inside the preview)
        el.tracer.Visible = cfg.Tracers
        if cfg.Tracers then
            local ax, ay
            local szp = vp.AbsoluteSize
            if cfg.TracerOrigin == "Top" then ax, ay = szp.X / 2, 0
            elseif cfg.TracerOrigin == "Left" then ax, ay = 0, szp.Y / 2
            elseif cfg.TracerOrigin == "Right" then ax, ay = szp.X, szp.Y / 2
            else ax, ay = szp.X / 2, szp.Y end
            ax, ay = ax + cfg.TracerOffsetX, ay + cfg.TracerOffsetY
            local tracerColor = ESPUI.colorFor(cfg.TracerColorMode,
                cfg.TracerR, cfg.TracerG, cfg.TracerB, demoTeam, now)
            placeLine(el.tracer, ax, ay, rect.x + rect.w / 2, rect.y + rect.h,
                cfg.TracerThickness, tracerColor, tex(cfg.TracerTransparency))
        end

        -- Head dot
        el.dot.Visible = cfg.HeadDot
        if cfg.HeadDot then
            local d = cfg.HeadDotSize
            el.dot.Size = UDim2.fromOffset(d * 2, d * 2)
            el.dot.Position = UDim2.fromOffset(rect.x + rect.w / 2, rect.y + rect.h * 0.08)
            el.dot.BackgroundColor3 = ESPUI.colorFor(cfg.HeadDotColorMode,
                cfg.HeadDotR, cfg.HeadDotG, cfg.HeadDotB, demoTeam, now)
        end

        -- Skeleton (approximate joints in box space)
        for i = 1, 5 do el.skel[i].Visible = cfg.Skeleton end
        if cfg.Skeleton then
            local jx = rect.x + rect.w / 2
            local joints = {
                Head = { jx, rect.y + rect.h * 0.08 },
                Torso = { jx, rect.y + rect.h * 0.30 },
                LeftHand = { rect.x + rect.w * 0.05, rect.y + rect.h * 0.52 },
                RightHand = { rect.x + rect.w * 0.95, rect.y + rect.h * 0.52 },
                LeftFoot = { rect.x + rect.w * 0.28, rect.y + rect.h * 0.98 },
                RightFoot = { rect.x + rect.w * 0.72, rect.y + rect.h * 0.98 },
            }
            local skelColor = ESPUI.colorFor(cfg.SkeletonColorMode,
                cfg.SkeletonR, cfg.SkeletonG, cfg.SkeletonB, demoTeam, now)
            for i, pair in ipairs(SKEL_PAIRS) do
                local a, b = joints[pair[1]], joints[pair[2]]
                placeLine(el.skel[i], a[1], a[2], b[1], b[2],
                    cfg.SkeletonThickness, skelColor, tex(cfg.SkeletonTransparency))
            end
        end
    end

    RunService.RenderStepped:Connect(function()
        if preview.Visible then
            pcall(updatePreview)
        end
    end)

    return preview
end

local function buildOptionsWindow(ctx, THEME, FONTS)
    local UILib = ctx.uilib
    local cfg = ctx.cfg
    local create, corner, stroke = UILib.create, UILib.corner, UILib.stroke

    local options = create("Frame", {
        Name = "ESPCustomizer",
        Size = UDim2.new(0, 560, 0, 470),
        Position = UDim2.new(0, 30, 0, 40),
        BackgroundColor3 = THEME.BG,
        BorderSizePixel = 0,
        Active = true,
        Draggable = true,
        -- Above the preview window (20): dropdown lists live in here, so
        -- this window must win both render order and pointer priority when
        -- the two are dragged over each other.
        ZIndex = 21,
        Parent = ctx.screenGui,
    })
    corner(options, 10); stroke(options, THEME.STROKE)

    local header = create("Frame", {
        Size = UDim2.new(1, 0, 0, 36),
        BackgroundColor3 = THEME.HEADER,
        BorderSizePixel = 0,
        Parent = options,
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
        Parent = options,
    })
    create("TextLabel", {
        Size = UDim2.new(1, -60, 1, 0),
        Position = UDim2.fromOffset(14, 0),
        BackgroundTransparency = 1,
        Text = "ESP CUSTOMIZER",
        TextColor3 = THEME.TEXT,
        TextSize = 13,
        Font = FONTS.BOLD,
        TextXAlignment = Enum.TextXAlignment.Left,
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
    closeBtn.MouseButton1Click:Connect(function() options.Visible = false end)

    -- Tabs + pages
    local tabDefs = { "Box", "Name", "Health", "Distance", "Extras", "Filters" }
    local tabRail = create("Frame", {
        Size = UDim2.new(1, -24, 0, 30),
        Position = UDim2.new(0, 12, 0, 46),
        BackgroundColor3 = THEME.RAIL,
        BorderSizePixel = 0,
        Parent = options,
    })
    corner(tabRail, 8); stroke(tabRail, THEME.STROKE)
    create("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        Padding = UDim.new(0, 4),
        VerticalAlignment = Enum.VerticalAlignment.Center,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent = tabRail,
    })
    create("UIPadding", { PaddingLeft = UDim.new(0, 4), Parent = tabRail })

    local pages, tabButtons = {}, {}
    for i, name in ipairs(tabDefs) do
        local page = create("ScrollingFrame", {
            Size = UDim2.new(1, -24, 1, -104),
            Position = UDim2.new(0, 12, 0, 84),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            ScrollBarThickness = 5,
            ScrollBarImageColor3 = THEME.STROKE,
            ScrollBarImageTransparency = 0.2,
            CanvasSize = UDim2.new(0, 0, 0, 0),
            AutomaticCanvasSize = Enum.AutomaticSize.Y,
            Visible = false,
            Parent = options,
        })
        create("UIListLayout", {
            Padding = UDim.new(0, 6),
            SortOrder = Enum.SortOrder.LayoutOrder,
            Parent = page,
        })
        create("UIPadding", { PaddingBottom = UDim.new(0, 10), Parent = page })
        pages[i] = page

        local btn = create("TextButton", {
            Size = UDim2.fromOffset(84, 22),
            LayoutOrder = i,
            BackgroundColor3 = THEME.PANEL,
            BorderSizePixel = 0,
            AutoButtonColor = false,
            Text = name,
            TextColor3 = THEME.TEXT,
            TextSize = 11,
            Font = FONTS.MEDIUM,
            Parent = tabRail,
        })
        corner(btn, 6)
        tabButtons[i] = btn
    end

    -- Dropdown lists are parented to this layer instead of straight to the
    -- window (see the `dropdown` helper below). Sitting at the top of the
    -- window's ZIndex stack, an open list can never be covered by any other
    -- control - its items always win the pointer.
    local popupLayer = create("Frame", {
        Name = "PopupLayer",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Active = false,
        ZIndex = 100,
        Parent = options,
    })

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

    local controls = {}
    local function refresh()
        for _, e in ipairs(controls) do
            if e.update then pcall(e.update) end
        end
    end
    local function reg(e) table.insert(controls, e); return e end
    -- Every widget goes through a labelled pcall: one bad row must never
    -- empty a whole tab, and the console names exactly what failed.
    local function guard(what, fn)
        local ok, e = pcall(fn)
        if ok and type(e) == "table" then
            reg(e)
            return e
        end
        warn(("[espui] widget '%s' failed: %s"):format(what, tostring(e)))
        return nil
    end
    local function section(page, text)
        guard("section " .. text, function() return UILib.makeSectionHeader(page, text) end)
    end
    local function toggle(page, text, key)
        guard("toggle " .. text, function()
            return UILib.makeToggle(page, text,
                function() return cfg[key] end,
                function(v) cfg[key] = v end)
        end)
    end
    local function slider(page, text, key, step, min, max)
        guard("slider " .. text, function()
            return UILib.makeSlider(page, text,
                function() return cfg[key] end,
                function(v) cfg[key] = v end, step, min, max)
        end)
    end
    local function dropdown(page, text, key, items)
        guard("dropdown " .. text, function()
            return UILib.makeDropdown(page, text,
                function() return items end,
                function() return cfg[key] end,
                function(v)
                    cfg[key] = v
                    -- uilib dropdowns don't auto-save (host-owned, unlike
                    -- toggles and sliders) - persist the pick here.
                    if ctx.save then pcall(ctx.save) end
                end,
                popupLayer)
        end)
    end
    local function colorpicker(page, text, prefix)
        guard("colour picker " .. text, function()
            return UILib.makeColorPicker(page, text, cfg, prefix)
        end)
    end
    local function note(page, text)
        pcall(function() UILib.makeNote(page, text, "auto") end)
    end

    local ANCHORS = { "Above", "Below", "Inside", "Left", "Right" }
    local MODES3 = { "Static", "Team", "Rainbow" }
    local HEALTH_MODES = { "Gradient", "Static", "Team", "Rainbow" }

    -- ---------------- Box ----------------
    local p1 = pages[1]
    section(p1, "Box")
    toggle(p1, "Box enabled", "Box")
    dropdown(p1, "Style", "BoxStyle", { "Full", "Corners", "Fill" })
    toggle(p1, "Outline", "BoxOutline")
    toggle(p1, "Fill", "BoxFill")
    slider(p1, "Thickness", "BoxThickness", 1, 1, 4)
    slider(p1, "Opacity", "BoxTransparency", 0.05, 0.05, 1)
    slider(p1, "Fill opacity", "BoxFillTransparency", 0.05, 0, 1)
    slider(p1, "Corner length", "BoxCornerLength", 1, 2, 20)
    dropdown(p1, "Colour mode", "BoxColorMode", MODES3)
    colorpicker(p1, "Box colour", "Box")
    note(p1, "Corners style draws four corner brackets and ignores fill/outline.")

    -- ---------------- Name ----------------
    local p2 = pages[2]
    section(p2, "Name")
    toggle(p2, "Name enabled", "Name")
    dropdown(p2, "Position", "NameAnchor", ANCHORS)
    slider(p2, "Offset X", "NameOffsetX", 1, -100, 100)
    slider(p2, "Offset Y", "NameOffsetY", 1, -100, 100)
    slider(p2, "Text size", "NameSize", 1, 8, 20)
    dropdown(p2, "Source", "NameSource", { "Username", "DisplayName" })
    toggle(p2, "Show health suffix", "NameShowHealth")
    toggle(p2, "Outline", "NameOutline")
    dropdown(p2, "Colour mode", "NameColorMode", MODES3)
    colorpicker(p2, "Name colour", "Name")

    -- ---------------- Health ----------------
    local p3 = pages[3]
    section(p3, "Health")
    toggle(p3, "Health enabled", "Health")
    dropdown(p3, "Style", "HealthStyle", { "Bar", "Text", "Both" })
    section(p3, "Health bar")
    dropdown(p3, "Bar position", "HealthBarAnchor", { "Left", "Right", "Top", "Bottom" })
    slider(p3, "Bar width", "HealthBarWidth", 1, 1, 6)
    slider(p3, "Bar height (0 = box height)", "HealthBarHeight", 2, 0, 120)
    toggle(p3, "Bar outline", "HealthBarOutline")
    slider(p3, "Bar opacity", "HealthBarTransparency", 0.05, 0.05, 1)
    dropdown(p3, "Bar colour mode", "HealthColorMode", HEALTH_MODES)
    colorpicker(p3, "Bar colour (Static mode)", "Health")
    section(p3, "Health text")
    dropdown(p3, "Text position", "HealthTextAnchor", ANCHORS)
    slider(p3, "Text offset X", "HealthTextOffsetX", 1, -100, 100)
    slider(p3, "Text offset Y", "HealthTextOffsetY", 1, -100, 100)
    slider(p3, "Text size", "HealthTextSize", 1, 8, 18)
    dropdown(p3, "Text format", "HealthTextFormat", { "Value", "Percent", "Value/Max" })
    toggle(p3, "Text outline", "HealthTextOutline")
    dropdown(p3, "Text colour mode", "HealthTextColorMode", HEALTH_MODES)
    colorpicker(p3, "Text colour (Static mode)", "HealthText")

    -- ---------------- Distance ----------------
    local p4 = pages[4]
    section(p4, "Distance")
    toggle(p4, "Distance enabled", "Distance")
    dropdown(p4, "Position", "DistanceAnchor", ANCHORS)
    slider(p4, "Offset X", "DistanceOffsetX", 1, -100, 100)
    slider(p4, "Offset Y", "DistanceOffsetY", 1, -100, 100)
    slider(p4, "Text size", "DistanceSize", 1, 8, 20)
    dropdown(p4, "Unit", "DistanceUnit", { "Meters", "Studs", "Km" })
    slider(p4, "Decimals", "DistanceDecimals", 1, 0, 2)
    toggle(p4, "Outline", "DistanceOutline")
    dropdown(p4, "Colour mode", "DistanceColorMode", { "Static", "Rainbow" })
    colorpicker(p4, "Distance colour", "Distance")

    -- ---------------- Extras ----------------
    local p5 = pages[5]
    section(p5, "Tracers")
    toggle(p5, "Tracers enabled", "Tracers")
    dropdown(p5, "Origin", "TracerOrigin", { "Bottom", "Top", "Left", "Right", "Mouse" })
    slider(p5, "Origin offset X", "TracerOffsetX", 1, -200, 200)
    slider(p5, "Origin offset Y", "TracerOffsetY", 1, -200, 200)
    slider(p5, "Thickness", "TracerThickness", 1, 1, 3)
    slider(p5, "Opacity", "TracerTransparency", 0.05, 0, 1)
    dropdown(p5, "Colour mode", "TracerColorMode", MODES3)
    colorpicker(p5, "Tracer colour", "Tracer")

    section(p5, "Head dot")
    toggle(p5, "Head dot enabled", "HeadDot")
    slider(p5, "Dot size", "HeadDotSize", 1, 2, 10)
    dropdown(p5, "Colour mode", "HeadDotColorMode", MODES3)
    colorpicker(p5, "Dot colour", "HeadDot")

    section(p5, "Skeleton")
    toggle(p5, "Skeleton enabled", "Skeleton")
    slider(p5, "Thickness", "SkeletonThickness", 1, 1, 3)
    slider(p5, "Opacity", "SkeletonTransparency", 0.05, 0, 1)
    dropdown(p5, "Colour mode", "SkeletonColorMode", MODES3)
    colorpicker(p5, "Skeleton colour", "Skeleton")

    section(p5, "Look line")
    toggle(p5, "Look line enabled", "LookLine")
    slider(p5, "Length", "LookLineLength", 5, 10, 200)
    slider(p5, "Thickness", "LookLineThickness", 1, 1, 3)
    slider(p5, "Opacity", "LookLineTransparency", 0.05, 0, 1)
    dropdown(p5, "Colour mode", "LookLineColorMode", MODES3)
    colorpicker(p5, "Look line colour", "LookLine")

    section(p5, "Off-screen arrows")
    toggle(p5, "Arrows enabled", "Arrow")
    slider(p5, "Arrow size", "ArrowSize", 1, 4, 24)
    slider(p5, "Radius from centre", "ArrowRadius", 5, 40, 400)
    slider(p5, "Thickness", "ArrowThickness", 1, 1, 3)
    slider(p5, "Opacity", "ArrowTransparency", 0.05, 0, 1)
    dropdown(p5, "Colour mode", "ArrowColorMode", MODES3)
    colorpicker(p5, "Arrow colour", "Arrow")

    section(p5, "Chams (Highlight)")
    toggle(p5, "Chams enabled", "Chams")
    toggle(p5, "Always on top", "ChamsAlwaysOnTop")
    slider(p5, "Fill opacity", "ChamsFillTransparency", 0.05, 0, 1)
    colorpicker(p5, "Fill colour", "ChamsFill")
    slider(p5, "Outline opacity", "ChamsOutlineTransparency", 0.05, 0, 1)
    colorpicker(p5, "Outline colour", "ChamsOutline")
    note(p5, "Chams can't render inside the preview window - check them in-game.")

    -- ---------------- Filters ----------------
    local p6 = pages[6]
    section(p6, "Targeting")
    toggle(p6, "Team check", "TeamCheck")
    toggle(p6, "Visible only (raycast)", "VisibleOnly")
    slider(p6, "Max distance", "MaxDistance", 100, 100, 10000)
    slider(p6, "Update rate (frame skip)", "UpdateRate", 1, 1, 4)
    slider(p6, "Rainbow speed", "RainbowSpeed", 0.1, 0.1, 3)
    section(p6, "Reset")
    guard("reset button", function()
        return UILib.makeButton(p6, "Reset ESP settings to defaults", function()
            for k, v in pairs(DEFAULTS) do
                if k ~= "Enabled" then cfg[k] = v end
            end
            refresh()
            if ctx.save then pcall(ctx.save) end
            if ctx.notify then pcall(ctx.notify, "ESP settings reset to defaults") end
        end, { confirm = true, confirmText = "Click again to reset" })
    end)
    note(p6, "Every change applies live and is saved with the script's config.")

    setTab(1)
    print("[espui] settings built (" .. tostring(#controls) .. " controls)")

    return options, refresh
end

function ESPUI.open(ctx)
    if type(ctx) ~= "table" or not ctx.cfg or not ctx.uilib or not ctx.screenGui then
        return false, "espui.open needs { cfg, uilib, screenGui }"
    end
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
        warn("[espui] preview build failed: " .. tostring(previewFrame))
        previewFrame = nil
    end
    local okO, optionsFrame, refreshFn = pcall(buildOptionsWindow, ctx, THEME, FONTS)
    if not okO then
        warn("[espui] options build failed: " .. tostring(optionsFrame))
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

print(("[espui] %s loaded (opacity sliders: value = OPACITY, 1 = fully visible)"):format(ESPUI.VERSION))

return ESPUI
