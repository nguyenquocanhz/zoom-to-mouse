--[[
    Chapter Markers — v1.0.0
    Bấm phím trong lúc Record/Stream để đánh dấu chương. Script ghi ra file .txt đúng định dạng
    YouTube chapters (dán thẳng vào mô tả video):

        00:00 Intro
        03:12 Cài đặt OBS
        11:45 Demo

    - Danh sách tên chương soạn trước (agenda) — mỗi lần bấm lấy tên kế tiếp
    - Ghi chapter thật vào file MP4 khi dùng định dạng Hybrid MP4 (OBS 30.2+)
    - Thời gian Record trừ phần đã Pause
    - (Tùy chọn) Hiện tên chương hiện tại lên một Text source

    Author : nguyenquocanhz — License: MIT
]]--

local obs = obslua

local VERSION = "1.0.0"
local NONE = "<none>"
local MIN_YT_GAP = 10 -- YouTube ignores chapters shorter than 10 seconds

local cfg = {
    timeline = "record",
    first_title = "Intro",
    titles = {},
    title_pattern = "Chapter {n}",
    output_dir = "",
    native_chapters = true,
    text_source = NONE,
}

-- Output clocks (pause-aware) -------------------------------------------------
local clocks = {
    stream = { start = nil, paused = 0, pause_start = nil },
    record = { start = nil, paused = 0, pause_start = nil },
}

local session = nil -- { path = "...", markers = { {t = 0, title = "Intro"}, ... } }
local hotkey_ids = {}

local function log(msg)
    obs.script_log(obs.OBS_LOG_INFO, "[chapters] " .. msg)
end

local function now_ns()
    return obs.os_gettime_ns()
end

function clock_elapsed(c)
    if c.start == nil then
        return nil
    end
    local paused = c.paused + (c.pause_start and (now_ns() - c.pause_start) or 0)
    return (now_ns() - c.start - paused) / 1000000000
end

---
-- Seconds -> "MM:SS" or "H:MM:SS" (YouTube chapter format)
function format_ts(sec)
    sec = math.max(0, math.floor(sec))
    local h = math.floor(sec / 3600)
    local m = math.floor(sec % 3600 / 60)
    local s = sec % 60
    if h > 0 then
        return string.format("%d:%02d:%02d", h, m, s)
    end
    return string.format("%02d:%02d", m, s)
end

local function output_folder()
    if cfg.output_dir ~= "" then
        return cfg.output_dir
    end
    if obs.obs_frontend_get_current_record_output_path then
        local p = obs.obs_frontend_get_current_record_output_path()
        if p ~= nil and p ~= "" then
            return p
        end
    end
    return os.getenv("USERPROFILE") or os.getenv("HOME") or "."
end

function write_session()
    if session == nil then
        return
    end
    local f, err = io.open(session.path, "w")
    if f == nil then
        log("Không ghi được file: " .. tostring(err))
        return
    end
    for _, m in ipairs(session.markers) do
        f:write(format_ts(m.t), " ", m.title, "\n")
    end
    f:close()
end

function set_text(text)
    if cfg.text_source == NONE or cfg.text_source == "" then
        return
    end
    local source = obs.obs_get_source_by_name(cfg.text_source)
    if source ~= nil then
        local settings = obs.obs_data_create()
        obs.obs_data_set_string(settings, "text", text)
        obs.obs_source_update(source, settings)
        obs.obs_data_release(settings)
        obs.obs_source_release(source)
    end
end

function start_session()
    local name = os.date("chapters_%Y-%m-%d_%H-%M-%S.txt")
    local sep = package.config:sub(1, 1)
    local folder = output_folder():gsub("[/\\]+$", "")
    session = {
        path = folder .. sep .. name,
        markers = { { t = 0, title = cfg.first_title } },
    }
    write_session()
    set_text(cfg.first_title)
    log("Bắt đầu phiên chương: " .. session.path)
end

