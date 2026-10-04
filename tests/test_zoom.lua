local H = dofile((debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or ".") .. "/harness.lua")
local env, M = H.load("obs-zoom-to-mouse.lua")
local obs = obslua

-- Linux display capture is xshm_input; LuaJIT here reports ffi.os == "Linux"
local display = M.add_source("Display", "xshm_input")
local main = M.add_source("Main", "scene", { scene = true })
local item = M.add_item(main, display)
M.current_scene = main

-- Drive the mouse/buttons from the test instead of X11
local mouse = { x = 1000, y = 500 }
local button = false
env.get_mouse_pos = function() return { x = mouse.x, y = mouse.y } end
env.is_left_button_down = function() return button end

local settings = H.start(env, M, {
    source = "Display",
    zoom_mode = "crop", follow_speed = 0.25, zoom_speed = 0.06,
    use_monitor_override = true,
    monitor_override_x = 0, monitor_override_y = 0,
    monitor_override_w = 1920, monitor_override_h = 1080,
    monitor_override_sx = 1, monitor_override_sy = 1,
    debug_logs = true,
})

local crop = obs.obs_source_get_filter_by_name(display, "obs-zoom-to-mouse-crop")
H.check(crop ~= nil, "crop filter added on source select")
H.eq(item.info.bounds_type, obs.OBS_BOUNDS_SCALE_INNER, "transform converted to bounding box while active")
H.eq(crop.settings.vals.cx, 1920, "crop starts at full width")

local function cv(k) return crop.settings.vals[k] end

-- Zoom in
M.hotkeys.toggle_zoom_hotkey(true)
M.advance(2000)
H.eq(cv("cx"), 960, "zoomed crop width = 1920/2")
H.eq(cv("cy"), 540, "zoomed crop height = 1080/2")
H.eq(cv("left"), 520, "zoom centered on mouse x")
H.eq(cv("top"), 230, "zoom centered on mouse y")
H.eq(item.scale_filter, obs.OBS_SCALE_LANCZOS, "Lanczos scale filter while zoomed")
local sharpen = obs.obs_source_get_filter_by_name(display, "obs-zoom-to-mouse-sharpen")
H.check(sharpen ~= nil and sharpen.enabled, "sharpen filter enabled while zoomed")
H.eq(sharpen and sharpen.settings.vals.sharpness, 0.1, "sharpen strength at 2x")

-- Idle while locked: no filter updates every frame
local updates = M.calls.obs_source_update
M.advance(1000)
H.eq(M.calls.obs_source_update, updates, "no crop updates while mouse rests")

-- Follow the mouse to the bottom-right corner, clamped to the source
mouse.x, mouse.y = 1900, 1070
M.advance(3000)
H.eq(cv("left"), 960, "follow clamps to right edge")
H.eq(cv("top"), 540, "follow clamps to bottom edge")

-- Zoom in more via hotkey (step 0.5 -> 2.5x)
M.hotkeys.zoom_more_hotkey(true)
M.advance(2000)
H.eq(cv("cx"), 768, "zoom more = 1920/2.5")

-- Zoom out restores filter + quality settings and stops the timer
M.hotkeys.toggle_zoom_hotkey(true)
M.advance(2000)
H.eq(cv("cx"), 1920, "zoomed out to full width")
H.eq(cv("left"), 0, "zoomed out to x=0")
H.eq(item.scale_filter, 0, "scale filter restored after zoom out")
H.check(not sharpen.enabled, "sharpen disabled after zoom out")
H.check(M.timers[env.on_timer] == nil, "frame timer removed once zoomed out")

-- Pressing during the zoom-in animation reverses it
M.hotkeys.zoom_less_hotkey(true) -- back to 2x for the next zoom
M.hotkeys.toggle_zoom_hotkey(true)
M.advance(200)
H.check(cv("cx") < 1920 and cv("cx") > 960, "mid animation")
M.hotkeys.toggle_zoom_hotkey(true)
M.advance(2000)
H.eq(cv("cx"), 1920, "reverse mid-animation goes back out")

