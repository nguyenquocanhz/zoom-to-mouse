local H = dofile((debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or ".") .. "/harness.lua")
local env, M = H.load("face-mask.lua")
local obs = obslua

local f = M.registered.algen_face_mask
H.check(f ~= nil, "filter registered")
H.eq(f.get_name(), "Face Mask (Mặt nạ)", "name")

local fs = M.settings()
f.get_defaults(fs)
local cam = M.add_source("Webcam", "v4l2_input", { width = 1280, height = 720 })
local inst = { name = "Face Mask", id = "algen_face_mask", target = cam }
local data = f.create(fs, inst)
H.check(data ~= nil, "created")
f.video_tick(data, 0)
f.video_render(data, nil)
local P = M.effect_params
H.eq(P.mode, 0, "hacker by default")
H.check(math.abs(P.aspect - 1280 / 720) < 1e-9, "frame aspect")
H.check(math.abs(P.size - 0.45) < 1e-9, "size as fraction of height")
H.check(math.abs(P.center.x - 0.5) < 1e-9 and math.abs(P.center.y - 0.4) < 1e-9, "center")
H.eq(P.blend_mode, 0, "over the original by default")
H.eq(P.eye_holes, 0, "no eye holes by default")

fs.vals.rotation = 90
fs.vals.mask = "neko"
fs.vals.blend = "mix"
fs.vals.eye_holes = true
fs.vals.ear_color = 0xFF0000FF -- red in 0xAABBGGRR
f.update(data, fs)
f.video_render(data, nil)
H.check(math.abs(P.rotation - math.pi / 2) < 1e-9, "rotation in radians")
H.eq(P.mode, 2, "neko")
H.eq(P.blend_mode, 1, "mix")
H.eq(P.eye_holes, 1, "eye holes")
H.check(P.tint.x == 1 and P.tint.y == 0 and P.tint.z == 0, "ear colour channels (red lands in .x)")

-- Image mode: nothing loaded -> pass through; a real file -> texture + its aspect
fs.vals.mask = "image"
fs.vals.image_path = "/no/such/file.png"
f.update(data, fs)
local skips = M.calls.obs_source_skip_video_filter or 0
f.video_render(data, nil)
H.eq(M.calls.obs_source_skip_video_filter, skips + 1, "image mode without image passes through")
local png = os.tmpname()
local fh = io.open(png, "w"); fh:write("x"); fh:close()
fs.vals.image_path = png
f.update(data, fs)
f.video_render(data, nil)
H.eq(P.mode, 3, "image mode")
H.eq(P.img_aspect, 2, "image aspect from file")
H.check(P.mask_img ~= nil and P.mask_img.tex == png, "texture bound")
local freed = M.images_freed or 0
f.update(data, fs) -- same path: no reload
H.eq(M.images_freed or 0, freed, "same image not reloaded")
fs.vals.image_path = ""
f.update(data, fs)
H.eq(M.images_freed, freed + 1, "old image freed when cleared")
os.remove(png)

-- Properties follow the chosen mask
local props = f.get_properties(data)
fs.vals.mask = "neko"
props.props.mask.modified(props, props.props.mask, fs)
H.check(props.props.ear_color.visible and not props.props.image_path.visible and not props.props.eye_holes.visible, "neko props")
fs.vals.mask = "hacker"
props.props.mask.modified(props, props.props.mask, fs)
H.check(props.props.eye_holes.visible and not props.props.ear_color.visible, "hacker props")

f.destroy(data)
H.check(M.effect_destroyed, "effect destroyed")

------------------------------------------------------------------------------
-- Script hotkeys, "đè lên ảnh gốc"
local cartoon = { __source = true, name = "Cartoon Face", id = "algen_cartoon_face", settings = M.settings(), filters = {}, enabled = true }
local color = { __source = true, name = "Color Correction", id = "color_filter_v2", settings = M.settings(), filters = {}, enabled = true }
table.insert(cam.filters, cartoon)
table.insert(cam.filters, color)

local settings = H.start(env, M, { webcam = "Webcam" })
M.hotkeys.face_mask_toggle(true)
local mask = obs.obs_source_get_filter_by_name(cam, "Face Mask")
H.check(mask ~= nil and mask.enabled, "mask added and on")
H.check(not cartoon.enabled, "cartoon paused while masked")
H.check(color.enabled, "other filters untouched")
H.eq(cam.filters[#cam.filters], mask, "mask is the last filter (on top)")

M.hotkeys.face_mask_next(true)
H.eq(mask.settings.vals.mask, "kitsune", "next -> kitsune")
M.hotkeys.face_mask_next(true)
H.eq(mask.settings.vals.mask, "neko", "next -> neko")
M.hotkeys.face_mask_next(true)
H.eq(mask.settings.vals.mask, "hacker", "image skipped while no PNG chosen")
mask.settings.vals.image_path = "/x.png"
mask.settings.vals.mask = "neko"
M.hotkeys.face_mask_next(true)
H.eq(mask.settings.vals.mask, "image", "image included once a PNG is set")
M.hotkeys.face_mask_next(true)
H.eq(mask.settings.vals.mask, "hacker", "wraps around")
H.check(not cartoon.enabled, "cycling keeps cartoon paused")

M.hotkeys.face_mask_toggle(true)
H.check(not mask.enabled, "mask off")
H.check(cartoon.enabled, "cartoon restored")
H.eq(#cam.filters, 3, "no duplicate mask filter")

-- The user adds a filter after the mask later: turning the mask on puts it back on top
local lut = { __source = true, name = "LUT", id = "clut_filter", settings = M.settings(), filters = {}, enabled = true }
table.insert(cam.filters, lut)
M.hotkeys.face_mask_toggle(true)
H.eq(cam.filters[#cam.filters], mask, "mask moved back on top of a newer filter")
M.hotkeys.face_mask_toggle(true)

-- A cartoon the user had turned off themselves stays off afterwards
cartoon.enabled = false
M.hotkeys.face_mask_toggle(true)
M.hotkeys.face_mask_toggle(true)
H.check(not cartoon.enabled, "user-disabled cartoon not turned on by us")

-- Option off: mask simply goes on top of whatever is there
cartoon.enabled = true
H.update(env, settings, { on_original = false })
M.hotkeys.face_mask_toggle(true)
H.check(mask.enabled and cartoon.enabled, "cartoon kept when on_original is off")
M.hotkeys.face_mask_toggle(true)

-- next while off turns the mask on (and pauses cartoon)
H.update(env, settings, { on_original = true })
M.hotkeys.face_mask_next(true)
H.check(mask.enabled and not cartoon.enabled, "next turns the mask on")

env.script_save(settings)
H.finish("face-mask.lua", M)
