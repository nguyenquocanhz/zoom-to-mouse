local H = dofile((debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or ".") .. "/harness.lua")
local env, M = H.load("countdown-pro.lua")

local text = M.add_source("Countdown", "text_gdiplus_v3")
M.add_source("Starting", "scene", { scene = true })
local live = M.add_source("Live", "scene", { scene = true })
local function t() return text.settings.vals.text end

H.eq(env.format_time(65, "auto"), "01:05", "format mm:ss")
H.eq(env.format_time(3725, "auto"), "01:02:05", "auto switches to hh:mm:ss")
H.eq(env.format_time(3725, "mm:ss"), "62:05", "mm:ss keeps counting minutes")
H.eq(env.format_time(9.2, "auto"), "00:10", "rounds up so 00:00 only shows at the end")

local settings = H.start(env, M, {
    text_source = "Countdown", duration_min = 0, duration_sec = 10, end_scene = "Live",
})
H.eq(t(), "Bắt đầu sau 00:10", "idle shows full duration")

M.hotkeys.countdown_pro_start_pause(true)
M.advance(3000, 50)
H.eq(t(), "Bắt đầu sau 00:07", "counts down")
M.hotkeys.countdown_pro_start_pause(true) -- pause
M.advance(5000, 50)
H.eq(t(), "Bắt đầu sau 00:07", "paused keeps the time")
M.hotkeys.countdown_pro_add_minute(true)
H.eq(t(), "Bắt đầu sau 01:07", "+1 minute")
M.hotkeys.countdown_pro_reset(true)
H.eq(t(), "Bắt đầu sau 00:10", "reset")

M.hotkeys.countdown_pro_start_pause(true)
M.advance(10500, 50)
H.eq(t(), "Bắt đầu thôi!", "end text")
M.current_scene = nil
M.hotkeys.countdown_pro_reset(true)
M.hotkeys.countdown_pro_start_pause(true)
M.advance(2000, 50)
M.hotkeys.countdown_pro_add_minute(true)
M.advance(1000, 50)
H.eq(t(), "Bắt đầu sau 01:07", "+1 minute while running")
M.advance(70000, 50)
H.check(M.current_scene == live, "finishes after the extra minute")
M.hotkeys.countdown_pro_reset(true)
H.eq(t(), "Bắt đầu sau 00:10", "reset after finish")
M.hotkeys.countdown_pro_start_pause(true)
M.advance(10500, 50)
H.check(M.current_scene == live, "switched to end scene")
H.check(M.timers[env.on_tick] == nil, "timer removed when finished")

-- Clock mode
H.update(env, settings, { mode = "clock", target_time = os.date("%H:%M", os.time() + 3600) })
M.hotkeys.countdown_pro_reset(true)
local mm = tonumber(t():match("(%d+):%d+$"))
H.check(mm == 59 or mm == 60, "clock mode counts to the target time (" .. t() .. ")")
H.update(env, settings, { target_time = os.date("%H:%M", os.time() - 3600) })
M.hotkeys.countdown_pro_reset(true)
local hh = tonumber(t():match("(%d+):%d+:%d+"))
H.check(hh == 22 or hh == 23, "time already passed today -> counts to tomorrow (" .. t() .. ")")
H.check(env.seconds_until("25:00") == nil, "invalid target rejected")
H.check(env.seconds_until("7:05") ~= nil, "H:MM accepted")

-- Auto start on activate
H.update(env, settings, { mode = "duration", duration_sec = 30 })
env.on_source_activate()
M.advance(2000, 50)
H.eq(t(), "Bắt đầu sau 00:28", "auto start when shown")
env.on_source_deactivate()
H.check(M.timers[env.on_tick] == nil, "auto pause when hidden")

env.script_unload()
H.finish("countdown-pro.lua", M)
