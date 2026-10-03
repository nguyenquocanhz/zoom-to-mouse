-- Minimal fake of the `obslua` module so OBS scripts can be loaded and driven by LuaJIT
-- outside of OBS. It only models what the scripts in this repo use; any other API name
-- a script touches is recorded in M.unknown so the test runner can flag typos.

local M = {}

M.clock_ns = 0
M.logs = {}
M.timers = {}
M.hotkeys = {}
M.frontend_callbacks = {}
M.sources = {}
M.current_scene = nil
M.unknown = {}
M.streaming = false
M.recording = false
M.recording_paused = false
M.replay_active = false
M.last_replay = nil
M.chapters = {}
M.calls = {}

local function record(name)
    M.calls[name] = (M.calls[name] or 0) + 1
end

-- obs_data ------------------------------------------------------------------
local function data_new()
    return { __data = true, vals = {}, defaults = {}, arrays = {} }
end

local function data_get(d, k)
    local v = d.vals[k]
    if v == nil then v = d.defaults[k] end
    return v
end

-- sources -------------------------------------------------------------------
function M.add_source(name, id, opts)
    opts = opts or {}
    local s = {
        __source = true, name = name, id = id, settings = data_new(), filters = {},
        width = opts.width or 1920, height = opts.height or 1080, enabled = true,
        media_state = opts.media_state or 0, active = opts.active ~= false,
    }
    if opts.scene then
        s.scene = { __scene = true, source = s, items = {} }
    end
    M.sources[name] = s
    return s
end

function M.add_item(scene_src, src, info)
    local item = {
        __item = true, source = src, scene = scene_src.scene,
        info = info or {
            pos = { x = 0, y = 0 }, rot = 0, scale = { x = 1, y = 1 }, alignment = 5,
            bounds_type = 0, bounds_alignment = 0, bounds = { x = 0, y = 0 }
        },
        crop = { left = 0, top = 0, right = 0, bottom = 0 },
        scale_filter = 0, visible = true,
    }
    table.insert(scene_src.scene.items, item)
    return item
end

