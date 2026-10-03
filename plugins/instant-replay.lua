--[[
    Instant Replay — v1.0.0
    Một phím: lưu Replay Buffer -> phát lại ngay trên scene Replay (có slow-motion) -> tự quay về scene cũ.

    Yêu cầu: bật Replay Buffer (Settings → Output → Replay Buffer) và một Media Source trên scene Replay.

    Author : nguyenquocanhz — License: MIT
]]--

local obs = obslua

local VERSION = "1.0.0"
local NONE = "<none>"
local WATCH_MS = 250
local START_GRACE_S = 1.5 -- media may report "ended/stopped" for a moment before it starts playing
local SAVE_POLL_MS = 200
local SAVE_TIMEOUT_S = 15

local cfg = {
    media_source = NONE,
    replay_scene = NONE,
    max_seconds = 20,
    speed_percent = 100,
    return_to_previous = true,
    auto_start_buffer = true,
}

local pending_save = false
local replay_before = nil
local save_requested_at = 0
local playing = false
local play_started = 0
local previous_scene = nil
local hotkey_ids = {}

local function log(msg)
    obs.script_log(obs.OBS_LOG_INFO, "[replay] " .. msg)
end

local function now_sec()
    return obs.os_gettime_ns() / 1000000000
end

local function current_scene_name()
    local scene = obs.obs_frontend_get_current_scene()
    if scene == nil then
        return nil
    end
    local name = obs.obs_source_get_name(scene)
    obs.obs_source_release(scene)
    return name
end

function switch_scene(name)
    if name == nil or name == NONE then
        return false
    end
    local found = false
    local scenes = obs.obs_frontend_get_scenes()
    if scenes ~= nil then
        for _, scene in ipairs(scenes) do
            if obs.obs_source_get_name(scene) == name then
                obs.obs_frontend_set_current_scene(scene)
                found = true
                break
            end
        end
        obs.source_list_release(scenes)
    end
    return found
end

function request_replay()
    if cfg.media_source == NONE or cfg.replay_scene == NONE then
        log("Chưa chọn Media source / scene Replay trong cài đặt script")
        return
    end

    if not obs.obs_frontend_replay_buffer_active() then
        if cfg.auto_start_buffer then
            obs.obs_frontend_replay_buffer_start()
            log("Replay Buffer chưa chạy -> đã bật. Bấm lại sau vài giây khi buffer có dữ liệu.")
        else
            log("Replay Buffer chưa chạy. Bật nó trong Controls → Start Replay Buffer.")
        end
        return
    end

    -- The new file is detected by polling obs_frontend_get_last_replay() instead of listening to
    -- OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED: a script with a frontend event callback must not switch
    -- scenes from a timer (the watch timer does), or OBS deadlocks on the script lock.
    pending_save = true
    replay_before = obs.obs_frontend_get_last_replay() or ""
    save_requested_at = now_sec()
    obs.timer_remove(on_save_poll)
    obs.timer_add(on_save_poll, SAVE_POLL_MS)
    obs.obs_frontend_replay_buffer_save()
    log("Đang lưu replay...")
end

function on_save_poll()
    if not pending_save then
        obs.timer_remove(on_save_poll)
        return
    end
    local path = obs.obs_frontend_get_last_replay()
    if path ~= nil and path ~= "" and path ~= replay_before then
        pending_save = false
        obs.timer_remove(on_save_poll)
        play_file(path)
    elseif now_sec() - save_requested_at > SAVE_TIMEOUT_S then
        pending_save = false
        obs.timer_remove(on_save_poll)
        log("OBS không lưu được replay (kiểm tra Replay Buffer trong Settings → Output)")
    end
end

function play_file(path)
    local media = obs.obs_get_source_by_name(cfg.media_source)
    if media == nil then
        log("Không tìm thấy Media source '" .. cfg.media_source .. "'")
        return
    end

    local settings = obs.obs_data_create()
    obs.obs_data_set_bool(settings, "is_local_file", true)
    obs.obs_data_set_string(settings, "local_file", path)
    obs.obs_data_set_bool(settings, "looping", false)
    obs.obs_data_set_bool(settings, "restart_on_activate", true)
    obs.obs_data_set_int(settings, "speed_percent", cfg.speed_percent)
    obs.obs_source_update(media, settings)
    obs.obs_data_release(settings)

    local current = current_scene_name()
    if current ~= cfg.replay_scene then
        previous_scene = current
    end
    switch_scene(cfg.replay_scene)
    obs.obs_source_media_restart(media)
    obs.obs_source_release(media)

    playing = true
    play_started = now_sec()
    obs.timer_remove(on_watch)
    obs.timer_add(on_watch, WATCH_MS)
    log("Phát replay: " .. path)
end

