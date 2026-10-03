--[[
    Countdown Pro — v1.0.0
    Đếm ngược "Starting soon" vào một Text source, hết giờ thì tự chuyển scene.

    - Hai chế độ: đếm theo thời lượng (vd 5:00) hoặc tới một giờ cụ thể (vd 20:00)
    - Mẫu hiển thị tùy biến: "Bắt đầu sau {time}"
    - Tự chạy khi Text source xuất hiện trên Program (tùy chọn)
    - Hotkey: Start/Pause, Reset, +1 phút (khi bị trễ giờ)

    Author : nguyenquocanhz — License: MIT
]]--

local obs = obslua

local VERSION = "1.0.0"
local NONE = "<none>"
local TICK_MS = 200

local cfg = {
    text_source = "",
    mode = "duration",
    duration_min = 5,
    duration_sec = 0,
    target_time = "20:00",
    time_format = "auto",
    template = "Bắt đầu sau {time}",
    end_text = "Bắt đầu thôi!",
    end_scene = NONE,
    auto_start = true,
}

local running = false
local finished = false
local end_ns = 0
local remaining_ns = 0
local last_text = nil
local hooked_source_name = nil
local hotkey_ids = {}

local function log(msg)
    obs.script_log(obs.OBS_LOG_INFO, "[countdown] " .. msg)
end

local function is_text_source(s)
    local id = obs.obs_source_get_unversioned_id(s)
    return id == "text_gdiplus" or id == "text_ft2_source"
end

---
-- Seconds -> "MM:SS" or "HH:MM:SS"
function format_time(sec, fmt)
    sec = math.max(0, math.ceil(sec))
    local h = math.floor(sec / 3600)
    local m = math.floor(sec % 3600 / 60)
    local s = sec % 60
    if fmt == "hh:mm:ss" or (fmt == "auto" and h > 0) then
        return string.format("%02d:%02d:%02d", h, m, s)
    end
    return string.format("%02d:%02d", h * 60 + m, s)
end

function set_text(text)
    if text == last_text then
        return
    end
    local source = obs.obs_get_source_by_name(cfg.text_source)
    if source ~= nil then
        local settings = obs.obs_data_create()
        obs.obs_data_set_string(settings, "text", text)
        obs.obs_source_update(source, settings)
        obs.obs_data_release(settings)
        obs.obs_source_release(source)
        last_text = text
    end
end

function switch_scene(name)
    if name == nil or name == "" or name == NONE then
        return
    end
    local scenes = obs.obs_frontend_get_scenes()
    if scenes ~= nil then
        for _, scene in ipairs(scenes) do
            if obs.obs_source_get_name(scene) == name then
                obs.obs_frontend_set_current_scene(scene)
                break
            end
        end
        obs.source_list_release(scenes)
    end
end

---
-- Seconds from now until the next HH:MM (tomorrow if it already passed today)
function seconds_until(hhmm)
    local h, m = tostring(hhmm):match("^%s*(%d%d?):(%d%d)%s*$")
    h, m = tonumber(h), tonumber(m)
    if h == nil or m == nil or h > 23 or m > 59 then
        return nil
    end
    local now = os.time()
    local t = os.date("*t", now)
    t.hour, t.min, t.sec = h, m, 0
    local target = os.time(t)
    if target <= now then
        target = target + 86400
    end
    return target - now
end

function full_duration_ns()
    if cfg.mode == "clock" then
        local sec = seconds_until(cfg.target_time)
        if sec == nil then
            log("Giờ đích không hợp lệ: '" .. tostring(cfg.target_time) .. "' (định dạng HH:MM)")
            return 0
        end
        return sec * 1000000000
    end
    return (cfg.duration_min * 60 + cfg.duration_sec) * 1000000000
end

function render()
    if finished then
        set_text(cfg.end_text)
        return
    end
    local ns = running and (end_ns - obs.os_gettime_ns()) or remaining_ns
    local text = cfg.template:gsub("{time}", format_time(ns / 1000000000, cfg.time_format))
    set_text(text)
end

