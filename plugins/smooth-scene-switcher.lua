--[[
    Smooth Scene Switcher — v1.0.0
    Chuyển scene mượt, không giật:

    - Next / Previous scene theo thứ tự bạn đặt (có vòng lại)
    - Transition riêng cho Next và Prev, thời lượng riêng; Slide/Swipe tự đổi hướng
      (Next trượt sang trái, Prev trượt sang phải) — như lật trang
    - Bấm dồn dập khi đang chuyển: lệnh được xếp hàng, chạy tiếp ngay khi transition xong,
      không bị cắt ngang giữa chừng
    - Chuyển xong tự trả lại transition / thời lượng bạn đang dùng
    - Playlist: tự xoay vòng scene mỗi N giây (slideshow chờ, podcast nhiều góc máy)
    - Tự chuyển scene theo cửa sổ đang dùng (Windows, Linux X11): "Visual Studio Code => Code"
    - Hỗ trợ Studio Mode (đưa vào Preview rồi transition)

    Author : nguyenquocanhz — License: MIT
]]--

local obs = obslua
local ffi = require("ffi")

local VERSION = "1.0.0"
local CURRENT = "<current>"
local WINDOW_POLL_MS = 1000

local cfg = {
    order = {},
    wrap = true,
    next_transition = CURRENT,
    prev_transition = CURRENT,
    duration = 400,
    auto_direction = true,
    restore = true,
    playlist_seconds = 30,
    window_enabled = false,
    rules = {},
}

local busy = false
local busy_target = nil
local pending = nil
local saved_transition = nil
local saved_duration = nil
local playlist_on = false
local window_timer_on = false
local last_title = nil
local hotkey_ids = {}

local function log(msg)
    obs.script_log(obs.OBS_LOG_INFO, "[switcher] " .. msg)
end

------------------------------------------------------------------------------
-- Active window title (for the window rules)

local win_title = nil

if ffi.os == "Windows" then
    ffi.cdef([[
        typedef void* HWND;
        HWND GetForegroundWindow(void);
        int GetWindowTextW(HWND hWnd, uint16_t* lpString, int nMaxCount);
        int WideCharToMultiByte(unsigned int CodePage, unsigned long dwFlags, const uint16_t* lpWideCharStr,
            int cchWideChar, char* lpMultiByteStr, int cbMultiByte, const char* lpDefaultChar, int* lpUsedDefaultChar);
    ]])
    local wbuf = ffi.new("uint16_t[512]")
    local ubuf = ffi.new("char[2048]")
    win_title = function()
        local hwnd = ffi.C.GetForegroundWindow()
        if hwnd == nil then return nil end
        local n = ffi.C.GetWindowTextW(hwnd, wbuf, 512)
        if n <= 0 then return "" end
        local len = ffi.C.WideCharToMultiByte(65001, 0, wbuf, n, ubuf, 2048, nil, nil) -- CP_UTF8
        return ffi.string(ubuf, len)
    end
elseif ffi.os == "Linux" then
    ffi.cdef([[
        typedef unsigned long XID;
        typedef unsigned long Atom;
        typedef void Display;
        Display* XOpenDisplay(const char*);
        XID XDefaultRootWindow(Display*);
        Atom XInternAtom(Display*, const char*, int);
        int XGetWindowProperty(Display*, XID, Atom, long, long, int, Atom, Atom*, int*,
            unsigned long*, unsigned long*, unsigned char**);
        int XFree(void*);
        int XCloseDisplay(Display*);
    ]])
    local ok, x11 = pcall(ffi.load, "X11.so.6")
    local dpy = ok and x11.XOpenDisplay(nil) or nil
    if dpy ~= nil then
        local root = x11.XDefaultRootWindow(dpy)
        local A_ACTIVE = x11.XInternAtom(dpy, "_NET_ACTIVE_WINDOW", 0)
        local A_NAME = x11.XInternAtom(dpy, "_NET_WM_NAME", 0)
        local A_UTF8 = x11.XInternAtom(dpy, "UTF8_STRING", 0)
        local XA_WINDOW, XA_WM_NAME, XA_STRING = 33, 39, 31
        local t, f = ffi.new("Atom[1]"), ffi.new("int[1]")
        local n, after = ffi.new("unsigned long[1]"), ffi.new("unsigned long[1]")
        local data = ffi.new("unsigned char*[1]")

        local function prop(win, atom, kind, as_string)
            if x11.XGetWindowProperty(dpy, win, atom, 0, 1024, 0, kind, t, f, n, after, data) ~= 0
                or data[0] == nil then
                return nil
            end
            local result = nil
            if n[0] > 0 then
                if as_string then
                    result = ffi.string(data[0], n[0])
                else
                    result = ffi.cast("unsigned long*", data[0])[0]
                end
            end
            x11.XFree(data[0])
            return result
        end

        win_title = function()
            local win = prop(root, A_ACTIVE, XA_WINDOW, false)
            if win == nil or win == 0 then return nil end
            return prop(win, A_NAME, A_UTF8, true) or prop(win, XA_WM_NAME, XA_STRING, true) or ""
        end
    end
