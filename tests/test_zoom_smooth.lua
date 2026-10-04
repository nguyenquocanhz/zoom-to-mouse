-- Smooth mode: sub-pixel shader view + spring follow.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or ".") .. "/harness.lua")
local env, M = H.load("obs-zoom-to-mouse.lua")
local obs = obslua

local display = M.add_source("Display", "xshm_input", { width = 1920, height = 1080 })
local main = M.add_source("Main", "scene", { scene = true })
local item = M.add_item(main, display)
M.current_scene = main
env.get_monitor_rects = function() return { { x = 0, y = 0, width = 1920, height = 1080, scale = 1 } } end

local mouse = { x = 1000, y = 500 }
env.get_mouse_pos = function() return { x = mouse.x, y = mouse.y } end
env.is_left_button_down = function() return false end

local settings = H.start(env, M, { source = "Display", use_monitor_override = true, monitor_override_x = 0,
    monitor_override_y = 0, monitor_override_w = 1920, monitor_override_h = 1080, monitor_override_sx = 1,
    monitor_override_sy = 1, follow_border = 50 })

local view = obs.obs_source_get_filter_by_name(display, "obs-zoom-to-mouse-view")
H.check(view ~= nil, "smooth is the default: view filter added")
H.check(obs.obs_source_get_filter_by_name(display, "obs-zoom-to-mouse-crop") == nil, "no crop filter in smooth mode")
H.eq(item.info.bounds_type, obs.OBS_BOUNDS_NONE, "user transform left untouched")
local function v(k) return view.settings.vals[k] end

-- Sub-pixel: 2.2x of 1920 = 872.73 px wide, centred on x=1000 -> 563.64 (not floored)
H.update(env, settings, { zoom_value = 2.2 })
M.hotkeys.toggle_zoom_hotkey(true)
M.advance(2500, 16)
H.check(math.abs(v("w") - 1920 / 2.2) < 0.01, "view width is fractional: " .. tostring(v("w")))
H.check(math.abs(v("x") - (1000 - 1920 / 2.2 / 2)) < 0.06, "view x is fractional: " .. tostring(v("x")))
H.eq(item.scale_filter, 0, "OBS item scale filter untouched (the shader upscales)")

