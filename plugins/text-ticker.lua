--[[
    Text Ticker — v1.0.0
    Xoay vòng các thông báo (follow, donate, lịch stream, link mạng xã hội...) trên một Text source.

    - Nhập danh sách trong cài đặt, hoặc đọc từ file .txt (mỗi dòng 1 câu, sửa file là tự cập nhật)
    - Chế độ "Xoay vòng": đổi câu mỗi N giây (có xáo trộn)
    - Chế độ "Ghép một dòng": nối tất cả bằng dấu phân cách — thêm filter "Scroll" vào Text source
      là thành dòng chữ chạy kiểu bản tin
    - Hotkey: câu tiếp theo

    Author : nguyenquocanhz — License: MIT
]]--

local obs = obslua

local VERSION = "1.0.0"

local cfg = {
    text_source = "",
    mode = "rotate",
    interval = 8,
    shuffle = false,
    file_path = "",
    separator = "   •   ",
    template = "{msg}",
    messages = {},
}

local order = {}
local pos = 0
local last_text = nil
local hotkey_id = nil
local timer_running = false

local function log(msg)
    obs.script_log(obs.OBS_LOG_INFO, "[ticker] " .. msg)
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---
-- Messages from the settings list plus the file (re-read every time so edits show up live)
function load_messages()
    local list = {}
    for _, m in ipairs(cfg.messages) do
        if trim(m) ~= "" then
            table.insert(list, m)
        end
    end
    if cfg.file_path ~= "" then
        local f = io.open(cfg.file_path, "r")
        if f ~= nil then
            for line in f:lines() do
                line = trim(line:gsub("^\239\187\191", "")) -- strip UTF-8 BOM
                if line ~= "" then
                    table.insert(list, line)
                end
            end
            f:close()
        end
    end
    return list
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

local function apply_template(msg)
    return (cfg.template:gsub("{msg}", (msg:gsub("%%", "%%%%"))))
end

local function new_order(n)
    order = {}
    for i = 1, n do
        order[i] = i
    end
    if cfg.shuffle then
        for i = n, 2, -1 do
            local j = math.random(i)
            order[i], order[j] = order[j], order[i]
        end
    end
    pos = 0
end

function show_next()
    local list = load_messages()
    if #list == 0 then
        set_text("")
        return
    end

    if cfg.mode == "join" then
        set_text(apply_template(table.concat(list, cfg.separator)))
        return
    end

    if #order ~= #list or pos >= #order then
        local previous = order[pos]
        new_order(#list)
        -- Avoid showing the same message twice in a row when a shuffled round restarts
        if cfg.shuffle and #order > 1 and order[1] == previous then
            order[1], order[2] = order[2], order[1]
        end
    end
    pos = pos + 1
    set_text(apply_template(list[order[pos]]))
end

function on_tick()
    show_next()
end

function restart_timer()
    if timer_running then
        obs.timer_remove(on_tick)
        timer_running = false
    end
    -- In "join" mode the text only changes when the list/file does, so a slow refresh is enough
    local ms = cfg.mode == "join" and 5000 or math.max(1, cfg.interval) * 1000
    obs.timer_add(on_tick, ms)
    timer_running = true
end

function on_next_hotkey(pressed)
    if pressed then
        show_next()
        restart_timer()
    end
end

------------------------------------------------------------------------------
-- OBS script API

function script_description()
    return "<b>Text Ticker v" .. VERSION .. "</b><br>" ..
        "Xoay vòng thông báo trên Text source, hoặc ghép thành dòng chữ chạy (kết hợp filter Scroll)."
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

    local mode = obs.obs_properties_add_list(props, "mode", "Chế độ",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(mode, "Xoay vòng từng câu", "rotate")
    obs.obs_property_list_add_string(mode, "Ghép một dòng (dùng với filter Scroll)", "join")

    obs.obs_properties_add_editable_list(props, "messages", "Danh sách thông báo",
        obs.OBS_EDITABLE_LIST_TYPE_STRINGS, nil, nil)
    obs.obs_properties_add_path(props, "file_path", "Hoặc đọc thêm từ file .txt",
        obs.OBS_PATH_FILE, "Text (*.txt);;All files (*.*)", nil)
    obs.obs_properties_add_int(props, "interval", "Đổi câu sau (giây)", 1, 3600, 1)
    obs.obs_properties_add_bool(props, "shuffle", "Xáo trộn")
    obs.obs_properties_add_text(props, "separator", "Dấu phân cách (chế độ ghép)", obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_text(props, "template", "Mẫu ({msg} = câu thông báo)", obs.OBS_TEXT_DEFAULT)

    obs.obs_properties_add_button(props, "btn_next", "Câu tiếp theo", function() on_next_hotkey(true) return false end)

    return props
end

function script_defaults(settings)
    obs.obs_data_set_default_string(settings, "mode", "rotate")
    obs.obs_data_set_default_int(settings, "interval", 8)
    obs.obs_data_set_default_bool(settings, "shuffle", false)
    obs.obs_data_set_default_string(settings, "separator", "   •   ")
    obs.obs_data_set_default_string(settings, "template", "{msg}")
end

function script_update(settings)
    cfg.text_source = obs.obs_data_get_string(settings, "text_source")
    cfg.mode = obs.obs_data_get_string(settings, "mode")
    cfg.interval = obs.obs_data_get_int(settings, "interval")
    cfg.shuffle = obs.obs_data_get_bool(settings, "shuffle")
    cfg.file_path = obs.obs_data_get_string(settings, "file_path")
    cfg.separator = obs.obs_data_get_string(settings, "separator")
    cfg.template = obs.obs_data_get_string(settings, "template")

    cfg.messages = {}
    local arr = obs.obs_data_get_array(settings, "messages")
    if arr ~= nil then
        for i = 0, obs.obs_data_array_count(arr) - 1 do
            local item = obs.obs_data_array_item(arr, i)
            table.insert(cfg.messages, obs.obs_data_get_string(item, "value"))
            obs.obs_data_release(item)
        end
        obs.obs_data_array_release(arr)
    end

    order = {}
    pos = 0
    last_text = nil
    show_next()
    restart_timer()
end

function script_load(settings)
    math.randomseed(os.time())
    hotkey_id = obs.obs_hotkey_register_frontend("text_ticker_next", "Text Ticker: Câu tiếp theo", on_next_hotkey)
    local arr = obs.obs_data_get_array(settings, "text_ticker_next")
    obs.obs_hotkey_load(hotkey_id, arr)
    obs.obs_data_array_release(arr)
end

function script_save(settings)
    local arr = obs.obs_hotkey_save(hotkey_id)
    obs.obs_data_set_array(settings, "text_ticker_next", arr)
    obs.obs_data_array_release(arr)
end

function script_unload()
    if timer_running then
        obs.timer_remove(on_tick)
    end
end