end

------------------------------------------------------------------------------
-- Helpers

local function current_scene_name()
    local scene = obs.obs_frontend_get_current_scene()
    if scene == nil then return nil end
    local name = obs.obs_source_get_name(scene)
    obs.obs_source_release(scene)
    return name
end

---
-- The scenes to step through: the user's order (only those that still exist), else OBS order
function scene_list()
    local all, exists = {}, {}
    local scenes = obs.obs_frontend_get_scenes()
    if scenes ~= nil then
        for _, s in ipairs(scenes) do
            local name = obs.obs_source_get_name(s)
            table.insert(all, name)
            exists[name] = true
        end
        obs.source_list_release(scenes)
    end
    if #cfg.order == 0 then
        return all
    end
    local list = {}
    for _, name in ipairs(cfg.order) do
        if exists[name] then table.insert(list, name) end
    end
    return list
end

local function find_transition(name)
    local found = nil
    local list = obs.obs_frontend_get_transitions()
    if list ~= nil then
        for _, tr in ipairs(list) do
            if found == nil and obs.obs_source_get_name(tr) == name then
                found = obs.obs_source_get_ref(tr)
            end
        end
        obs.source_list_release(list)
    end
    return found
end

---
-- Slide/Swipe: Next moves the picture to the left (like turning a page), Prev to the right
function set_direction(tr, dir)
    local id = obs.obs_source_get_unversioned_id(tr)
    if id ~= "slide_transition" and id ~= "swipe_transition" then
        return
    end
    local settings = obs.obs_source_get_settings(tr)
    obs.obs_data_set_string(settings, "direction", dir == "prev" and "right" or "left")
    obs.obs_source_update(tr, settings)
    obs.obs_data_release(settings)
end

local function remember_transition()
    if not cfg.restore or saved_transition ~= nil then
        return
    end
    local cur = obs.obs_frontend_get_current_transition()
    if cur ~= nil then
        saved_transition = obs.obs_source_get_name(cur)
        obs.obs_source_release(cur)
    end
    saved_duration = obs.obs_frontend_get_transition_duration()
end

local function restore_transition()
    if saved_transition ~= nil then
        local tr = find_transition(saved_transition)
        if tr ~= nil then
            obs.obs_frontend_set_current_transition(tr)
            obs.obs_source_release(tr)
        end
    end
    if saved_duration ~= nil then
        obs.obs_frontend_set_transition_duration(saved_duration)
    end
    saved_transition, saved_duration = nil, nil
end

------------------------------------------------------------------------------
-- Switching

---
-- Switch to `name` with the transition for `dir` ("next" / "prev"). While a transition is running the
-- request is queued (latest wins) and fired as soon as it ends, so nothing is cut off mid-way.
function switch_to(name, dir)
    if busy then
        pending = { name = name, dir = dir }
        return
    end

    local scene = obs.obs_get_source_by_name(name)
    if scene == nil then
        log("Không có scene '" .. tostring(name) .. "'")
        return
    end
    if name == current_scene_name() and not obs.obs_frontend_preview_program_mode_active() then
        obs.obs_source_release(scene)
        return
    end

    local tname = dir == "prev" and cfg.prev_transition or cfg.next_transition
    if tname ~= CURRENT or cfg.duration > 0 then
        remember_transition()
    end
    if tname ~= CURRENT then
        local tr = find_transition(tname)
        if tr ~= nil then
            if cfg.auto_direction then
                set_direction(tr, dir)
            end
            obs.obs_frontend_set_current_transition(tr)
            obs.obs_source_release(tr)
        else
            log("Không có transition '" .. tname .. "', dùng transition hiện tại")
        end
    end
    if cfg.duration > 0 then
        obs.obs_frontend_set_transition_duration(cfg.duration)
    end

    busy, busy_target = true, name
    -- The end of the transition is timed rather than taken from OBS_FRONTEND_EVENT_TRANSITION_STOPPED:
    -- a script that registers a frontend event callback deadlocks OBS when its hotkey/timer calls
    -- obs_frontend_set_current_scene (both callbacks need the same script lock, and the UI thread
    -- would wait for it while we wait for the UI thread).
    local ms = cfg.duration > 0 and cfg.duration or obs.obs_frontend_get_transition_duration()
    obs.timer_remove(on_transition_end)
    obs.timer_add(on_transition_end, ms + 150)

    if obs.obs_frontend_preview_program_mode_active() then
        obs.obs_frontend_set_current_preview_scene(scene)
        obs.obs_frontend_preview_program_trigger_transition()
    else
        obs.obs_frontend_set_current_scene(scene)
    end
    obs.obs_source_release(scene)
