-- Cyber's window glitch, run by Hyprland itself.
-- Loaded by ~/.config/hypr/custom/keybinds.lua ("cyber desktop" block, written by setup.sh)
-- only while Cyber is the desktop.
--
-- When a window opens or closes (or the workspace changes), Hyprland calls this code directly,
-- inside the compositor. It fills in cyber/shaders/screen-glitch.glsl with the window's rectangle
-- and switches it on as the screen shader for a fraction of a second. The shader works on the
-- finished frame, so the glitch is drawn in the same frame as the window's own pop-in / fade and
-- cannot lag behind it.
--
-- Switches: cyber/config.json  "effects": { "windows": true, "workspace": true }  (read live)
-- From outside:  hyprctl eval 'CyberGlitch.screen(0.6)'   whole screen (used after a screenshot)
-- While it plays, damage tracking is off (the shader animates every frame); it is put back after.

local HOME = os.getenv("HOME")
local DIR = HOME .. "/.local/share/cyber/cyber"
local RUNTIME = os.getenv("XDG_RUNTIME_DIR") or "/tmp"
local BORDER = 5                 -- include the focused window's corner brackets (gap 3 + line 2, hypr/corners)
local OPEN_S, CLOSE_S, SWITCH_S, RESHAPE_S = 0.285, 0.2, 0.24, 0.26

local function read(path)
    local f = io.open(path)
    if not f then return nil end
    local s = f:read("a")
    f:close()
    return s
end

local template = read(DIR .. "/shaders/screen-glitch.glsl")
if not template then return end

-- "intensity": 0..1, how strong every glitch is (same setting as the menus)
local function intensity()
    local v = tonumber(((read(DIR .. "/config.json") or ""):match('"intensity"%s*:%s*([%d.]+)')))
    return math.max(0, math.min(1, v or 0.55))
end

local function enabled(key)
    local cfg = read(DIR .. "/config.json") or ""
    return cfg:find('"' .. key .. '"%s*:%s*true') ~= nil
end

local function complain(where, err)
    local f = io.open(HOME .. "/.cache/hypr-setup/glitch.log", "a")
    if f then f:write(os.date("%F %T ") .. where .. ": " .. tostring(err) .. "\n"); f:close() end