local function copy_into(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            dst[k] = dst[k] or {}
            copy_into(dst[k], v)
        else
            dst[k] = v
        end
    end
end

local api = {
    OBS_LOG_ERROR = 100, OBS_LOG_WARNING = 200, OBS_LOG_INFO = 300, OBS_LOG_DEBUG = 400,
    OBS_COMBO_TYPE_LIST = 2, OBS_COMBO_TYPE_EDITABLE = 1, OBS_COMBO_FORMAT_STRING = 3, OBS_COMBO_FORMAT_INT = 1,
    OBS_TEXT_DEFAULT = 0, OBS_TEXT_MULTILINE = 2, OBS_TEXT_INFO = 3,
    OBS_PATH_FILE = 0, OBS_PATH_DIRECTORY = 2,
    OBS_EDITABLE_LIST_TYPE_STRINGS = 0,
    OBS_BOUNDS_NONE = 0, OBS_BOUNDS_SCALE_INNER = 2, OBS_ORDER_MOVE_BOTTOM = 3,
    OBS_SCALE_BICUBIC = 2, OBS_SCALE_BILINEAR = 3, OBS_SCALE_LANCZOS = 4, OBS_SCALE_AREA = 5,
    OBS_MEDIA_STATE_NONE = 0, OBS_MEDIA_STATE_PLAYING = 1, OBS_MEDIA_STATE_PAUSED = 4,
    OBS_MEDIA_STATE_STOPPED = 5, OBS_MEDIA_STATE_ENDED = 6, OBS_MEDIA_STATE_ERROR = 7,
    OBS_FRONTEND_EVENT_STREAMING_STARTED = 1, OBS_FRONTEND_EVENT_STREAMING_STOPPED = 3,
    OBS_FRONTEND_EVENT_RECORDING_STARTED = 5, OBS_FRONTEND_EVENT_RECORDING_STOPPED = 7,
    OBS_FRONTEND_EVENT_SCENE_CHANGED = 8, OBS_FRONTEND_EVENT_EXIT = 17,
    OBS_FRONTEND_EVENT_REPLAY_BUFFER_STARTED = 19, OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPED = 21,
    OBS_FRONTEND_EVENT_RECORDING_PAUSED = 23, OBS_FRONTEND_EVENT_RECORDING_UNPAUSED = 24,
    OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGING = 28, OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN = 30,
    OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED = 34, OBS_FRONTEND_EVENT_TRANSITION_STOPPED = 13,
}

function api.obs_get_version_string() return "30.2.3" end
function api.obs_get_frame_interval_ns() return 16666667 end
function api.os_gettime_ns() return M.clock_ns end
function api.script_log(level, msg) table.insert(M.logs, { level = level, msg = msg }) end
function api.script_path() return "/tmp/" end

function api.timer_add(fn, ms) M.timers[fn] = ms end
function api.timer_remove(fn) M.timers[fn] = nil end
function api.remove_current_callback() M.removed_current = true end

-- data
function api.obs_data_create() return data_new() end
function api.obs_data_release(d) end
function api.obs_data_get_string(d, k) return data_get(d, k) or "" end
function api.obs_data_get_int(d, k) return math.floor(data_get(d, k) or 0) end
function api.obs_data_get_double(d, k) return data_get(d, k) or 0 end
function api.obs_data_get_bool(d, k) return data_get(d, k) or false end
function api.obs_data_set_string(d, k, v) d.vals[k] = v end
function api.obs_data_set_int(d, k, v) d.vals[k] = v end
function api.obs_data_set_double(d, k, v) d.vals[k] = v end
function api.obs_data_set_bool(d, k, v) d.vals[k] = v end
function api.obs_data_set_default_string(d, k, v) d.defaults[k] = v end
function api.obs_data_set_default_int(d, k, v) d.defaults[k] = v end
function api.obs_data_set_default_double(d, k, v) d.defaults[k] = v end
function api.obs_data_set_default_bool(d, k, v) d.defaults[k] = v end
function api.obs_data_get_array(d, k) return d.arrays[k] or { __array = true, items = {} } end
function api.obs_data_set_array(d, k, a) d.arrays[k] = a end
function api.obs_data_array_release(a) end
function api.obs_data_array_count(a) return #a.items end
function api.obs_data_array_item(a, i) return a.items[i + 1] end
function api.obs_data_array_create() return { __array = true, items = {} } end
function api.obs_data_array_push_back(a, d) table.insert(a.items, d) end

-- properties
local function prop_new(name, kind)
    return { name = name, kind = kind, items = {}, visible = true }
end
function api.obs_properties_create() return { props = {} } end
function api.obs_properties_destroy(p) end
function api.obs_properties_get(p, name) return p.props[name] end
local function add_prop(kind)
    return function(p, name, ...)
        local pr = prop_new(name, kind)
        pr.args = { ... }
        p.props[name] = pr
        return pr
    end
end
api.obs_properties_add_bool = add_prop("bool")
api.obs_properties_add_int = add_prop("int")
api.obs_properties_add_int_slider = add_prop("int")
api.obs_properties_add_float = add_prop("float")
api.obs_properties_add_float_slider = add_prop("float")
api.obs_properties_add_text = add_prop("text")
api.obs_properties_add_path = add_prop("path")
api.obs_properties_add_list = add_prop("list")
api.obs_properties_add_editable_list = add_prop("editable_list")
function api.obs_properties_add_button(p, name, text, cb)
    local pr = prop_new(name, "button")
    pr.callback = cb
    p.props[name] = pr
    return pr
end
function api.obs_property_set_long_description(pr, d) end
function api.obs_property_set_visible(pr, v) assert(pr, "set_visible on nil property"); pr.visible = v end
function api.obs_property_set_enabled(pr, v) end
function api.obs_property_set_modified_callback(pr, cb) pr.modified = cb end
function api.obs_property_name(pr) return pr.name end
function api.obs_property_list_clear(pr) pr.items = {} end
function api.obs_property_list_add_string(pr, n, v) table.insert(pr.items, { n, v }) end
function api.obs_property_list_add_int(pr, n, v) table.insert(pr.items, { n, v }) end
function api.obs_property_list_item_count(pr) return #pr.items end
function api.obs_property_list_item_name(pr, i) return pr.items[i + 1][1] end
function api.obs_property_list_item_string(pr, i) return pr.items[i + 1][2] end
function api.obs_property_list_item_int(pr, i) return pr.items[i + 1][2] end
function api.obs_source_properties(s)
    local p = { props = {} }
    if s.prop_list then
        local pr = prop_new(s.prop_list.name, "list")
        pr.items = s.prop_list.items
        p.props[pr.name] = pr
    end
    return p
end

-- sources
function api.obs_get_source_by_name(n) return M.sources[n] end
function api.obs_source_release(s) end
function api.obs_source_get_name(s) return s.name end
function api.obs_source_get_id(s) return s.id end
function api.obs_source_get_unversioned_id(s) return (s.id:gsub("_v%d+$", "")) end
function api.obs_source_get_settings(s) return s.settings end
function api.obs_source_update(s, d) copy_into(s.settings.vals, d.vals); record("obs_source_update") end
function api.obs_source_get_width(s) return s.width end
function api.obs_source_get_height(s) return s.height end
function api.obs_source_get_base_width(s) return s.width end
function api.obs_source_get_base_height(s) return s.height end
function api.obs_source_active(s) return s.active end
function api.obs_source_showing(s) return s.active end
function api.obs_source_is_scene(s) return s.scene ~= nil end
function api.obs_source_set_enabled(s, v) s.enabled = v end
function api.obs_source_enabled(s) return s.enabled end
function api.obs_source_create_private(id, name, settings)
    local s = { __source = true, name = name, id = id, settings = data_new(), filters = {}, enabled = true }
    if settings then copy_into(s.settings.vals, settings.vals) end
    return s
end
function api.obs_source_filter_add(s, f) table.insert(s.filters, f) end
function api.obs_source_filter_remove(s, f)
    for i, x in ipairs(s.filters) do if x == f then table.remove(s.filters, i) return end end
end
function api.obs_source_filter_set_order(s, f, o)
    if o == api.OBS_ORDER_MOVE_BOTTOM then
        api.obs_source_filter_remove(s, f)
        table.insert(s.filters, f)
    end
end
function api.obs_source_get_ref(s) return s end
function api.obs_source_get_filter_by_name(s, n)
    for _, f in ipairs(s.filters) do if f.name == n then return f end end
    return nil
end
function api.obs_source_enum_filters(s) return s.filters end
function api.obs_enum_sources()
    local t = {}
    for _, s in pairs(M.sources) do if not s.scene then table.insert(t, s) end end
    table.sort(t, function(a, b) return a.name < b.name end)
    return t
end
function api.source_list_release(l) end
function api.obs_source_get_signal_handler(s) return {} end
function api.signal_handler_connect(h, sig, cb) end
function api.signal_handler_disconnect(h, sig, cb) end
function api.obs_source_media_get_state(s) return s.media_state end
function api.obs_source_media_restart(s) s.media_state = s.restart_state or 1; record("obs_source_media_restart") end
function api.obs_source_media_stop(s) s.media_state = 5 end
function api.obs_source_media_get_duration(s) return s.duration or 0 end
function api.obs_source_media_get_time(s) return s.time or 0 end

-- scenes
function api.obs_scene_from_source(s) return s.scene end
function api.obs_scene_get_source(sc) return sc.source end
function api.obs_scene_find_source(sc, name)
    for _, it in ipairs(sc.items) do if it.source.name == name then return it end end
    return nil
end
function api.obs_scene_enum_items(sc) return sc.items end
function api.sceneitem_list_release(l) end
function api.obs_sceneitem_addref(it) end
function api.obs_sceneitem_release(it) end
function api.obs_sceneitem_get_source(it) return it.source end
function api.obs_sceneitem_is_group(it) return false end
function api.obs_sceneitem_group_get_scene(it) return nil end
function api.obs_transform_info() return { pos = {}, scale = {}, bounds = {} } end
function api.obs_sceneitem_get_info2(it, info) copy_into(info, it.info) end
function api.obs_sceneitem_set_info2(it, info) copy_into(it.info, info); record("obs_sceneitem_set_info2") end
function api.obs_sceneitem_crop() return {} end
function api.obs_sceneitem_get_crop(it, c) copy_into(c, it.crop) end
function api.obs_sceneitem_set_crop(it, c) copy_into(it.crop, c) end
function api.obs_sceneitem_get_scale_filter(it) return it.scale_filter end
function api.obs_sceneitem_set_scale_filter(it, f) it.scale_filter = f end
function api.obs_sceneitem_visible(it) return it.visible end
function api.obs_sceneitem_set_visible(it, v) it.visible = v end

-- frontend
-- In OBS these calls block until the UI thread has run them, and the UI thread runs the script's
-- frontend event callbacks under the same script lock. So a script that registered a frontend
-- event callback deadlocks OBS if it calls them from a hotkey/timer (anything but a UI callback).
M.in_ui = false
local function ui_blocking(name)
    if #M.frontend_callbacks > 0 and not M.in_ui then
        error("DEADLOCK in real OBS: " .. name .. " called from a hotkey/timer by a script that " ..
            "registered a frontend event callback", 3)
    end
end
local function emit(event)
    local was = M.in_ui
    M.in_ui = true
    for _, cb in ipairs(M.frontend_callbacks) do cb(event) end
    M.in_ui = was
end
M.emit = emit
function api.obs_frontend_get_current_scene() return M.current_scene end
function api.obs_frontend_set_current_scene(s)
    ui_blocking("obs_frontend_set_current_scene")
    M.current_scene = s
    emit(api.OBS_FRONTEND_EVENT_SCENE_CHANGED)
end
function api.obs_frontend_get_scenes()
    local t = {}
    for _, s in pairs(M.sources) do if s.scene then table.insert(t, s) end end
    table.sort(t, function(a, b) return a.name < b.name end)
    return t
end
function api.obs_frontend_get_scene_names()
    local t = {}
    for _, s in ipairs(api.obs_frontend_get_scenes()) do table.insert(t, s.name) end
    return t
end
M.transitions = {}
M.current_transition = nil
M.transition_duration = 300
M.studio_mode = false
M.preview_scene = nil
function api.obs_frontend_get_transitions() local t = {} for i, x in ipairs(M.transitions) do t[i] = x end return t end
function api.obs_frontend_get_current_transition() return M.current_transition end
function api.obs_frontend_set_current_transition(t) ui_blocking("obs_frontend_set_current_transition"); M.current_transition = t end
function api.obs_frontend_get_transition_duration() return M.transition_duration end
function api.obs_frontend_set_transition_duration(d) M.transition_duration = d end
function api.obs_frontend_set_current_preview_scene(s) ui_blocking("obs_frontend_set_current_preview_scene"); M.preview_scene = s end
function api.obs_frontend_preview_program_trigger_transition()
    ui_blocking("obs_frontend_preview_program_trigger_transition")
    M.current_scene = M.preview_scene
    emit(api.OBS_FRONTEND_EVENT_SCENE_CHANGED)
end
function M.add_transition(name, id)
    local t = { __source = true, name = name, id = id, settings = data_new(), filters = {}, enabled = true }
    table.insert(M.transitions, t)
    return t
end
function api.obs_frontend_add_event_callback(cb) table.insert(M.frontend_callbacks, cb) end
function api.obs_frontend_remove_event_callback(cb)
    for i, x in ipairs(M.frontend_callbacks) do if x == cb then table.remove(M.frontend_callbacks, i) return end end
end
function api.obs_frontend_streaming_active() return M.streaming end
function api.obs_frontend_recording_active() return M.recording end
function api.obs_frontend_recording_paused() return M.recording_paused end
function api.obs_frontend_replay_buffer_active() return M.replay_active end
function api.obs_frontend_replay_buffer_save() record("obs_frontend_replay_buffer_save") end
function api.obs_frontend_get_last_replay() return M.last_replay end
function api.obs_frontend_recording_add_chapter(name) table.insert(M.chapters, name); return true end
function api.obs_frontend_get_current_record_output_path() return M.record_path or "/tmp" end
function api.obs_frontend_preview_program_mode_active() return M.studio_mode end
function api.obs_frontend_replay_buffer_start() M.replay_active = true; record("obs_frontend_replay_buffer_start") end
function api.obs_frontend_get_streaming_output() return M.streaming and { frames = M.stream_frames or 0 } or nil end
function api.obs_frontend_get_recording_output() return M.recording and { frames = M.record_frames or 0 } or nil end
function api.obs_output_get_total_frames(o) return o.frames end
function api.obs_output_release(o) end

-- hotkeys
function api.obs_hotkey_register_frontend(id, desc, cb)
    M.hotkeys[id] = cb
    return id
end
function api.obs_hotkey_unregister(cb) end
function api.obs_hotkey_load(id, arr) end
function api.obs_hotkey_save(id) return { __array = true, items = {} } end

-- graphics / source registration
api.OBS_SOURCE_TYPE_INPUT = 0
api.OBS_SOURCE_TYPE_FILTER = 1
api.OBS_SOURCE_VIDEO = 1
api.OBS_SOURCE_AUDIO = 2
api.GS_RGBA = 3
api.OBS_NO_DIRECT_RENDERING = 1
M.registered = {}
M.effect_params = {}
M.effect_fail = false
function api.obs_register_source(info) M.registered[info.id] = info end
function api.obs_enter_graphics() M.in_graphics = true end
function api.obs_leave_graphics() M.in_graphics = false end
function api.gs_effect_create(src, name, err)
    assert(M.in_graphics, "gs_effect_create outside obs_enter_graphics")
    if M.effect_fail then return nil end
    return { src = src }
end
function api.gs_effect_destroy(e) assert(M.in_graphics, "gs_effect_destroy outside graphics"); M.effect_destroyed = true end
function api.gs_effect_get_param_by_name(e, n)
    assert(e.src:find("uniform [%w]+ " .. n .. ";"), "effect has no uniform " .. n)
    return n
end
local function copy_vec(v) local t = {} for k, x in pairs(v) do t[k] = x end return t end
function api.gs_effect_set_float(p, v) assert(p and type(v) == "number", "set_float " .. tostring(p)); M.effect_params[p] = v end
function api.gs_effect_set_vec2(p, v) assert(p, "set_vec2 nil param"); M.effect_params[p] = copy_vec(v) end
function api.gs_effect_set_vec4(p, v) assert(p, "set_vec4 nil param"); M.effect_params[p] = copy_vec(v) end
function api.vec2() return { x = 0, y = 0 } end
function api.vec4() return { x = 0, y = 0, z = 0, w = 0 } end
function api.obs_filter_get_target(f) return f.target end
function api.obs_source_skip_video_filter(f) record("obs_source_skip_video_filter") end
function api.obs_source_process_filter_begin(f, fmt, mode) return true end
function api.obs_source_process_filter_end(f, e, w, h) M.rendered = { w = w, h = h }; record("obs_source_process_filter_end") end
function api.obs_source_get_output_flags(s) return s.flags or 1 end
function api.obs_source_create(id, name, settings, hotkeys)
    local s = { __source = true, name = name, id = id, settings = data_new(), filters = {}, enabled = true }
    return s
end
api.obs_properties_add_color = add_prop("color")
function api.obs_scene_find_source_recursive(sc, name) return api.obs_scene_find_source(sc, name) end

function api.gs_image_file()
    return { loaded = false, cx = 0, cy = 0, texture = nil }
end
function api.gs_image_file_init(img, path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        img.loaded, img.cx, img.cy = true, 256, 128
    end
    img.path = path
end
function api.gs_image_file_init_texture(img)
    assert(M.in_graphics, "init_texture outside graphics")
    if img.loaded then img.texture = { tex = img.path } end
end
function api.gs_image_file_free(img) assert(M.in_graphics, "image free outside graphics"); M.images_freed = (M.images_freed or 0) + 1 end
function api.gs_effect_set_texture(p, t) assert(p, "set_texture nil param"); M.effect_params[p] = t end

M.api = api

function M.fire(event)
    emit(event)
end

-- Run every registered timer whose period elapsed while advancing the clock by `ms`
function M.advance(ms, step)
    step = step or 1
    local elapsed = 0
    local next_fire = M.next_fire or {}
    M.next_fire = next_fire
    while elapsed < ms do
        elapsed = elapsed + step
        M.clock_ns = M.clock_ns + step * 1000000
        local due = {}
        for fn, period in pairs(M.timers) do
            next_fire[fn] = next_fire[fn] or (M.clock_ns + period * 1000000 - step * 1000000)
            if M.clock_ns >= next_fire[fn] then
                table.insert(due, fn)
                next_fire[fn] = M.clock_ns + period * 1000000
            end
        end
        for _, fn in ipairs(due) do
            if M.timers[fn] then fn() end
        end
        for fn in pairs(next_fire) do
            if not M.timers[fn] then next_fire[fn] = nil end
        end
    end
end

function M.install()
    _G.obslua = setmetatable(api, {
        __index = function(_, k)
            M.unknown[k] = true
            return nil
        end
    })
end

function M.settings()
    return data_new()
end

function M.log_text()
    local t = {}
    for _, l in ipairs(M.logs) do table.insert(t, l.msg) end
    return table.concat(t, "\n")
end

return M