-- Slow pan: the mouse moves 1 px every 3 frames. The view must glide a little EVERY frame
-- (sub-pixel), not stand still for 2 frames and jump on the 3rd like whole-pixel cropping does.
local function slow_pan(read)
    local xs = {}
    for i = 1, 180 do
        if i % 3 == 0 then mouse.x = mouse.x + 1 end
        M.advance(16, 16)
        xs[#xs + 1] = read()
    end
    local frozen, steps = 0, 0
    for i = 61, #xs do -- after the spring has caught up with the pan speed
        local d = xs[i] - xs[i - 1]
        if math.abs(d) < 0.01 then frozen = frozen + 1 end
        if d > 0.5 then steps = steps + 1 end
    end
    return frozen, steps
end
local frozen, steps = slow_pan(function() return v("x") end)
H.check(frozen == 0 and steps == 0,
    string.format("smooth: slow pan glides every frame (frozen frames %d, whole-pixel jumps %d)", frozen, steps))

-- Spring: when the mouse jumps away, the view accelerates (first step smaller than the next ones)
mouse.x = 1000
M.advance(3000, 16)
local x0 = v("x")
mouse.x = 1400
M.advance(16, 16)
local x1 = v("x")
M.advance(16, 16)
local x2 = v("x")
H.check(x1 - x0 > 0 and (x2 - x1) > (x1 - x0), string.format("eases in: steps %.1f then %.1f px", x1 - x0, x2 - x1))
M.advance(3000, 16)
H.check(math.abs(v("x") - (1400 - 1920 / 2.2 / 2)) < 0.06, "spring settles exactly on the target")
H.check(v("x") <= 1400 - 1920 / 2.2 / 2 + 0.06, "and never overshoots")

-- The view is racing towards the mouse and the mouse stops: no overshoot-and-bounce-back
local pos_, vel_, max_ = 0, 3000, 0
for _ = 1, 120 do
    pos_, vel_ = env.smooth_damp(pos_, 100, vel_, 0.15, 1 / 60)
    max_ = math.max(max_, pos_)
end
H.check(max_ <= 100 and math.abs(pos_ - 100) < 0.01, "spring with momentum stops at the target: max " .. max_)

-- Zoom out: back to the full picture
M.hotkeys.toggle_zoom_hotkey(true)
M.advance(2500, 16)
H.check(v("x") == 0 and v("y") == 0 and math.abs(v("w") - 1920) < 0.01, "zoomed out to the full view")

-- Switch to crop mode and back: the right filter each time, no leftovers
H.update(env, settings, { zoom_mode = "crop" })
H.check(obs.obs_source_get_filter_by_name(display, "obs-zoom-to-mouse-view") == nil, "crop mode removes the view filter")
H.check(obs.obs_source_get_filter_by_name(display, "obs-zoom-to-mouse-crop") ~= nil, "crop mode adds the crop filter")
H.update(env, settings, { zoom_mode = "smooth" })
view = obs.obs_source_get_filter_by_name(display, "obs-zoom-to-mouse-view")
H.check(view ~= nil and obs.obs_source_get_filter_by_name(display, "obs-zoom-to-mouse-crop") == nil, "and back")

-- A leftover crop filter from a crash is cleaned up when smooth mode sets up
local leftover = obs.obs_source_create_private("crop_filter", "obs-zoom-to-mouse-crop", nil)
table.insert(display.filters, leftover)
M.fire(obs.OBS_FRONTEND_EVENT_SCENE_CHANGED)
H.check(obs.obs_source_get_filter_by_name(display, "obs-zoom-to-mouse-crop") == nil, "stale crop filter removed")

------------------------------------------------------------------------------
-- The registered shader filter itself
local f = M.registered.algen_zoom_to_mouse_view
H.check(f ~= nil, "view filter registered")
local fs = M.settings()
fs.vals = { x = 100.25, y = 50.5, w = 960, h = 540 }
local target = M.add_source("Cam", "v4l2_input", { width = 1920, height = 1080 })
local data = f.create(fs, { name = "v", target = target })
H.check(data ~= nil, "shader compiled (mock)")
-- OBS treats a Lua filter without get_width/get_height as 0x0: the whole source turns black
H.check(type(f.get_width) == "function" and type(f.get_height) == "function", "filter reports its size")
if f.video_tick then f.video_tick(data, 0.016) end
H.check(f.get_width and f.get_width(data) == 1920 and f.get_height(data) == 1080, "size = input size (1920x1080)")
f.video_tick(data, 0.016)
f.video_render(data)
local P = M.effect_params
H.check(P.tex_size.x == 1920 and P.tex_size.y == 1080, "texture size from the input")
H.check(P.view.x == 100.25 and P.view.y == 50.5 and P.view.z == 960 and P.view.w == 540, "sub-pixel view passed to the shader")
local skips = M.calls.obs_source_skip_video_filter or 0
fs.vals = { x = 0, y = 0, w = 1920, h = 1080 }
f.update(data, fs)
f.video_render(data)
H.eq(M.calls.obs_source_skip_video_filter, skips + 1, "full view = pass-through (no resampling, no cost)")
target.width = 0
f.video_tick(data, 0.016)
f.video_render(data)
H.eq(M.calls.obs_source_skip_video_filter, skips + 2, "no size yet = pass-through")
f.destroy(data)
M.effect_fail = true
H.check(f.create(fs, { name = "v", target = target }) == nil, "nil when the shader fails")
M.effect_fail = false

-- Same slow pan in crop mode, for comparison: the classic mode visibly steps
H.update(env, settings, { zoom_mode = "crop" })
mouse.x = 1000
M.hotkeys.toggle_zoom_hotkey(true)
M.advance(2500, 16)
local crop = obs.obs_source_get_filter_by_name(display, "obs-zoom-to-mouse-crop")
local cfrozen, csteps = slow_pan(function() return crop.settings.vals.left end)
H.check(cfrozen > 40 and csteps > 20,
    string.format("crop mode steps on the same pan (frozen frames %d, whole-pixel jumps %d)", cfrozen, csteps))

env.script_unload()
H.finish("zoom: chế độ mượt", M)