function on_tick()
    if not running then
        return
    end
    if obs.os_gettime_ns() >= end_ns then
        running = false
        finished = true
        remaining_ns = 0
        obs.timer_remove(on_tick)
        render()
        log("Hết giờ")
        switch_scene(cfg.end_scene)
        return
    end
    render()
end

function start()
    if running then
        return
    end
    if finished or remaining_ns <= 0 then
        remaining_ns = full_duration_ns()
        finished = false
    end
    if remaining_ns <= 0 then
        return
    end
    running = true
    end_ns = obs.os_gettime_ns() + remaining_ns
    obs.timer_add(on_tick, TICK_MS)
    render()
end

function pause()
    if not running then
        return
    end
    running = false
    remaining_ns = math.max(0, end_ns - obs.os_gettime_ns())
    obs.timer_remove(on_tick)
    render()
end

function reset()
    pause()
    finished = false
    remaining_ns = full_duration_ns()
    render()
end

function add_minute()
    finished = false
    if running then
        end_ns = end_ns + 60 * 1000000000
    else
        remaining_ns = math.max(0, remaining_ns) + 60 * 1000000000
    end
    render()
end

function on_start_pause(pressed)
    if not pressed then return end
    if running then pause() else start() end
end

function on_reset(pressed)
    if pressed then reset() end
end

function on_add_minute(pressed)
    if pressed then add_minute() end
end

-- Auto start when the text source becomes visible on program, like the bundled countdown.lua
function on_source_activate(cd)
    if cfg.auto_start and not running then
        reset()
        start()
    end
end

function on_source_deactivate(cd)
    if cfg.auto_start then
        pause()
    end
end

function hook_source(name)
    if hooked_source_name == name then
        return
    end
    unhook_source()
    local source = obs.obs_get_source_by_name(name)
    if source ~= nil then
        local sh = obs.obs_source_get_signal_handler(source)
        obs.signal_handler_connect(sh, "activate", on_source_activate)
        obs.signal_handler_connect(sh, "deactivate", on_source_deactivate)
        obs.obs_source_release(source)
        hooked_source_name = name
    end
end

function unhook_source()
    if hooked_source_name == nil then
        return
    end
    local source = obs.obs_get_source_by_name(hooked_source_name)
    if source ~= nil then
        local sh = obs.obs_source_get_signal_handler(source)
        obs.signal_handler_disconnect(sh, "activate", on_source_activate)
        obs.signal_handler_disconnect(sh, "deactivate", on_source_deactivate)
        obs.obs_source_release(source)
    end
    hooked_source_name = nil
end

------------------------------------------------------------------------------
-- OBS script API

function script_description()
    return "<b>Countdown Pro v" .. VERSION .. "</b><br>" ..
        "Đếm ngược vào Text source (theo thời lượng hoặc tới giờ cố định), hết giờ tự chuyển scene.<br>" ..
        "Dùng <code>{time}</code> trong mẫu hiển thị."
end

