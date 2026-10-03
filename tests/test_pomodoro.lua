local H = dofile((debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or ".") .. "/harness.lua")
local env, M = H.load("pomodoro-study.lua")

local text = M.add_source("Pomo", "text_ft2_source_v2")
local ding = M.add_source("Ding", "ffmpeg_source")
local focus = M.add_source("Study", "scene", { scene = true })
local brk = M.add_source("Break", "scene", { scene = true })
local function t() return text.settings.vals.text end

local settings = H.start(env, M, {
    text_source = "Pomo", focus_min = 1, short_min = 1, cycles = 2, long_min = 1,
    focus_scene = "Study", break_scene = "Break", sound_source = "Ding",
    template = "{label} {time} {cycle}/{total} done={done}",
})
H.eq(t(), "⏸ 🍅 FOCUS 01:00 1/2 done=0", "idle")

M.hotkeys.pomodoro_start_pause(true)
H.check(M.current_scene == focus, "focus scene on start")
M.advance(30000, 250)
H.eq(t(), "🍅 FOCUS 00:30 1/2 done=0", "focus counting")
M.advance(31000, 250)
H.eq(t(), "☕ BREAK 00:59 1/2 done=1", "short break after focus")
H.check(M.current_scene == brk, "break scene")
H.eq(M.calls.obs_source_media_restart, 1, "ding played")
M.advance(61000, 250)
H.eq(t(), "🍅 FOCUS 00:58 2/2 done=1", "cycle 2 focus (break ended 2s ago)")
M.advance(61000, 250)
H.check(t():find("LONG BREAK 00:5", 1, true) ~= nil, "long break after last cycle: " .. t())
M.hotkeys.pomodoro_skip(true)
H.check(t():find("FOCUS 01:00 1/2 done=2", 1, true) ~= nil, "skip -> new round: " .. t())
M.hotkeys.pomodoro_start_pause(true)
H.check(t():find("⏸", 1, true) == 1, "paused label")
M.hotkeys.pomodoro_reset(true)
H.eq(t(), "⏸ 🍅 FOCUS 01:00 1/2 done=0", "reset")

-- No drift: OBS timers never fire exactly on the phase boundary. With ticks that don't line up
-- (70ms steps vs 250ms timer), 20 one-minute phases must still end exactly 20 minutes later.
M.hotkeys.pomodoro_reset(true)
M.hotkeys.pomodoro_start_pause(true)
M.advance(20 * 60000 + 30000, 70)
H.eq(t():match("%d%d:%d%d"), "00:30", "no drift after 20 phases: " .. t())

-- auto_continue off: the next phase waits for Start
H.update(env, settings, { auto_continue = false })
M.hotkeys.pomodoro_reset(true)
M.hotkeys.pomodoro_start_pause(true)
M.advance(65000, 250)
H.eq(t(), "⏸ ☕ BREAK 01:00 1/2 done=1", "waits at the start of the break")
M.advance(5000, 250)
H.eq(t(), "⏸ ☕ BREAK 01:00 1/2 done=1", "still waiting")

env.script_unload()
H.finish("pomodoro-study.lua", M)