-- Easing runs from where the animation started, at a speed independent of the timer rate.
-- zoom_speed is "progress per 60fps frame": after 160ms -> 9.6 frames -> t = 0.06 * 9.6
local function expected_cx(ms)
    return math.floor(1920 - 960 * env.ease_in_out(math.min(1, 0.06 * ms * 60 / 1000)))
end
mouse.x, mouse.y = 1000, 500 -- target crop: left 520, top 230
M.hotkeys.toggle_zoom_hotkey(true)
M.advance(160) -- 16ms ticks (60 fps)
H.check(math.abs(cv("cx") - expected_cx(160)) <= 1, "eased from start at 60fps: " .. cv("cx") .. " vs " .. expected_cx(160))
local e160 = env.ease_in_out(0.06 * 9.6)
H.check(math.abs(cv("left") - 520 * e160) <= 1, "x eased from start: " .. cv("left") .. " vs " .. math.floor(520 * e160))
H.check(math.abs(cv("top") - 230 * e160) <= 1, "y eased from start: " .. cv("top") .. " vs " .. math.floor(230 * e160))
local sh = sharpen.settings.vals.sharpness
H.check(sharpen.enabled and sh > 0 and sh < 0.1, "sharpen fades in with the zoom (" .. tostring(sh) .. ")")
M.advance(3000)
M.hotkeys.toggle_zoom_hotkey(true)
M.advance(3000)
H.eq(cv("cx"), 1920, "back out")
M.hotkeys.toggle_zoom_hotkey(true)
M.advance(165, 33) -- 33ms ticks (30 fps): same wall time, half the ticks
H.check(math.abs(cv("cx") - expected_cx(165)) <= 1, "same progress at 30fps: " .. cv("cx") .. " vs " .. expected_cx(165))
M.advance(3000)

-- Follow speed is frame-rate independent too (follow_border 50 = never lock, always track)
H.update(env, settings, { follow_border = 50 })
mouse.x, mouse.y = 1000, 500
M.advance(3000, 33)
H.eq(cv("left"), 520, "follow settled on mouse")
-- Same pan at 30 fps and at 60 fps must cover the same distance in the same time
mouse.x = 1400 -- target left = 920, 400px away
M.advance(198, 33) -- 6 ticks at 30fps
local at30 = cv("left")
mouse.x = 1000
M.advance(3000, 16)
H.eq(cv("left"), 520, "back on the mouse")
mouse.x = 1400
M.advance(198, 16) -- 12 ticks at 60fps
local at60 = cv("left")
H.check(at30 > 600 and at30 < 920 and math.abs(at30 - at60) <= 25,
    "follow is frame-rate independent: 30fps " .. at30 .. " vs 60fps " .. at60)

-- With no lock, a resting mouse must not push identical crop values every frame
M.advance(3000, 16)
local updates2 = M.calls.obs_source_update
M.advance(1000, 16)
H.eq(M.calls.obs_source_update, updates2, "no duplicate crop updates when the camera has converged")
H.update(env, settings, { follow_border = 8 })

-- A slow animation moves less than a pixel per frame at the start: those frames must not hit OBS
M.hotkeys.toggle_zoom_hotkey(true)
M.advance(3000)
H.eq(cv("cx"), 1920, "zoomed out before the slow zoom")
H.update(env, settings, { zoom_speed = 0.01 })
local before = M.calls.obs_source_update
M.hotkeys.toggle_zoom_hotkey(true)
M.advance(160) -- 10 frames, ~2px of movement in total
H.check(M.calls.obs_source_update - before <= 4, "sub-pixel frames skipped (" .. (M.calls.obs_source_update - before) .. " updates)")
H.update(env, settings, { zoom_speed = 0.06 })
M.advance(3000)