function script_properties()
    local props = obs.obs_properties_create()

    local list = obs.obs_properties_add_list(props, "text_source", "Text source",
        obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
    local sources = obs.obs_enum_sources()
    if sources ~= nil then
        for _, s in ipairs(sources) do
            if is_text_source(s) then
                local name = obs.obs_source_get_name(s)
                obs.obs_property_list_add_string(list, name, name)
            end
        end
        obs.source_list_release(sources)
    end

    local mode = obs.obs_properties_add_list(props, "mode", "Chế độ",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(mode, "Đếm theo thời lượng", "duration")
    obs.obs_property_list_add_string(mode, "Đếm tới giờ cố định (HH:MM)", "clock")

    obs.obs_properties_add_int(props, "duration_min", "Phút", 0, 600, 1)
    obs.obs_properties_add_int(props, "duration_sec", "Giây", 0, 59, 1)
    obs.obs_properties_add_text(props, "target_time", "Giờ đích (HH:MM)", obs.OBS_TEXT_DEFAULT)

    local fmt = obs.obs_properties_add_list(props, "time_format", "Định dạng",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(fmt, "Tự động (MM:SS, có giờ thì HH:MM:SS)", "auto")
    obs.obs_property_list_add_string(fmt, "MM:SS", "mm:ss")
    obs.obs_property_list_add_string(fmt, "HH:MM:SS", "hh:mm:ss")

    obs.obs_properties_add_text(props, "template", "Mẫu hiển thị", obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_text(props, "end_text", "Chữ khi hết giờ", obs.OBS_TEXT_DEFAULT)

    local scene_list = obs.obs_properties_add_list(props, "end_scene", "Hết giờ chuyển sang scene",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(scene_list, "(không chuyển)", NONE)
    local scenes = obs.obs_frontend_get_scenes()
    if scenes ~= nil then
        for _, scene in ipairs(scenes) do
            local name = obs.obs_source_get_name(scene)
            obs.obs_property_list_add_string(scene_list, name, name)
        end
        obs.source_list_release(scenes)
    end

    obs.obs_properties_add_bool(props, "auto_start", "Tự chạy khi Text source hiện trên Program")

    obs.obs_properties_add_button(props, "btn_start", "Start / Pause", function() on_start_pause(true) return false end)
    obs.obs_properties_add_button(props, "btn_reset", "Reset", function() reset() return false end)
    obs.obs_properties_add_button(props, "btn_add", "+1 phút", function() add_minute() return false end)

    return props
end

function script_defaults(settings)
    obs.obs_data_set_default_string(settings, "mode", "duration")
    obs.obs_data_set_default_int(settings, "duration_min", 5)
    obs.obs_data_set_default_int(settings, "duration_sec", 0)
    obs.obs_data_set_default_string(settings, "target_time", "20:00")
    obs.obs_data_set_default_string(settings, "time_format", "auto")
    obs.obs_data_set_default_string(settings, "template", "Bắt đầu sau {time}")
    obs.obs_data_set_default_string(settings, "end_text", "Bắt đầu thôi!")
    obs.obs_data_set_default_string(settings, "end_scene", NONE)
    obs.obs_data_set_default_bool(settings, "auto_start", true)
end

function script_update(settings)
    local old_duration = full_duration_ns()
    cfg.text_source = obs.obs_data_get_string(settings, "text_source")
    cfg.mode = obs.obs_data_get_string(settings, "mode")
    cfg.duration_min = obs.obs_data_get_int(settings, "duration_min")
    cfg.duration_sec = obs.obs_data_get_int(settings, "duration_sec")
    cfg.target_time = obs.obs_data_get_string(settings, "target_time")
    cfg.time_format = obs.obs_data_get_string(settings, "time_format")
    cfg.template = obs.obs_data_get_string(settings, "template")
    cfg.end_text = obs.obs_data_get_string(settings, "end_text")
    cfg.end_scene = obs.obs_data_get_string(settings, "end_scene")
    cfg.auto_start = obs.obs_data_get_bool(settings, "auto_start")

    hook_source(cfg.text_source)
    last_text = nil

    -- Show the new duration right away while idle
    if not running and (remaining_ns <= 0 or remaining_ns == old_duration) then
        remaining_ns = full_duration_ns()
        finished = false
    end
    render()
end

local HOTKEYS = {
    { "countdown_pro_start_pause", "Countdown: Start / Pause", on_start_pause },
    { "countdown_pro_reset", "Countdown: Reset", on_reset },
    { "countdown_pro_add_minute", "Countdown: +1 phút", on_add_minute },
}

function script_load(settings)
    for _, hk in ipairs(HOTKEYS) do
        local id = obs.obs_hotkey_register_frontend(hk[1], hk[2], hk[3])
        local arr = obs.obs_data_get_array(settings, hk[1])
        obs.obs_hotkey_load(id, arr)
        obs.obs_data_array_release(arr)
        hotkey_ids[hk[1]] = id
    end
end

function script_save(settings)
    for _, hk in ipairs(HOTKEYS) do
        local arr = obs.obs_hotkey_save(hotkey_ids[hk[1]])
        obs.obs_data_set_array(settings, hk[1], arr)
        obs.obs_data_array_release(arr)
    end
end

function script_unload()
    obs.timer_remove(on_tick)
    unhook_source()
end
