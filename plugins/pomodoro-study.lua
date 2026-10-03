--[[
    Pomodoro "Study with me" — v1.0.0
    Đồng hồ Pomodoro cho stream học bài / làm việc cùng nhau.

    - Focus / nghỉ ngắn / nghỉ dài, số vòng trước khi nghỉ dài
    - Mẫu hiển thị: "{label} {time} · {cycle}/{total}" (+ {done} = số pomodoro đã xong)
    - Tự đổi scene theo pha (scene Focus / scene Break) — tùy chọn
    - Phát âm báo bằng một Media source khi đổi pha — tùy chọn
    - Hotkey: Start/Pause, Skip pha, Reset

    Author : nguyenquocanhz — License: MIT
]]--

local obs = obslua

local VERSION = "1.0.0"
local NONE = "<none>"
local TICK_MS = 250

local PHASE_FOCUS, PHASE_SHORT, PHASE_LONG = "focus", "short", "long"

local cfg = {
    text_source = "",
    focus_min = 25,
    short_min = 5,
    long_min = 15,
    cycles = 4,
    focus_label = "🍅 FOCUS",
    short_label = "☕ BREAK",
    long_label = "🌴 LONG BREAK",
    paused_label = "⏸",
    template = "{label} {time} · {cycle}/{total}",
    focus_scene = NONE,
    break_scene = NONE,
    sound_source = NONE,
    auto_continue = true,
}

local phase = PHASE_FOCUS
local cycle = 1
local done = 0
local running = false
local end_ns = 0
local remaining_ns = 0
local last_text = nil
local hotkey_ids = {}

local function log(msg)
    obs.script_log(obs.OBS_LOG_INFO, "[pomodoro] " .. msg)
end

local function is_text_source(s)
    local id = obs.obs_source_get_unversioned_id(s)
    return id == "text_gdiplus" or id == "text_ft2_source"
end

function phase_minutes(p)
    if p == PHASE_SHORT then return cfg.short_min end
    if p == PHASE_LONG then return cfg.long_min end
    return cfg.focus_min
end

function phase_label(p)
    if p == PHASE_SHORT then return cfg.short_label end
    if p == PHASE_LONG then return cfg.long_label end
    return cfg.focus_label
end

function format_time(sec)
    sec = math.max(0, math.ceil(sec))
    local h = math.floor(sec / 3600)
    local m = math.floor(sec % 3600 / 60)
    local s = sec % 60
    if h > 0 then
        return string.format("%d:%02d:%02d", h, m, s)
    end
    return string.format("%02d:%02d", m, s)
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
    local current = obs.obs_frontend_get_current_scene()
    if current ~= nil then
        local same = obs.obs_source_get_name(current) == name
        obs.obs_source_release(current)
        if same then
            return
        end
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

function play_sound()
    if cfg.sound_source == NONE or cfg.sound_source == "" then
        return
    end
    local source = obs.obs_get_source_by_name(cfg.sound_source)
    if source ~= nil then
        obs.obs_source_media_restart(source)
        obs.obs_source_release(source)
    end
end

function render()
    local ns = running and (end_ns - obs.os_gettime_ns()) or remaining_ns
    local label = phase_label(phase)
    if not running then
        label = cfg.paused_label .. " " .. label
    end
    local text = cfg.template
        :gsub("{label}", (label:gsub("%%", "%%%%")))
        :gsub("{time}", format_time(ns / 1000000000))
        :gsub("{cycle}", tostring(cycle))
        :gsub("{total}", tostring(cfg.cycles))
        :gsub("{done}", tostring(done))
    set_text(text)
end

function apply_phase_scene()
    if phase == PHASE_FOCUS then
        switch_scene(cfg.focus_scene)
    else
        switch_scene(cfg.break_scene)
    end
end

---
-- Move to the next phase. Focus -> short break (or long break every N cycles) -> focus ...
function next_phase()
    if phase == PHASE_FOCUS then
        done = done + 1
        if cycle >= cfg.cycles then
            phase = PHASE_LONG
        else
            phase = PHASE_SHORT
        end
    else
        if phase == PHASE_LONG then
            cycle = 1
        else
            cycle = cycle + 1
        end
        phase = PHASE_FOCUS
    end

    remaining_ns = phase_minutes(phase) * 60 * 1000000000
    log("Chuyển sang pha '" .. phase .. "' (vòng " .. cycle .. "/" .. cfg.cycles .. ")")
    play_sound()
    apply_phase_scene()

    if running then
        if cfg.auto_continue then
            -- Chain from the moment the phase really ended (not the tick that noticed it) so there is no drift
            end_ns = math.min(end_ns, obs.os_gettime_ns()) + remaining_ns
        else
            running = false
            obs.timer_remove(on_tick)
        end
    end
    render()
end

function on_tick()
    if not running then
        return
    end
    if obs.os_gettime_ns() >= end_ns then
        next_phase()
        return
    end
    render()
end

function start()
    if running then
        return
    end
    if remaining_ns <= 0 then
        remaining_ns = phase_minutes(phase) * 60 * 1000000000
    end
    running = true
    end_ns = obs.os_gettime_ns() + remaining_ns
    obs.timer_add(on_tick, TICK_MS)
    apply_phase_scene()
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
    phase = PHASE_FOCUS
    cycle = 1
    done = 0
    remaining_ns = cfg.focus_min * 60 * 1000000000
    render()
end

function skip()
    next_phase()
end

function on_start_pause(pressed)
    if not pressed then return end
    if running then pause() else start() end
end

function on_skip(pressed)
    if pressed then skip() end