end
-- run a handler; a mistake in here must never put an error bar on the screen
local function guarded(where, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then complain(where, err) end
    end
end

local serial, current, saved = 0, 0, nil

local function stop(id)
    if id ~= current or not saved then return end      -- a newer glitch has taken over
    hl.config({ decoration = { screen_shader = saved.shader } })
    hl.config({ debug = { damage_tracking = saved.tracking } })
    saved = nil
end

-- rects: { { x, y, w, h }, ... } in layout coordinates; mode 0 = opening, 1 = closing
local function play(rects, mon, mode, seconds, strength)
    if not mon or #rects == 0 then return end
    local scale = mon.scale or 1
    local lines = {}
    for i = 1, math.min(#rects, 8) do
        local r = rects[i]
        local x0, y0 = (r.x - mon.x) * scale, (r.y - mon.y) * scale
        local x1, y1 = x0 + r.w * scale, y0 + r.h * scale
        lines[#lines + 1] = string.format(
            "    if (p.x >= %.1f && p.x < %.1f && p.y >= %.1f && p.y < %.1f) { r = vec4(%.1f, %.1f, %.1f, %.1f); return true; }",
            x0, x1, y0, y1, x0, y0, x1, y1)
    end
    local source = template:gsub("@(%u+)@", {
        W = string.format("%.1f", mon.width), H = string.format("%.1f", mon.height),
        STRENGTH = string.format("%.3f", strength * intensity()),
        MODE = tostring(mode), SALT = string.format("%.3f", math.random() * 100),
        RECTS = table.concat(lines, "\n"),
    })

    serial = serial + 1
    local path = string.format("%s/cyber-glitch-%d.glsl", RUNTIME, serial % 4)   -- a new name each time: Hyprland reloads it
    local f = io.open(path, "w")
    if not f then return end
    f:write(source)
    f:close()

    if not saved then
        saved = { shader = hl.get_config("decoration:screen_shader") or "", tracking = hl.get_config("debug:damage_tracking") or 2 }
    end
    current = serial
    local id = serial
    hl.config({ debug = { damage_tracking = 0 } })       -- first: the shader animates over time
    hl.config({ decoration = { screen_shader = path } })
    hl.timer(guarded("stop", function() stop(id) end), { timeout = math.floor(seconds * 1000) + 60, type = "oneshot" })
end

local function rect(w)
    return { x = w.at.x - BORDER, y = w.at.y - BORDER, w = w.size.x + 2 * BORDER, h = w.size.y + 2 * BORDER }
end

-- is this window on the workspace that is showing, and not hidden under a fullscreen window?
local function showing(w)
    local ws, mon = w.workspace, w.monitor
    if not ws or not mon or not w.at or not w.size or ws.special then return false end
    local active = mon.active_workspace
    if not active or active.id ~= ws.id then return false end
    if ws.has_fullscreen then
        local fs = ws.fullscreen_window
        return fs ~= nil and fs.address == w.address
    end
    return true
end

hl.on("window.open", guarded("open", function(w)
    if w and enabled("windows") and showing(w) then play({ rect(w) }, w.monitor, 0, OPEN_S, 1.0) end
end))

-- every other window on a workspace: address -> rectangle
local function others(ws_id, except)
    local out = {}
    for _, o in ipairs(hl.get_workspace_windows(ws_id) or {}) do
        if o.address ~= except and o.at and o.size then out[o.address] = rect(o) end
    end
    return out
end

-- Closing: the neighbours grow into the freed space while the window fades, so a glitch on the
-- closed window's old rectangle would end up lying across half of a bigger window. Instead, glitch
-- the windows that change shape, at the size they end up with (that area includes the closed
-- window's): it reads as the layout re-forming. If nothing else moves (a floating window, or the
-- last one), glitch the closed window's own rectangle.
hl.on("window.close", guarded("close", function(w)
    if not (w and enabled("windows") and showing(w)) then return end
    local own, mon, ws_id, address = rect(w), w.monitor, w.workspace.id, w.address
    local before = others(ws_id, address)
    hl.timer(guarded("close", function()      -- one tick later Hyprland has re-tiled: final sizes are known
        local reshaped = {}
        for a, r in pairs(others(ws_id, address)) do
            local b = before[a]
            if b and (b.x ~= r.x or b.y ~= r.y or b.w ~= r.w or b.h ~= r.h) then reshaped[#reshaped + 1] = r end
        end
        if #reshaped > 0 then play(reshaped, mon, 0, RESHAPE_S, 0.8)
        else play({ own }, mon, 1, CLOSE_S, 1.0) end
    end), { timeout = 1, type = "oneshot" })
end))

-- workspace change: the windows of the workspace you arrive on glitch in
hl.on("workspace.active", guarded("workspace", function()
    if not enabled("workspace") then return end
    hl.timer(guarded("workspace", function()          -- one tick later: the switch has happened
        local ws = hl.get_active_workspace()
        local mon = ws and ws.monitor
        if not ws or not mon or ws.special then return end
        local rects = {}
        if ws.has_fullscreen and ws.fullscreen_window then
            rects[1] = rect(ws.fullscreen_window)
        else
            local ok, list = pcall(function() return ws:get_windows() end)
            if not ok or type(list) ~= "table" then list = hl.get_workspace_windows(ws.id) or {} end
            for _, w in ipairs(list) do
                if w.at and w.size then rects[#rects + 1] = rect(w) end
            end
        end
        play(rects, mon, 0, SWITCH_S, 0.8)
    end), { timeout = 1, type = "oneshot" })
end))

CyberGlitch = {
    -- the whole focused monitor for a moment (e.g. after a screenshot)
    screen = function(strength)
        for _, m in ipairs(hl.get_monitors()) do
            if m.focused then
                play({ { x = m.x, y = m.y, w = m.width / (m.scale or 1), h = m.height / (m.scale or 1) } }, m, 0, SWITCH_S, strength or 0.6)
                return
            end
        end
    end,
    -- one rectangle (testing):  hyprctl eval 'CyberGlitch.rect(100, 100, 800, 600, 0)'
    rect = function(x, y, w, h, mode)
        local m = hl.get_monitors()[1]
        play({ { x = x, y = y, w = w, h = h } }, m, mode or 0, mode == 1 and CLOSE_S or OPEN_S, 1.0)
    end,
}
