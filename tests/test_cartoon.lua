local H = dofile((debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or ".") .. "/harness.lua")
local env, M = H.load("cartoon-face.lua")
local obs = obslua

-- The filter registers itself when the script loads
local f = M.registered.algen_cartoon_face
H.check(f ~= nil, "filter registered")
H.eq(f.type, obs.OBS_SOURCE_TYPE_FILTER, "is a filter")
H.eq(f.get_name(), "Cartoon Face (Hoạt hình)", "name")

local fs = M.settings()
f.get_defaults(fs)
local cam = M.add_source("Webcam", "v4l2_input", { width = 1280, height = 720 })
local inst = { name = "Cartoon Face", id = "algen_cartoon_face", target = cam }
local data = f.create(fs, inst)
H.check(data ~= nil, "created")
H.check(not M.in_graphics, "left the graphics context")

-- Before the first tick the size is unknown -> pass through
f.video_render(data, nil)
H.eq(M.calls.obs_source_skip_video_filter, 1, "skips while size unknown")

f.video_tick(data, 0.016)
H.eq(f.get_width(data), 1280, "width from parent")
H.eq(f.get_height(data), 720, "height from parent")
f.video_render(data, nil)
H.eq(M.calls.obs_source_process_filter_end, 1, "rendered")
local P = M.effect_params
H.check(math.abs(P.texel.x - 1 / 1280) < 1e-9 and math.abs(P.texel.y - 1 / 720) < 1e-9, "texel size")
H.eq(P.levels, 6, "anime levels")
H.eq(P.intensity, 1, "intensity 100% -> 1")
H.eq(P.use_mask, 0, "mask off by default")
H.check(math.abs(P.mask_center.x - 0.5) < 1e-9 and math.abs(P.mask_center.y - 0.42) < 1e-9, "mask center in uv")
H.check(math.abs(P.mask_radius.x - 0.225) < 1e-9 and math.abs(P.mask_radius.y - 0.375) < 1e-9, "mask radius = size/2 in uv")
H.check(math.abs(P.line_color.x - 0x1A / 255) < 1e-9, "line colour")

-- OBS colours are 0xAABBGGRR: pure red must land in .x
fs.vals.line_color = 0xFF0000FF
fs.vals.use_mask = true
f.update(data, fs)
f.video_render(data, nil)
H.eq(P.line_color.x, 1, "red channel")
H.eq(P.line_color.z, 0, "blue channel")
H.eq(P.use_mask, 1, "mask on")

-- Presets
local props = f.get_properties(data)
fs.vals.preset = "comic"
H.check(props.props.preset.modified(props, props.props.preset, fs), "preset refreshes UI")
f.update(data, fs)
f.video_render(data, nil)
H.eq(P.levels, 4, "comic levels")
H.eq(P.edge_threshold, 0.12, "comic edges")
fs.vals.preset = "custom"
H.check(not props.props.preset.modified(props, props.props.preset, fs), "custom keeps values")

-- Mask sliders only visible when the mask is on
fs.vals.use_mask = false
props.props.use_mask.modified(props, props.props.use_mask, fs)
H.check(not props.props.mask_x.visible, "mask sliders hidden")
fs.vals.use_mask = true
props.props.use_mask.modified(props, props.props.use_mask, fs)
H.check(props.props.mask_x.visible, "mask sliders shown")

f.destroy(data)
H.check(M.effect_destroyed, "effect destroyed")

-- Shader that fails to compile -> create returns nil instead of a half-built filter
M.effect_fail = true
H.check(f.create(fs, inst) == nil, "nil on shader error")
M.effect_fail = false

------------------------------------------------------------------------------
-- Script hotkey: filter mode
local avatar = M.add_source("Avatar", "image_source")
local main = M.add_source("Main", "scene", { scene = true })
local game = M.add_source("Game", "scene", { scene = true })
local cam_item = M.add_item(main, cam)
local av_item = M.add_item(main, avatar)
av_item.visible = false
local cam_item2 = M.add_item(game, cam)

local settings = H.start(env, M, { webcam = "Webcam" })
M.hotkeys.cartoon_face_toggle(true)
local added = obs.obs_source_get_filter_by_name(cam, "Cartoon Face")
H.check(added ~= nil and added.enabled, "filter added and enabled")
M.hotkeys.cartoon_face_toggle(true)
H.check(not added.enabled, "filter disabled")
M.hotkeys.cartoon_face_toggle(true)
H.check(added.enabled, "re-enabled")
H.eq(#cam.filters, 1, "existing filter reused, not added twice")

-- Changing the webcam while on: the old camera goes back to normal, the new one turns cartoon
local cam2 = M.add_source("Webcam 2", "v4l2_input")
H.update(env, settings, { webcam = "Webcam 2" })
H.check(not added.enabled, "old webcam filter turned off")
local added2 = obs.obs_source_get_filter_by_name(cam2, "Cartoon Face")
H.check(added2 ~= nil and added2.enabled, "new webcam gets the filter")
H.update(env, settings, { webcam = "Webcam" })
H.check(added.enabled and not added2.enabled, "and back")

-- Switching to avatar mode while on: filter off, avatar shown, webcam hidden in every scene
H.update(env, settings, { mode = "avatar", avatar = "Avatar" })
H.check(not added.enabled, "filter off in avatar mode")
H.check(not cam_item.visible and av_item.visible, "avatar replaces webcam")
H.check(not cam_item2.visible, "webcam hidden in a scene without avatar too")
M.hotkeys.cartoon_face_toggle(true)
H.check(cam_item.visible and not av_item.visible and cam_item2.visible, "back to the real webcam")

env.script_save(settings)
H.finish("cartoon-face.lua", M)