end

function on_reset(pressed)
    if pressed then reset() end
end

------------------------------------------------------------------------------
-- OBS script API

function script_description()
    return "<b>Pomodoro Study v" .. VERSION .. "</b><br>" ..
        "Đồng hồ Pomodoro cho stream \"study with me\". Biến trong mẫu: " ..
        "<code>{label} {time} {cycle} {total} {done}</code>"
end

local function add_scene_list(props, id, label)
    local list = obs.obs_properties_add_list(props, id, label, obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(list, "(không đổi scene)", NONE)
    local scenes = obs.obs_frontend_get_scenes()
    if scenes ~= nil then
        for _, scene in ipairs(scenes) do
            local name = obs.obs_source_get_name(scene)
            obs.obs_property_list_add_string(list, name, name)
        end
        obs.source_list_release(scenes)
    end
end

function script_properties()
    local props = obs.obs_properties_create()

    local text_list = obs.obs_properties_add_list(props, "text_source", "Text source",
        obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
    local sound_list = obs.obs_properties_add_list(props, "sound_source", "Âm báo (Media source)",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(sound_list, "(không phát)", NONE)

    local sources = obs.obs_enum_sources()
    if sources ~= nil then
        for _, s in ipairs(sources) do
            local name = obs.obs_source_get_name(s)
            if is_text_source(s) then
                obs.obs_property_list_add_string(text_list, name, name)
            elseif obs.obs_source_get_unversioned_id(s) == "ffmpeg_source" then
                obs.obs_property_list_add_string(sound_list, name, name)
            end
        end
        obs.source_list_release(sources)
    end

    obs.obs_properties_add_int(props, "focus_min", "Focus (phút)", 1, 180, 1)
    obs.obs_properties_add_int(props, "short_min", "Nghỉ ngắn (phút)", 1, 60, 1)
    obs.obs_properties_add_int(props, "long_min", "Nghỉ dài (phút)", 1, 120, 1)
    obs.obs_properties_add_int(props, "cycles", "Số vòng trước nghỉ dài", 1, 12, 1)

    obs.obs_properties_add_text(props, "focus_label", "Nhãn Focus", obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_text(props, "short_label", "Nhãn nghỉ ngắn", obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_text(props, "long_label", "Nhãn nghỉ dài", obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_text(props, "template", "Mẫu hiển thị", obs.OBS_TEXT_DEFAULT)

    add_scene_list(props, "focus_scene", "Scene khi Focus")
    add_scene_list(props, "break_scene", "Scene khi nghỉ")

    obs.obs_properties_add_bool(props, "auto_continue", "Tự chạy pha tiếp theo")

    obs.obs_properties_add_button(props, "btn_start", "Start / Pause", function() on_start_pause(true) return false end)
    obs.obs_properties_add_button(props, "btn_skip", "Skip pha", function() skip() return false end)
    obs.obs_properties_add_button(props, "btn_reset", "Reset", function() reset() return false end)

    return props
end

function script_defaults(settings)
    obs.obs_data_set_default_int(settings, "focus_min", 25)
    obs.obs_data_set_default_int(settings, "short_min", 5)
    obs.obs_data_set_default_int(settings, "long_min", 15)
    obs.obs_data_set_default_int(settings, "cycles", 4)
    obs.obs_data_set_default_string(settings, "focus_label", "🍅 FOCUS")
    obs.obs_data_set_default_string(settings, "short_label", "☕ BREAK")
    obs.obs_data_set_default_string(settings, "long_label", "🌴 LONG BREAK")
    obs.obs_data_set_default_string(settings, "template", "{label} {time} · {cycle}/{total}")
    obs.obs_data_set_default_string(settings, "focus_scene", NONE)
    obs.obs_data_set_default_string(settings, "break_scene", NONE)
    obs.obs_data_set_default_string(settings, "sound_source", NONE)
    obs.obs_data_set_default_bool(settings, "auto_continue", true)
end

function script_update(settings)
    local old_phase_ns = phase_minutes(phase) * 60 * 1000000000

    cfg.text_source = obs.obs_data_get_string(settings, "text_source")
    cfg.focus_min = obs.obs_data_get_int(settings, "focus_min")
    cfg.short_min = obs.obs_data_get_int(settings, "short_min")
    cfg.long_min = obs.obs_data_get_int(settings, "long_min")
    cfg.cycles = obs.obs_data_get_int(settings, "cycles")
    cfg.focus_label = obs.obs_data_get_string(settings, "focus_label")
    cfg.short_label = obs.obs_data_get_string(settings, "short_label")
    cfg.long_label = obs.obs_data_get_string(settings, "long_label")
    cfg.template = obs.obs_data_get_string(settings, "template")
    cfg.focus_scene = obs.obs_data_get_string(settings, "focus_scene")
    cfg.break_scene = obs.obs_data_get_string(settings, "break_scene")
    cfg.sound_source = obs.obs_data_get_string(settings, "sound_source")
    cfg.auto_continue = obs.obs_data_get_bool(settings, "auto_continue")

    -- A phase that hasn't started yet picks up the new length
    if not running and (remaining_ns <= 0 or remaining_ns == old_phase_ns) then
        remaining_ns = phase_minutes(phase) * 60 * 1000000000
    end
    last_text = nil
    render()
end

local HOTKEYS = {
    { "pomodoro_start_pause", "Pomodoro: Start / Pause", on_start_pause },
    { "pomodoro_skip", "Pomodoro: Skip pha", on_skip },
    { "pomodoro_reset", "Pomodoro: Reset", on_reset },
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
end
