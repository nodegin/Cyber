-- Looking Glass (the Windows VM's screen) on the Cyber desktop.
-- Loaded by the "cyber desktop" block of custom/keybinds.lua, so it only exists on Cyber.
-- The monitor button in Cyber's bottom bar starts and stops the client (services/LookingGlass.qml).
--
-- It is a fixture of the desktop, not a window on top of your work:
--   * a fixed spot top-left, a third of the screen wide, on whichever workspace you are looking at
--     (it follows you; it is not pinned, because Hyprland draws pinned windows above everything,
--     fullscreen apps included, and refuses to fullscreen them);
--   * normally the BOTTOM window: every other window is above it, tiled windows too;
--   * it comes FORWARD (raised above the other windows, flat, the real window):
--       - when you point at the part of its tilted picture that you can see: until the pointer leaves;
--       - when you pick it in the Super+Tab switcher, or it was just opened and other windows lie
--         over its spot (it would be invisible): until another window gets the focus, or the
--         pointer has been on it and left;
--     a window lying over its spot keeps the pointer: pointing there does not bring it forward;
--   * Super+F makes it fullscreen like any window.
-- While it is idle, Cyber shows a live copy of it tilted in 3D (hud/LookingGlassPanel.qml) and hides
-- the real window by tagging it "cybertilt" (the rule below). The real window stays in place, since
-- Hyprland only produces frames for windows it draws.
-- Hyprland keeps every floating window above the tiled ones, so the idle (invisible) window would
-- still take the pointer from a tiled window lying over its spot, and come forward over it. So
-- while it is idle it also carries the tag "cyberpass": the pointer goes through it. Cyber's copy
-- is on the desktop level, really under every window; where it shows and the pointer is on it,
-- Cyber calls CyberLookingGlass.engage() and the window takes the pointer and the focus again.
-- This file decides engaged / idle and tells Cyber (shortcuts "lgEngaged" / "lgIdle"); Cyber plays
-- the swing and sets "cybertilt". If Cyber's panel isn't there, both tags are taken off here, so
-- the window can never stay invisible or out of reach.

local CLASS = LOOKING_GLASS_CLASS or "looking-glass-client"   -- tests set LOOKING_GLASS_CLASS
local TAG = "cybertilt"
local PASS = "cyberpass"          -- while it carries this tag the pointer goes through it
local PANEL = "cyber:lg"          -- the layer namespace of Cyber's tilted panel
local HOME = os.getenv("HOME")

local function complain(where, err)
    local f = io.open(HOME .. "/.cache/hypr-setup/lookingglass.log", "a")
    if f then f:write(os.date("%F %T ") .. where .. ": " .. tostring(err) .. "\n"); f:close() end
end
-- a mistake in here must never put an error bar on the screen
local function guarded(where, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then complain(where, err) end
    end
end

-- ---- where it opens: these load after Cyber's general window rules (custom/env.lua), so they win
local this = { class = "^" .. CLASS .. "$" }
hl.window_rule({ match = this, float = true })
hl.window_rule({ match = this, center = false })
hl.window_rule({ match = this, size = "monitor_w/3 monitor_w/3*window_h/window_w" })   -- the guest's aspect ratio
hl.window_rule({ match = this, move = "12 66" })                                        -- under the top band
hl.window_rule({ match = this, render_unfocused = true })
-- No frosted glass behind it. It is the VM's opaque picture and only ever see-through for the
-- moment it fades out or in under its tilted copy: with blur, that moment showed a blurred
-- rectangle in front of the swinging copy (seen 2026-11-24).
hl.window_rule({ match = this, no_blur = true })
hl.window_rule({ match = { class = this.class, tag = TAG }, opacity = "0 override" })
hl.window_rule({ match = { class = this.class, tag = PASS }, no_focus = true })

-- ---- helpers
local function find()
    for _, w in ipairs(hl.get_windows() or {}) do
        if w.class == CLASS then return w end
    end
end
local function target(w) return "address:" .. w.address end
local function onSpecial(w)
    local ok, name = pcall(function() return w.workspace.name end)
    return ok and tostring(name):sub(1, 8) == "special:"
end
local function tagged(w, tag)
    for _, t in ipairs(w.tags or {}) do
        if tostring(t):gsub("%*$", "") == (tag or TAG) then return true end
    end
    return false
end
local function setTag(w, tag, on)
    if tagged(w, tag) ~= on then
        hl.dispatch(hl.dsp.window.tag({ tag = (on and "+" or "-") .. tag, window = target(w) }))
    end
end
local function panelAlive()
    for _, l in ipairs(hl.get_layers() or {}) do
        if l.namespace == PANEL and l.mapped then return true end
    end
    return false
end
-- is most of it under another window of its workspace?
local function covered(w)
    if not (w.at and w.size and w.workspace) then return false end
    local area = w.size.x * w.size.y
    for _, o in ipairs(hl.get_windows() or {}) do
        if o.address ~= w.address and o.workspace and o.workspace.id == w.workspace.id and o.at and o.size then
            local ix = math.min(w.at.x + w.size.x, o.at.x + o.size.x) - math.max(w.at.x, o.at.x)
            local iy = math.min(w.at.y + w.size.y, o.at.y + o.size.y) - math.max(w.at.y, o.at.y)
            if ix > 0 and iy > 0 and ix * iy >= 0.5 * area then return true end
        end
    end
    return false
end
local function pointerInside(w)
    local p = hl.get_cursor_pos()
    if not (p and w.at and w.size) then return false end
    return p.x >= w.at.x and p.y >= w.at.y and p.x < w.at.x + w.size.x and p.y < w.at.y + w.size.y
end

-- ---- engaged / idle
local engaged = nil       -- nil = not decided yet (after a reload)
local watching = false
local wanted = 0          -- > 0: it was called forward and does not have the focus yet; counts down the tries
local summoned = false    -- called forward (engage / show / just opened under other windows)
local visited = false     -- ... and the pointer has been on it since
local justOpened = false  -- its window appeared since the last look
local openedAt = 0
local seen = nil          -- its address the last time we looked (false: there was none; nil: not looked yet)

local function report()
    hl.dispatch(hl.dsp.global("quickshell:" .. (engaged and "lgEngaged" or "lgIdle")))
end
local function place(w)
    hl.dispatch(hl.dsp.window.alter_zorder({ mode = engaged and "top" or "bottom", window = target(w) }))
end

-- Work out the state and put the window where it belongs. Run one tick after any relevant event,
-- and while it is the active window every 120 ms, every 30 ms while it is forward (to see the
-- pointer leave and come back).
local function update(event)
    local w = find()
    if not w then engaged = nil; seen = false; return false end
    if seen == nil then seen = w.address                               -- it was already there when this file was loaded
    elseif seen ~= w.address then seen = w.address; justOpened = true; openedAt = os.time() end
    local active = hl.get_active_window()
    local isActive = active ~= nil and active.address == w.address
    local parked = w.fullscreen ~= 0 or onSpecial(w)      -- fullscreen, or minimized

    if not parked then
        if w.pinned then hl.dispatch(hl.dsp.window.pin({ action = "unset", window = target(w) })) end
        local ws = hl.get_active_workspace()
        if ws and not ws.special and w.workspace and w.workspace.id ~= ws.id then   -- follow the workspace
            hl.dispatch(hl.dsp.window.move({ workspace = tostring(ws.id), follow = false, window = target(w) }))
        end
    end

    local inside = pointerInside(w)
    local panel = panelAlive()
    if justOpened and (panel or os.time() - openedAt > 3) then   -- Cyber's panel appears a moment after the window
        justOpened = false
        -- opened where other windows lie over its spot: show it, or nothing would seem to happen
        if panel and not parked and covered(w) then summoned = true; visited = false; wanted = 12 end
    end

    -- Called forward. It ends when the pointer has been on it and left, or (below) when another
    -- window has the focus.
    if summoned then
        if inside then visited = true end
        if (visited and not inside) or parked or not panel then summoned = false end
    end
    if not summoned then wanted = 0 end
    -- it does not have the focus yet: take the pointer again (PASS off) and ask for the focus
    if wanted > 0 then
        if isActive then
            wanted = 0
        else
            wanted = wanted - 1
            setTag(w, PASS, false)
            -- Focusing a window by command puts the pointer in the middle of it. The pointer is on
            -- the part of the copy that shows, the middle may lie under another window: the pointer
            -- "jumped away" and the focus went to that window instead (the user's recording,
            -- 2026-11-24). So: above the other windows first, then the focus, then the pointer
            -- back where it was.
            local p = hl.get_cursor_pos()
            hl.dispatch(hl.dsp.window.alter_zorder({ mode = "top", window = target(w) }))
            hl.dispatch(hl.dsp.focus({ window = target(w) }))
            if p then hl.dispatch(hl.dsp.cursor.move({ x = p.x, y = p.y })) end
        end
    end
    if summoned and wanted == 0 and not isActive then summoned = false end

    local now
    if parked then now = isActive
    elseif not panel then now = isActive and inside     -- no Cyber panel: a plain window, forward under the pointer
    else now = summoned and isActive end                 -- idle otherwise, whatever the pointer is over
    if now ~= engaged then
        engaged = now
        if not parked then place(w) end
        report()
    elseif event and not parked then
        place(w)      -- a click raises a floating window: put it back where its state says
    end

    -- the tags only mean something while Cyber's panel is there to show the copy and to call it back
    if not panel then setTag(w, TAG, false) end
    setTag(w, PASS, panel and not parked and not now and wanted == 0)
    return isActive
end

local pending = false     -- an event came in since the last look
local watch
watch = guarded("watch", function()
    watching = false
    local event = pending
    pending = false
    local active = update(event)
    if active or wanted > 0 then
        watching = true
        -- while it is forward the pointer is watched closely, so it goes back the moment the pointer leaves
        hl.timer(watch, { timeout = (wanted > 0 and 15) or (engaged and 30) or 120, type = "oneshot" })
    end
end)
-- one tick later: Hyprland raises a clicked floating window after it reports the focus change
local function soon()
    pending = true
    if not watching then
        watching = true
        hl.timer(watch, { timeout = 1, type = "oneshot" })
    end
end

for _, event in ipairs({ "window.active", "window.close", "window.fullscreen", "workspace.active",
                         "layer.opened", "layer.closed" }) do   -- layers: Cyber's panel coming and going
    hl.on(event, guarded(event, soon))
end
hl.on("window.open", guarded("window.open", function(win)
    local ok, class = pcall(function() return win.class end)
    if ok and class == CLASS then justOpened = true; openedAt = os.time() end
    soon()
end))
soon()   -- after a (re)load

-- Cyber asks for the current state when it starts; also handy for testing:
--   hyprctl eval 'CyberLookingGlass.report()'
CyberLookingGlass = {
    report = guarded("report", function() update(true); report() end),
    -- the pointer is on Cyber's copy of the idle window: forward until the pointer leaves
    engage = guarded("engage", function()
        if engaged then return end
        summoned = true; visited = true; wanted = 12
        soon()
    end),
    -- picked in the window switcher: forward until another window gets the focus
    show = guarded("show", function()
        summoned = true; visited = false; wanted = 12
        soon()
    end),
}
