-- Cyber's keyboard extras. Loaded by the "cyber desktop" block of custom/keybinds.lua (Cyber only).
--
--   * Super+Q: eliminate mode (popups/Eliminate.qml): aim at any window with the crosshair, click to
--     close it. Super+Q again fires at the window under the crosshair; Esc or right-click aborts.
--   * Holding Super lights the screen's edges cyan (hud/SuperGlow.qml), driven by end-4's Super
--     press/release shortcut. That release can get lost (Super+Tab's submap has its own binds, a VM
--     can grab the keyboard), so while Super is down Cyber asks for CyberKeys.watch(): Hyprland
--     checks the key every 150 ms and sends "superReleased" itself once it's up.

local HOME = os.getenv("HOME")
local function complain(where, err)
    local f = io.open(HOME .. "/.cache/hypr-setup/keys.log", "a")
    if f then f:write(os.date("%F %T ") .. where .. ": " .. tostring(err) .. "\n"); f:close() end
end

hl.unbind("SUPER + Q")
hl.bind("SUPER + Q", hl.dsp.global("quickshell:eliminateToggle"),
    { description = "Window: Eliminate mode (aim, click to close)" })

local watching = false
local function superDown()
    local ok, down = pcall(function() return hl.is_key_down("Super_L") or hl.is_key_down("Super_R") end)
    return ok and down
end
local function check()
    local ok, err = pcall(function()
        if superDown() then
            hl.timer(check, { timeout = 150, type = "oneshot" })
        else
            watching = false
            hl.dispatch(hl.dsp.global("quickshell:superReleased"))
        end
    end)
    if not ok then watching = false; complain("watch", err) end
end

CyberKeys = {
    watch = function()
        if watching then return end
        watching = true
        hl.timer(check, { timeout = 150, type = "oneshot" })
    end,
}