end

function transition_done()
    if not busy then
        return
    end
    busy, busy_target = false, nil
    obs.timer_remove(on_transition_end)

    if pending ~= nil then
        local p = pending
        pending = nil
        switch_to(p.name, p.dir)
        if busy then
            return -- keep the user's transition saved until the queue is empty
        end
    end
    restore_transition()
end

function on_transition_end()
    obs.timer_remove(on_transition_end)
    transition_done()
end

---
-- Step through the list. Rapid presses build on the queued target, so 3 presses = 3 scenes ahead.
function step(delta)
    local list = scene_list()
    if #list == 0 then return end
    local base = (pending and pending.name) or busy_target or current_scene_name()
    local idx = 0
    for i, name in ipairs(list) do
        if name == base then idx = i break end
    end
    local n = idx + delta
    if idx == 0 then
        n = delta > 0 and 1 or #list
    elseif n < 1 or n > #list then
        if not cfg.wrap then return end
        n = (n - 1) % #list + 1
    end
    switch_to(list[n], delta > 0 and "next" or "prev")
end

------------------------------------------------------------------------------
-- Playlist

function on_playlist_tick()
    step(1)
end

function set_playlist(on)
    playlist_on = on
    obs.timer_remove(on_playlist_tick)
    if on then
        obs.timer_add(on_playlist_tick, math.max(1, cfg.playlist_seconds) * 1000)
    end
    log("Playlist " .. (on and ("BẬT, " .. cfg.playlist_seconds .. "s/scene") or "TẮT"))
end

------------------------------------------------------------------------------
-- Window rules: "part of the window title => Scene"

function parse_rule(line)
    local pattern, scene = line:match("^%s*(.-)%s*=>%s*(.-)%s*$")
    if pattern == nil then
        pattern, scene = line:match("^%s*(.-)%s*%->%s*(.-)%s*$")
    end
    if pattern == nil or pattern == "" or scene == nil or scene == "" then
        return nil
    end
    return { pattern = pattern:lower(), scene = scene }
end

function get_window_title()
    return win_title and win_title() or nil
end

function on_window_poll()
    local title = get_window_title()
    if title == nil or title == last_title then
        return -- only react when the focused window changes, so manual switching isn't fought
    end
    last_title = title
    local lower = title:lower()
    for _, rule in ipairs(cfg.rules) do
        if lower:find(rule.pattern, 1, true) then
            if rule.scene ~= current_scene_name() then
                log("Cửa sổ '" .. title .. "' -> " .. rule.scene)
                switch_to(rule.scene, "next")
            end
            return
        end
    end
end

function update_window_timer()
    local want = cfg.window_enabled and #cfg.rules > 0 and win_title ~= nil
    if want and not window_timer_on then
        last_title = nil
        obs.timer_add(on_window_poll, WINDOW_POLL_MS)
    elseif not want and window_timer_on then
        obs.timer_remove(on_window_poll)
    end
    window_timer_on = want
end

------------------------------------------------------------------------------
-- Hotkeys

function on_next(pressed) if pressed then step(1) end end
function on_prev(pressed) if pressed then step(-1) end end
function on_playlist(pressed) if pressed then set_playlist(not playlist_on) end end
function on_window_toggle(pressed)
    if pressed then
        cfg.window_enabled = not cfg.window_enabled
        update_window_timer()
        log("Chuyển theo cửa sổ: " .. (cfg.window_enabled and "BẬT" or "TẮT"))
    end
end

local HOTKEYS = {
    { "smooth_switcher_next", "Smooth Switcher: Scene tiếp theo", on_next },
    { "smooth_switcher_prev", "Smooth Switcher: Scene trước", on_prev },
    { "smooth_switcher_playlist", "Smooth Switcher: Playlist Bật/Tắt", on_playlist },
    { "smooth_switcher_window", "Smooth Switcher: Chuyển theo cửa sổ Bật/Tắt", on_window_toggle },
}

------------------------------------------------------------------------------
-- OBS script API

function script_description()
    return "<b>Smooth Scene Switcher v" .. VERSION .. "</b><br>" ..
        "Next/Prev scene với transition riêng, Slide tự đổi hướng, xếp hàng khi bấm dồn, " ..
        "playlist tự xoay, tự chuyển theo cửa sổ đang dùng."
end