-- Turning follow off while zoomed frees the per-frame timer, turning it on restarts it
M.hotkeys.toggle_follow_hotkey(true)
H.check(M.timers[env.on_timer] == nil, "follow off -> timer stopped")
M.hotkeys.toggle_follow_hotkey(true)
H.check(M.timers[env.on_timer] ~= nil, "follow on -> timer running")
M.hotkeys.toggle_zoom_hotkey(true)
M.advance(3000)
H.eq(cv("cx"), 1920, "out again")

-- Zoom factor stays within 1..10 no matter how often the hotkeys are pressed
for _ = 1, 10 do M.hotkeys.zoom_less_hotkey(true) end
M.hotkeys.zoom_more_hotkey(true)
M.hotkeys.toggle_zoom_hotkey(true)
M.advance(3000)
H.eq(cv("cx"), 1280, "zoom less clamps at 1x, +0.5 = 1.5x")
M.hotkeys.toggle_zoom_hotkey(true)
M.advance(3000)
M.hotkeys.zoom_more_hotkey(true) -- back to 2x

-- A transition releases the sceneitem; the hotkey must find it again by itself
env.on_transition_start()
H.check(obs.obs_source_get_filter_by_name(display, "obs-zoom-to-mouse-crop") == nil, "transition removed crop")
M.hotkeys.toggle_zoom_hotkey(true)
M.advance(3000)
crop = obs.obs_source_get_filter_by_name(display, "obs-zoom-to-mouse-crop")
H.check(crop ~= nil and cv("cx") == 960, "hotkey re-finds the source after a transition")
M.hotkeys.toggle_zoom_hotkey(true)
M.advance(3000)

-- Auto zoom on click + auto zoom out after idle
H.update(env, settings, { click_zoom = true, auto_zoom_out_delay = 2 })
H.check(M.timers[env.on_click_poll] ~= nil, "click poll timer started")
mouse.x, mouse.y = 400, 300
M.advance(100)
button = true
M.advance(60)
button = false
M.advance(1500)
H.eq(cv("cx"), 960, "click zooms in")
M.advance(3000)
H.eq(cv("cx"), 1920, "auto zoom out after idle")

-- Click outside the zoom source (another monitor) is ignored
mouse.x = 2500
M.advance(100)
button = true
M.advance(60)
button = false
M.advance(1500)
H.eq(cv("cx"), 1920, "click on another monitor ignored")
H.update(env, settings, { click_zoom = false })
H.check(M.timers[env.on_click_poll] == nil, "click poll timer stopped")

-- Leaving the scene / exiting restores the user's original transform (was get_info2 instead of set_info2)
M.fire(obs.OBS_FRONTEND_EVENT_EXIT)
H.eq(item.info.bounds_type, obs.OBS_BOUNDS_NONE, "original transform restored on exit")
H.check(obs.obs_source_get_filter_by_name(display, "obs-zoom-to-mouse-crop") == nil, "crop filter removed on exit")

-- Hotkey with no valid source does not crash
H.update(env, settings, { source = "obs-zoom-to-mouse-none" })
M.hotkeys.toggle_zoom_hotkey(true)
M.advance(100)

-- Only real display captures get automatic monitor detection
local cam = M.add_source("Webcam", "v4l2_input")
H.check(not env.is_display_capture(cam), "webcam is not a display capture")
H.check(env.is_display_capture(display), "xshm_input is a display capture")
H.check(not env.is_display_capture(nil), "nil is not a display capture")

-- Monitor info is parsed from the display list name (and the loop no longer reads past the end)
display.settings.vals.screen = 1
display.prop_list = { name = "screen", items = {
    { "Screen 0: 1920x1080 @ 0,0", 0 },
    { "Screen 1: 2560x1440 @ 1920,0", 1 },
} }
H.update(env, settings, { use_monitor_override = false })
local info = env.get_monitor_info(display)
H.check(info ~= nil, "monitor info parsed")
H.eq(info and info.x, 1920, "monitor x offset")
H.eq(info and info.width, 2560, "monitor width")
display.settings.vals.screen = 5
H.check(env.get_monitor_info(display) == nil, "unknown monitor id -> nil, no out-of-range read")

env.script_unload()
H.finish("obs-zoom-to-mouse.lua", M)
