local H = dofile((debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or ".") .. "/harness.lua")
local env, M = H.load("live-timer.lua")
local obs = obslua

local text = M.add_source("Timer", "text_gdiplus_v3")
local function t() return text.settings.vals.text end

-- Loaded mid-stream: 90s of frames already sent at 60fps
M.streaming = true
M.stream_frames = 90 * 60
M.clock_ns = 1000 * 1000000000
H.start(env, M, { text_source = "Timer" })
M.advance(1000, 500)
H.eq(t(), "🔴 LIVE 00:01:31", "resumes from output frames")

M.recording = true
M.fire(obs.OBS_FRONTEND_EVENT_RECORDING_STARTED)
M.advance(5000, 500)
H.eq(t(), "🔴 LIVE 00:01:36 · ⏺ REC 00:00:05", "both")

M.streaming = false
M.fire(obs.OBS_FRONTEND_EVENT_STREAMING_STOPPED)
M.fire(obs.OBS_FRONTEND_EVENT_RECORDING_PAUSED)
M.advance(10000, 500)
H.eq(t(), "⏸ PAUSED 00:00:05", "paused")
M.fire(obs.OBS_FRONTEND_EVENT_RECORDING_UNPAUSED)
M.advance(2000, 500)
H.eq(t(), "⏺ REC 00:00:07", "pause excluded")
M.fire(obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED)
H.eq(t(), "", "offline hides text")

env.script_unload()
H.finish("live-timer.lua", M)