function stop_replay()
    if not playing then
        return
    end
    playing = false
    obs.timer_remove(on_watch)

    local media = obs.obs_get_source_by_name(cfg.media_source)
    if media ~= nil then
        obs.obs_source_media_stop(media)
        obs.obs_source_release(media)
    end

    -- Only go back if the user is still on the replay scene
    if cfg.return_to_previous and previous_scene ~= nil and current_scene_name() == cfg.replay_scene then
        switch_scene(previous_scene)
    end
    previous_scene = nil
end

function on_watch()
    if not playing then
        obs.timer_remove(on_watch)
        return
    end

    local elapsed = now_sec() - play_started
    if cfg.max_seconds > 0 and elapsed >= cfg.max_seconds then
        log("Hết thời lượng replay")
        stop_replay()
        return
    end

    if elapsed > START_GRACE_S then
        local media = obs.obs_get_source_by_name(cfg.media_source)
        if media ~= nil then
            local state = obs.obs_source_media_get_state(media)
            obs.obs_source_release(media)
            if state == obs.OBS_MEDIA_STATE_ENDED or state == obs.OBS_MEDIA_STATE_STOPPED
                or state == obs.OBS_MEDIA_STATE_ERROR then
                stop_replay()
            end
        end
    end
end

function on_replay_hotkey(pressed)
    if pressed then request_replay() end
end

function on_stop_hotkey(pressed)
    if pressed then stop_replay() end
end

------------------------------------------------------------------------------
-- OBS script API

function script_description()
    return "<b>Instant Replay v" .. VERSION .. "</b><br>" ..
        "Bấm 1 phím: lưu Replay Buffer, phát lại ngay trên scene Replay (hỗ trợ slow-motion) rồi tự quay về.<br>" ..
        "Cần bật <i>Settings → Output → Replay Buffer</i>."
end

function script_properties()
    local props = obs.obs_properties_create()

    local media_list = obs.obs_properties_add_list(props, "media_source", "Media source phát replay",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(media_list, "(chọn)", NONE)
    local sources = obs.obs_enum_sources()
    if sources ~= nil then
        for _, s in ipairs(sources) do
            if obs.obs_source_get_unversioned_id(s) == "ffmpeg_source" then
                local name = obs.obs_source_get_name(s)
                obs.obs_property_list_add_string(media_list, name, name)
            end
        end
        obs.source_list_release(sources)
    end

    local scene_list = obs.obs_properties_add_list(props, "replay_scene", "Scene Replay",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(scene_list, "(chọn)", NONE)
    local scenes = obs.obs_frontend_get_scenes()
    if scenes ~= nil then
        for _, scene in ipairs(scenes) do
            local name = obs.obs_source_get_name(scene)
            obs.obs_property_list_add_string(scene_list, name, name)
        end
        obs.source_list_release(scenes)
    end

    obs.obs_properties_add_int_slider(props, "speed_percent", "Tốc độ phát (%) — 50 = slow-motion", 10, 200, 5)
    obs.obs_properties_add_int(props, "max_seconds", "Phát tối đa (giây, 0 = hết video)", 0, 600, 1)
    obs.obs_properties_add_bool(props, "return_to_previous", "Phát xong quay về scene trước")
    obs.obs_properties_add_bool(props, "auto_start_buffer", "Tự bật Replay Buffer nếu đang tắt")

    obs.obs_properties_add_button(props, "btn_replay", "Replay ngay", function() request_replay() return false end)
    obs.obs_properties_add_button(props, "btn_stop", "Dừng replay", function() stop_replay() return false end)

    return props
end

function script_defaults(settings)
    obs.obs_data_set_default_string(settings, "media_source", NONE)
    obs.obs_data_set_default_string(settings, "replay_scene", NONE)
    obs.obs_data_set_default_int(settings, "speed_percent", 100)
    obs.obs_data_set_default_int(settings, "max_seconds", 20)
    obs.obs_data_set_default_bool(settings, "return_to_previous", true)
    obs.obs_data_set_default_bool(settings, "auto_start_buffer", true)
end

function script_update(settings)
    cfg.media_source = obs.obs_data_get_string(settings, "media_source")
    cfg.replay_scene = obs.obs_data_get_string(settings, "replay_scene")
    cfg.speed_percent = obs.obs_data_get_int(settings, "speed_percent")
    cfg.max_seconds = obs.obs_data_get_int(settings, "max_seconds")
    cfg.return_to_previous = obs.obs_data_get_bool(settings, "return_to_previous")
    cfg.auto_start_buffer = obs.obs_data_get_bool(settings, "auto_start_buffer")
end

local HOTKEYS = {
    { "instant_replay_play", "Instant Replay: Lưu & phát lại", on_replay_hotkey },
    { "instant_replay_stop", "Instant Replay: Dừng", on_stop_hotkey },
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
    obs.timer_remove(on_watch)
    obs.timer_remove(on_save_poll)
end