function end_session()
    if session ~= nil then
        write_session()
        log("Đã lưu " .. #session.markers .. " chương vào " .. session.path)
        if #session.markers < 3 then
            log("Lưu ý: YouTube cần tối thiểu 3 chương (kể cả 00:00) thì mới hiện chapters.")
        end
    end
    session = nil
end

function next_title()
    local n = #session.markers + 1
    local planned = cfg.titles[#session.markers] -- first marker (00:00) uses first_title
    if planned ~= nil and planned ~= "" then
        return planned
    end
    return (cfg.title_pattern:gsub("{n}", tostring(n)))
end

function add_chapter()
    local t = clock_elapsed(clocks[cfg.timeline])
    if t == nil or session == nil then
        log("Chưa " .. (cfg.timeline == "record" and "Record" or "Stream") .. " nên không thêm được chương")
        return
    end

    local title = next_title()
    local last = session.markers[#session.markers]
    if t - last.t < MIN_YT_GAP then
        log(string.format("Cảnh báo: chương '%s' chỉ dài %.0fs (YouTube cần >= %ds)", last.title, t - last.t, MIN_YT_GAP))
    end

    table.insert(session.markers, { t = t, title = title })
    write_session()
    set_text(title)
    log(format_ts(t) .. " " .. title)

    if cfg.native_chapters and cfg.timeline == "record" and obs.obs_frontend_recording_add_chapter then
        -- Only Hybrid MP4 supports chapters; other formats return false
        local ok, res = pcall(obs.obs_frontend_recording_add_chapter, title)
        if not ok or res == false then
            log("Không ghi được chapter vào file (chỉ hỗ trợ Hybrid MP4 trên OBS 30.2+)")
        end
    end
end

function undo_chapter()
    if session == nil or #session.markers <= 1 then
        return
    end
    local m = table.remove(session.markers)
    write_session()
    set_text(session.markers[#session.markers].title)
    log("Đã xóa chương '" .. m.title .. "'")
end

function on_event(event)
    local now = now_ns()
    if event == obs.OBS_FRONTEND_EVENT_STREAMING_STARTED then
        clocks.stream.start, clocks.stream.paused, clocks.stream.pause_start = now, 0, nil
        if cfg.timeline == "stream" then start_session() end
    elseif event == obs.OBS_FRONTEND_EVENT_STREAMING_STOPPED then
        if cfg.timeline == "stream" then end_session() end
        clocks.stream.start = nil
    elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_STARTED then
        clocks.record.start, clocks.record.paused, clocks.record.pause_start = now, 0, nil
        if cfg.timeline == "record" then start_session() end
    elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED then
        if cfg.timeline == "record" then end_session() end
        clocks.record.start = nil
    elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_PAUSED then
        clocks.record.pause_start = now
    elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_UNPAUSED then
        if clocks.record.pause_start then
            clocks.record.paused = clocks.record.paused + (now - clocks.record.pause_start)
            clocks.record.pause_start = nil
        end
    end
end

---
-- Script (re)loaded while already live: estimate the start from the frames the output has sent
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

function on_add_hotkey(pressed)
    if pressed then add_chapter() end
end

function on_undo_hotkey(pressed)
    if pressed then undo_chapter() end
end

------------------------------------------------------------------------------
-- OBS script API

function script_description()
    return "<b>Chapter Markers v" .. VERSION .. "</b><br>" ..
        "Bấm phím để đánh dấu chương khi Record/Stream, xuất file .txt theo định dạng YouTube chapters.<br>" ..
        "Hybrid MP4 (OBS 30.2+) còn được ghi chapter thật vào file video."
end

function script_properties()
    local props = obs.obs_properties_create()

    local tl = obs.obs_properties_add_list(props, "timeline", "Tính giờ theo",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(tl, "Recording (video quay)", "record")
    obs.obs_property_list_add_string(tl, "Stream (VOD livestream)", "stream")

    obs.obs_properties_add_text(props, "first_title", "Tên chương 00:00", obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_editable_list(props, "titles", "Agenda (tên các chương tiếp theo)",
        obs.OBS_EDITABLE_LIST_TYPE_STRINGS, nil, nil)
    obs.obs_properties_add_text(props, "title_pattern", "Tên mặc định khi hết agenda ({n} = số thứ tự)",
        obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_path(props, "output_dir", "Thư mục lưu file (trống = thư mục Recording)",
        obs.OBS_PATH_DIRECTORY, nil, nil)
    obs.obs_properties_add_bool(props, "native_chapters", "Ghi chapter vào file MP4 (Hybrid MP4, OBS 30.2+)")

    local text_list = obs.obs_properties_add_list(props, "text_source", "Hiện tên chương lên Text source",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(text_list, "(không)", NONE)
    local sources = obs.obs_enum_sources()
    if sources ~= nil then
        for _, s in ipairs(sources) do
            local id = obs.obs_source_get_unversioned_id(s)
            if id == "text_gdiplus" or id == "text_ft2_source" then
                local name = obs.obs_source_get_name(s)
                obs.obs_property_list_add_string(text_list, name, name)
            end
        end
        obs.source_list_release(sources)
    end

    obs.obs_properties_add_button(props, "btn_add", "Thêm chương", function() add_chapter() return false end)
    obs.obs_properties_add_button(props, "btn_undo", "Xóa chương cuối", function() undo_chapter() return false end)

    return props
end

function script_defaults(settings)
    obs.obs_data_set_default_string(settings, "timeline", "record")
    obs.obs_data_set_default_string(settings, "first_title", "Intro")
    obs.obs_data_set_default_string(settings, "title_pattern", "Chapter {n}")
    obs.obs_data_set_default_string(settings, "output_dir", "")
    obs.obs_data_set_default_bool(settings, "native_chapters", true)
    obs.obs_data_set_default_string(settings, "text_source", NONE)
end

function script_update(settings)
    cfg.timeline = obs.obs_data_get_string(settings, "timeline")
    cfg.first_title = obs.obs_data_get_string(settings, "first_title")
    cfg.title_pattern = obs.obs_data_get_string(settings, "title_pattern")
    cfg.output_dir = obs.obs_data_get_string(settings, "output_dir")
    cfg.native_chapters = obs.obs_data_get_bool(settings, "native_chapters")
    cfg.text_source = obs.obs_data_get_string(settings, "text_source")

    cfg.titles = {}
    local arr = obs.obs_data_get_array(settings, "titles")
    if arr ~= nil then
        for i = 0, obs.obs_data_array_count(arr) - 1 do
            local item = obs.obs_data_array_item(arr, i)
            table.insert(cfg.titles, obs.obs_data_get_string(item, "value"))
            obs.obs_data_release(item)
        end
        obs.obs_data_array_release(arr)
    end
end

local HOTKEYS = {
    { "chapter_markers_add", "Chapter: Thêm chương", on_add_hotkey },
    { "chapter_markers_undo", "Chapter: Xóa chương cuối", on_undo_hotkey },
}

function script_load(settings)
    for _, hk in ipairs(HOTKEYS) do
        local id = obs.obs_hotkey_register_frontend(hk[1], hk[2], hk[3])
        local arr = obs.obs_data_get_array(settings, hk[1])
        obs.obs_hotkey_load(id, arr)
        obs.obs_data_array_release(arr)
        hotkey_ids[hk[1]] = id
    end
    obs.obs_frontend_add_event_callback(on_event)

    script_update(settings)
    if obs.obs_frontend_streaming_active() then
        resume_clock(clocks.stream, obs.obs_frontend_get_streaming_output(), false)
    end
    if obs.obs_frontend_recording_active() then
        resume_clock(clocks.record, obs.obs_frontend_get_recording_output(), obs.obs_frontend_recording_paused())
    end
    if clocks[cfg.timeline].start ~= nil then
        start_session()
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
    end_session()
end
