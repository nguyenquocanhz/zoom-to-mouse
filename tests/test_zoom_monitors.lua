-- Màn hình rời (external monitor): primary 1920x1080 at 0,0, external 2560x1440 to its right.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or ".") .. "/harness.lua")
local env, M = H.load("obs-zoom-to-mouse.lua")
local obs = obslua

local RECTS = {
    { x = 0, y = 0, width = 1920, height = 1080, scale = 1, primary = true },
    { x = 1920, y = 0, width = 2560, height = 1440, scale = 1, primary = false },
}
env.get_monitor_rects = function() return RECTS end

local display = M.add_source("Display", "xshm_input", { width = 1920, height = 1080 })
local main = M.add_source("Main", "scene", { scene = true })
M.add_item(main, display)
M.current_scene = main

local mouse = { x = 960, y = 540 }
env.get_mouse_pos = function() return { x = mouse.x, y = mouse.y } end
env.is_left_button_down = function() return false end

-- Capture starts on the primary monitor
display.settings.vals.screen = 0
display.prop_list = { name = "screen", items = {
    { "Screen 0: 1920x1080 @ 0,0", 0 },
    { "Screen 1: 2560x1440 @ 1920,0", 1 },
} }

local settings = H.start(env, M, { source = "Display", debug_logs = true })
local function cv(k)
    local crop = obs.obs_source_get_filter_by_name(display, "obs-zoom-to-mouse-crop")
    return crop and crop.settings.vals[k]
end
local function zoom_in_out(check)
    M.hotkeys.toggle_zoom_hotkey(true)
    M.advance(2500)
    check()
    M.hotkeys.toggle_zoom_hotkey(true)
    M.advance(2500)
end

zoom_in_out(function()
    H.eq(cv("left"), 480, "primary: zoom centred on the mouse")
end)