local function add_transition_list(props, id, label)
    local list = obs.obs_properties_add_list(props, id, label, obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(list, "(giữ transition đang chọn)", CURRENT)
    local trs = obs.obs_frontend_get_transitions()
    if trs ~= nil then
        for _, tr in ipairs(trs) do
            local name = obs.obs_source_get_name(tr)
            obs.obs_property_list_add_string(list, name, name)
        end
        obs.source_list_release(trs)
    end
end

function script_properties()
    local props = obs.obs_properties_create()

    obs.obs_properties_add_editable_list(props, "order", "Thứ tự scene (trống = theo danh sách OBS)",
        obs.OBS_EDITABLE_LIST_TYPE_STRINGS, nil, nil)
    obs.obs_properties_add_bool(props, "wrap", "Hết danh sách thì quay lại đầu")

    add_transition_list(props, "next_transition", "Transition khi Next")
    add_transition_list(props, "prev_transition", "Transition khi Prev")
    obs.obs_properties_add_int_slider(props, "duration", "Thời lượng (ms, 0 = giữ nguyên)", 0, 3000, 50)
    obs.obs_properties_add_bool(props, "auto_direction", "Slide/Swipe tự đổi hướng (Next ←, Prev →)")
    obs.obs_properties_add_bool(props, "restore", "Chuyển xong trả lại transition cũ")

    obs.obs_properties_add_int(props, "playlist_seconds", "Playlist: mỗi scene (giây)", 1, 3600, 1)

    obs.obs_properties_add_bool(props, "window_enabled", "Tự chuyển scene theo cửa sổ đang dùng")
    obs.obs_properties_add_editable_list(props, "window_rules",
        "Luật cửa sổ — mỗi dòng: chữ trong tiêu đề => Tên scene", obs.OBS_EDITABLE_LIST_TYPE_STRINGS, nil, nil)
    if win_title == nil then
        obs.obs_properties_add_text(props, "window_warn",
            "⚠ Máy này không đọc được cửa sổ đang dùng (macOS / Wayland) — luật cửa sổ sẽ không chạy.",
            obs.OBS_TEXT_INFO)
    end

    obs.obs_properties_add_button(props, "btn_prev", "◀ Scene trước", function() step(-1) return false end)
    obs.obs_properties_add_button(props, "btn_next", "Scene tiếp ▶", function() step(1) return false end)
    obs.obs_properties_add_button(props, "btn_playlist", "Playlist Bật/Tắt", function()
        set_playlist(not playlist_on)
        return false
    end)

    return props
end

function script_defaults(settings)
    obs.obs_data_set_default_bool(settings, "wrap", true)
    obs.obs_data_set_default_string(settings, "next_transition", CURRENT)
    obs.obs_data_set_default_string(settings, "prev_transition", CURRENT)
    obs.obs_data_set_default_int(settings, "duration", 400)
    obs.obs_data_set_default_bool(settings, "auto_direction", true)
    obs.obs_data_set_default_bool(settings, "restore", true)
    obs.obs_data_set_default_int(settings, "playlist_seconds", 30)
    obs.obs_data_set_default_bool(settings, "window_enabled", false)
end

local function read_list(settings, key)
    local out = {}
    local arr = obs.obs_data_get_array(settings, key)
    if arr ~= nil then
        for i = 0, obs.obs_data_array_count(arr) - 1 do
            local item = obs.obs_data_array_item(arr, i)
            table.insert(out, obs.obs_data_get_string(item, "value"))
            obs.obs_data_release(item)
        end
        obs.obs_data_array_release(arr)
    end
    return out
end

function script_update(settings)
    cfg.order = read_list(settings, "order")
    cfg.wrap = obs.obs_data_get_bool(settings, "wrap")
    cfg.next_transition = obs.obs_data_get_string(settings, "next_transition")
    cfg.prev_transition = obs.obs_data_get_string(settings, "prev_transition")
    cfg.duration = obs.obs_data_get_int(settings, "duration")
    cfg.auto_direction = obs.obs_data_get_bool(settings, "auto_direction")
    cfg.restore = obs.obs_data_get_bool(settings, "restore")
    cfg.playlist_seconds = obs.obs_data_get_int(settings, "playlist_seconds")
    cfg.window_enabled = obs.obs_data_get_bool(settings, "window_enabled")

    cfg.rules = {}
    for _, line in ipairs(read_list(settings, "window_rules")) do
        local rule = parse_rule(line)
        if rule then
            table.insert(cfg.rules, rule)
        elseif line:match("%S") then
            log("Bỏ qua luật sai định dạng: '" .. line .. "' (đúng: chữ trong tiêu đề => Tên scene)")
        end
    end

    if playlist_on then
        set_playlist(true) -- pick up a new interval
    end
    update_window_timer()
end

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
    obs.timer_remove(on_playlist_tick)
    obs.timer_remove(on_window_poll)
    obs.timer_remove(on_transition_end)
    restore_transition()
end
