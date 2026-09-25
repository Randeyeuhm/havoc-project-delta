--[[
    ============================================
    ESP CUSTOMIZER  (espui.luau)  - v17 "PD core"
    ============================================

    Thin customizer + host adapter around esp.luau - the shared engine
    ported from Project Delta's ESP. All drawing lives in the engine;
    this file only customizes and adapts it:

      - ESPUI.newRenderer(getCfg) -> { render(targets, cam, mouse) }
        Hosts keep their existing target loops (they still handle the
        raycast "Visible only" filter etc.); the adapter syncs the target
        models into the engine and renders one frame.

      - ESPUI.open{ cfg, uilib, screenGui, save?, notify? }
        Two windows: a PREVIEW (local character clone + the exact same
        corner/label maths as the engine) and the SETTINGS window
        (General / Box / Name / Health / Distance / Highlights).

    The schema lives in esp.luau: corner box (length/thickness/opacity/
    colour), name (source/size/opacity/colour), health number, distance in
    metres, head/body Highlight chams, team check, max distance.

    Opacity convention everywhere: 1 = fully visible.
]]

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

local ESPUI = {}
ESPUI.VERSION = "v17-pd-core"

-- ============================================================
-- SHARED ENGINE (esp.luau)
-- ============================================================
-- Same source lookup the game scripts use: the hub loader stashes every
-- module source in getgenv().HAVOC_HUB_SOURCES; readfile covers manual
-- runs.
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

local ESP
do
    local ok, res = pcall(function()
        local src = moduleSource("esp.luau")
        if not src then error("no source (loader stash empty, no local file)") end
        local chunk, compileErr = loadstring(src, "@esp.luau")
        if not chunk then error("compile error: " .. tostring(compileErr)) end
        return chunk()
    end)
    if ok and type(res) == "table" then
        ESP = res
    else
        warn("[espui] esp.luau not loaded (" .. tostring(res) .. ") - ESP rendering disabled")
    end
end

-- Fallback covers exactly the fields the host scripts read directly, so
-- their render loops keep working even if the engine failed to load.
local FALLBACK_DEFAULTS = {
    Enabled = false, TeamCheck = false, VisibleOnly = false,
    MaxDistance = 2000, NameSource = "Username",
}

ESPUI.DEFAULTS = (ESP and ESP.DEFAULTS) or FALLBACK_DEFAULTS

function ESPUI.fill(cfg)
    if ESP then return ESP.fill(cfg) end
    if type(cfg) == "table" then
        for k, v in pairs(FALLBACK_DEFAULTS) do
            if cfg[k] == nil then cfg[k] = v end
        end
    end
    return cfg
end

function ESPUI.sanitize(cfg)
    if ESP then return ESP.sanitize(cfg) end
    if type(cfg) == "table" then
        cfg.MaxDistance = math.clamp(tonumber(cfg.MaxDistance) or 2000, 100, 10000)
    end
    return cfg
end

function ESPUI.healthColor(frac)
    if ESP and ESP.healthColor then return ESP.healthColor(frac) end
    frac = tonumber(frac) or 1
    if frac > 0.75 then return Color3.fromRGB(82, 202, 128)
    elseif frac > 0.5 then return Color3.fromRGB(230, 210, 60)
    elseif frac > 0.25 then return Color3.fromRGB(240, 150, 50)
    else return Color3.fromRGB(235, 70, 70) end
end

local function rgb(r, g, b)
    return Color3.fromRGB(
        math.clamp(tonumber(r) or 255, 0, 255),
        math.clamp(tonumber(g) or 255, 0, 255),
        math.clamp(tonumber(b) or 255, 0, 255))
end

-- GUI frames / Highlights use standard alpha; the engine's Drawing
-- converter is its own business (see esp.luau header).
local function guiT(opacity)
    return 1 - math.clamp(tonumber(opacity) or 1, 0, 1)
end

-- ============================================================
-- HOST ADAPTER
-- ============================================================
-- Hosts keep building their target lists each frame ({key, model, ...});
-- everything visual is derived by the engine from the model itself.
function ESPUI.newRenderer(getCfg)
    local engine = ESP and ESP.new(getCfg) or nil
    local R = { cfg = getCfg, engine = engine }

    function R:render(targets, cam, mouse)
        if not engine then return end
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
        if engine then engine:Remove(key) end
    end

    function R:clear()
        if engine then engine:Clear() end
    end

    return R
end

-- ============================================================
-- DIAGNOSTICS
-- ============================================================
-- Draws one of each shape with a number for 12 seconds - whatever is
-- missing from the screenshot is what this client cannot render.
function ESPUI.primitiveTest()
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

    print(("[espui] primitive test drawn (build %s) - screenshot the numbered shapes"):format(ESPUI.VERSION))
    task.spawn(function()
        task.wait(12)
        for i = 1, #objs do
            local o = objs[i]
            pcall(function() o:Remove() end)
        end
    end)
end

-- ============================================================
-- PREVIEW WINDOW
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
            el.health.TextColor3 = ESPUI.healthColor(0.72)
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
-- SETTINGS WINDOW
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
        tabs = { "General", "Box", "Name", "Health", "Distance", "Highlights" },
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
        warn(("[espui] widget '%s' failed: %s"):format(what, tostring(e)))
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
        for k, v in pairs(ESPUI.DEFAULTS) do
            if k ~= "Enabled" then cfg[k] = v end
        end
        refresh()
        persist()
        if ctx.notify then pcall(ctx.notify, "ESP settings reset to defaults") end
    end, { confirm = true, confirmText = "Click again to reset" })
    section(p1, "Diagnostics")
    button(p1, "Drawing primitive test (12s)", function()
        ESPUI.primitiveTest()
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

    -- ---------------- Highlights ----------------
    local p6 = pages[6]
    section(p6, "Head highlight")
    toggle(p6, "Head highlight", "HeadHighlight")
    toggle(p6, "Hollow (outline only)", "HeadHighlightHollow")
    slider(p6, "Opacity", "HeadHighlightTransparency", 0.05, 0, 1)
    colorpicker(p6, "Head colour", "HeadHighlight")
    section(p6, "Body highlight")
    toggle(p6, "Body highlight", "BodyHighlight")
    toggle(p6, "Hollow (outline only)", "BodyHighlightHollow")
    slider(p6, "Opacity", "BodyHighlightTransparency", 0.05, 0, 1)
    colorpicker(p6, "Body colour", "BodyHighlight")
    note(p6, "Chams can't render in the preview window - check them in-game.")

    win.setTab(1)
    print("[espui] settings built (" .. tostring(#controls) .. " controls)")

    return options, refresh
end

-- ============================================================
-- OPEN / TOGGLE
-- ============================================================
function ESPUI.open(ctx)
    if type(ctx) ~= "table" or not ctx.cfg or not ctx.uilib or not ctx.screenGui then
        return false, "espui.open needs { cfg, uilib, screenGui }"
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

print(("[espui] %s loaded (engine: %s, opacity: 1 = fully visible)"):format(
    ESPUI.VERSION, (ESP and ESP.VERSION) or "MISSING"))
