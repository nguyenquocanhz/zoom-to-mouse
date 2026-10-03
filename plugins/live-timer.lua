--[[
    Live Timer — v1.0.0
    Hiện "🔴 LIVE 01:23:45" / "⏺ REC 00:10:02" lên một Text source, tự ẩn khi offline.

    - Mẫu riêng cho Live, Rec, và khi cả hai cùng chạy
    - Thời gian Rec trừ phần Pause, hiện nhãn ⏸ khi đang Pause
    - Reload script giữa buổi live vẫn tính đúng (lấy số frame output đã gửi)

    Author : nguyenquocanhz — License: MIT
]]--

local obs = obslua

local VERSION = "1.0.0"
local TICK_MS = 500

local cfg = {
    text_source = "",
    live_format = "🔴 LIVE {stream}",
    rec_format = "⏺ REC {rec}",
    both_format = "🔴 LIVE {stream} · ⏺ REC {rec}",
    paused_format = "⏸ PAUSED {rec}",
    offline_text = "",
}

local clocks = {
    stream = { start = nil, paused = 0, pause_start = nil },
    record = { start = nil, paused = 0, pause_start = nil },
}
local last_text = nil

local function now_ns()
    return obs.os_gettime_ns()
end

function clock_elapsed(c)
    if c.start == nil then
        return 0
    end
    local paused = c.paused + (c.pause_start and (now_ns() - c.pause_start) or 0)
    return math.max(0, (now_ns() - c.start - paused) / 1000000000)
end

function format_hms(sec)
    sec = math.floor(sec)
    return string.format("%02d:%02d:%02d", math.floor(sec / 3600), math.floor(sec % 3600 / 60), sec % 60)
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

function build_text()
    local live = clocks.stream.start ~= nil
    local rec = clocks.record.start ~= nil
    local paused = clocks.record.pause_start ~= nil

    local fmt
    if live and rec then
        fmt = cfg.both_format
    elseif live then
        fmt = cfg.live_format
    elseif rec then
        fmt = paused and cfg.paused_format or cfg.rec_format
    else
        return cfg.offline_text
    end

    local text = fmt:gsub("{stream}", format_hms(clock_elapsed(clocks.stream)))
        :gsub("{rec}", format_hms(clock_elapsed(clocks.record)))
    return text
end

function on_tick()
    set_text(build_text())
end

function on_event(event)
    local now = now_ns()
    if event == obs.OBS_FRONTEND_EVENT_STREAMING_STARTED then
        clocks.stream.start, clocks.stream.paused, clocks.stream.pause_start = now, 0, nil
    elseif event == obs.OBS_FRONTEND_EVENT_STREAMING_STOPPED then
        clocks.stream.start = nil
    elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_STARTED then
        clocks.record.start, clocks.record.paused, clocks.record.pause_start = now, 0, nil
    elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED then
        clocks.record.start, clocks.record.pause_start = nil, nil
    elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_PAUSED then
        clocks.record.pause_start = now
    elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_UNPAUSED then
        if clocks.record.pause_start then
            clocks.record.paused = clocks.record.paused + (now - clocks.record.pause_start)
            clocks.record.pause_start = nil
        end
    end
    on_tick()
end

local function resume_clock(c, output, paused)
    if output == nil then
        return
    end
    local frames = obs.obs_output_get_total_frames(output)
    obs.obs_output_release(output)
    c.start = now_ns() - frames * obs.obs_get_frame_interval_ns()
    c.paused = 0
    c.pause_start = paused and now_ns() or nil
end

------------------------------------------------------------------------------
-- OBS script API

function script_description()
    return "<b>Live Timer v" .. VERSION .. "</b><br>" ..
        "Hiện thời gian Live/Rec lên Text source. Biến: <code>{stream}</code>, <code>{rec}</code>."
end

function script_properties()
    local props = obs.obs_properties_create()

    local list = obs.obs_properties_add_list(props, "text_source", "Text source",
        obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
    local sources = obs.obs_enum_sources()
    if sources ~= nil then
        for _, s in ipairs(sources) do
            local id = obs.obs_source_get_unversioned_id(s)
            if id == "text_gdiplus" or id == "text_ft2_source" then
                local name = obs.obs_source_get_name(s)
                obs.obs_property_list_add_string(list, name, name)
            end
        end
        obs.source_list_release(sources)
    end

    obs.obs_properties_add_text(props, "live_format", "Khi Live", obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_text(props, "rec_format", "Khi Rec", obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_text(props, "both_format", "Khi Live + Rec", obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_text(props, "paused_format", "Khi Rec đang Pause", obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_text(props, "offline_text", "Khi offline (trống = ẩn chữ)", obs.OBS_TEXT_DEFAULT)

    return props
end

function script_defaults(settings)
    obs.obs_data_set_default_string(settings, "live_format", "🔴 LIVE {stream}")
    obs.obs_data_set_default_string(settings, "rec_format", "⏺ REC {rec}")
    obs.obs_data_set_default_string(settings, "both_format", "🔴 LIVE {stream} · ⏺ REC {rec}")
    obs.obs_data_set_default_string(settings, "paused_format", "⏸ PAUSED {rec}")
    obs.obs_data_set_default_string(settings, "offline_text", "")
end

function script_update(settings)
    cfg.text_source = obs.obs_data_get_string(settings, "text_source")
    cfg.live_format = obs.obs_data_get_string(settings, "live_format")
    cfg.rec_format = obs.obs_data_get_string(settings, "rec_format")
    cfg.both_format = obs.obs_data_get_string(settings, "both_format")
    cfg.paused_format = obs.obs_data_get_string(settings, "paused_format")
    cfg.offline_text = obs.obs_data_get_string(settings, "offline_text")
    last_text = nil
    on_tick()
end

function script_load(settings)
    obs.obs_frontend_add_event_callback(on_event)
    if obs.obs_frontend_streaming_active() then
        resume_clock(clocks.stream, obs.obs_frontend_get_streaming_output(), false)
    end
    if obs.obs_frontend_recording_active() then
        resume_clock(clocks.record, obs.obs_frontend_get_recording_output(), obs.obs_frontend_recording_paused())
    end
    obs.timer_add(on_tick, TICK_MS)
end

function script_unload()
    obs.timer_remove(on_tick)
end