-- The user switches the Display Capture to the external monitor (in the source's own properties).
-- The script must notice both the new monitor position and the new resolution.
display.settings.vals.screen = 1
display.width, display.height = 2560, 1440
mouse.x, mouse.y = 1920 + 1280, 720 -- middle of the external monitor
zoom_in_out(function()
    H.eq(cv("cx"), 1280, "external: crop uses the new 2560 width")
    H.eq(cv("left"), 640, "external: zoom centred on the mouse, not stuck at the edge")
    H.eq(cv("top"), 360, "external: vertical centre")
end)

-- Monitor names without a position (some drivers / capture methods): found from the OS by size
display.prop_list.items[2][1] = "LG ULTRAGEAR"
mouse.x, mouse.y = 1920 + 400, 300
zoom_in_out(function()
    H.eq(cv("left"), 400 - 640 < 0 and 0 or 400 - 640, "unnamed external monitor: clamp to left edge")
    H.eq(cv("top"), 0, "unnamed external monitor: clamp to top")
end)
mouse.x, mouse.y = 1920 + 2000, 1000
zoom_in_out(function()
    H.eq(cv("left"), 1280, "unnamed external monitor: right side (2000-640 clamped to 1280)")
    H.eq(cv("top"), 640, "unnamed external monitor: lower part (1000-360)")
end)

-- pick_monitor rules
local p = env.pick_monitor({ x = 1920, y = 0, width = 2560, height = 1440, scale_x = 1, scale_y = 1 }, RECTS, 2560, 1440, true)
H.eq(p.x, 1920, "name matching an OS monitor")
p = env.pick_monitor(nil, RECTS, 2560, 1440, true)
H.eq(p and p.x, 1920, "no name -> unique size match")
H.check(env.pick_monitor(nil, { RECTS[1], { x = 1920, y = 0, width = 1920, height = 1080, scale = 1 } }, 1920, 1080, true) == nil,
    "two monitors with the same size -> no guess")
-- macOS: names may be in pixels while the OS works in points; Retina external monitor 1512x982 pt @2x
local mac = { { x = 0, y = 0, width = 1440, height = 900, scale = 2 }, { x = 1440, y = -200, width = 1512, height = 982, scale = 2 } }
p = env.pick_monitor({ x = 2880, y = -400, width = 3024, height = 1964, scale_x = 1, scale_y = 1 }, mac, 3024, 1964, false)
H.check(p.x == 1440 and p.y == -200 and p.scale_x == 2 and p.width == 3024,
    "macOS: pixel-based name ignored, Retina monitor found by size (points + scale 2)")

-- Scale is applied before the crop offset (crop is in source pixels)
local crop_user = obs.obs_source_create_private("crop_filter", "My crop", nil)
crop_user.settings.vals = { relative = false, left = 100, top = 0, cx = 1800, cy = 1080 }
display.width, display.height = 1920, 1080
display.settings.vals.screen = 0
display.prop_list.items[2][1] = "Screen 1: 2560x1440 @ 1920,0"
table.insert(display.filters, 1, crop_user)
H.update(env, settings, { use_monitor_override = true, monitor_override_x = 0, monitor_override_y = 0,
    monitor_override_w = 1920, monitor_override_h = 1080, monitor_override_sx = 2, monitor_override_sy = 2 })
M.hotkeys.toggle_zoom_hotkey(true) -- refresh picks up the crop filter on the first zoom
M.advance(2500)
M.hotkeys.toggle_zoom_hotkey(true)
M.advance(2500)
mouse.x, mouse.y = 300, 270
zoom_in_out(function()
    -- (300 * 2) - 100 = 500 in the cropped source; crop 900 wide -> left = 500 - 450
    H.eq(cv("left"), 50, "mouse scaled first, then crop offset")
end)
table.remove(display.filters, 1)
H.update(env, settings, { use_monitor_override = false })

-- Two monitors with the SAME resolution: switching the capture between them changes nothing but the
-- position, so the script has to re-read the monitor right before zooming.
mouse.x, mouse.y = 960, 540
zoom_in_out(function() H.eq(cv("left"), 480, "settled on the primary first") end)
table.insert(RECTS, { x = -1920, y = 0, width = 1920, height = 1080, scale = 1, primary = false })
table.insert(display.prop_list.items, { "Screen 2: 1920x1080 @ -1920,0", 2 })
display.settings.vals.screen = 2
mouse.x, mouse.y = -1920 + 960, 540
zoom_in_out(function()
    H.eq(cv("left"), 480, "same-resolution monitor on the left: zoom follows the mouse there")
end)
table.remove(RECTS)
table.remove(display.prop_list.items)
display.settings.vals.screen = 0

-- "Dùng màn hình đang có chuột": hotkey and the 3-second button
mouse.x, mouse.y = 1920 + 100, 100
M.hotkeys.zoom_calibrate_hotkey(true)
H.check(settings.vals.use_monitor_override == true, "calibrate turns on manual position")
H.eq(settings.vals.monitor_override_x, 1920, "calibrate x")
H.eq(settings.vals.monitor_override_w, 2560, "calibrate width")
H.eq(settings.vals.monitor_override_dh, 1440, "calibrate monitor height")
H.update(env, settings, { use_monitor_override = false })
local props = env.script_properties()
mouse.x, mouse.y = 500, 500 -- on the primary when the button is pressed
props.props.calibrate.callback(props, props.props.calibrate)
mouse.x, mouse.y = 1920 + 50, 50 -- moved to the external monitor within 3 s
H.check(settings.vals.use_monitor_override == false, "button waits before calibrating")
M.advance(3100, 100)
H.eq(settings.vals.monitor_override_x, 1920, "button calibrates the monitor under the mouse after 3 s")
H.check(M.timers[env.on_calibrate_timer] == nil, "calibrate timer is one-shot")

-- Zoom Source that doesn't exist (yet): OBS loads scripts before it creates the sources.
-- No scary "not a Display Capture" error in that case.
M.logs = {}
H.update(env, settings, { source = "Not created yet", use_monitor_override = false })
H.check(not M.log_text():find("không phải là Display Capture", 1, true), "no false error before sources exist")

env.script_unload()
H.finish("zoom: màn hình rời", M)
