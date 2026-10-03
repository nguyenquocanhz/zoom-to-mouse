--[[
    AFK Scene Switcher — v1.0.0
    Không đụng chuột/bàn phím N phút -> tự chuyển sang scene "BRB / Be right back".
    Quay lại máy -> tự về scene trước đó.

    Đo thời gian rảnh (idle) của cả hệ thống, kể cả bàn phím:
      Windows : GetLastInputInfo (user32)
      macOS   : CGEventSourceSecondsSinceLastEventType (CoreGraphics)
      Linux   : XScreenSaverQueryInfo (libXss), nếu thiếu thì dựa vào chuyển động chuột (X11)

    Author : nguyenquocanhz — License: MIT
]]--

local obs = obslua
local ffi = require("ffi")

local VERSION = "1.0.0"
local NONE = "<none>"
local POLL_MS = 1000
local ACTIVE_THRESHOLD = 1.5 -- seconds of idle that still count as "the user is back"

local cfg = {
    enabled = true,
    idle_minutes = 5,
    brb_scene = NONE,
    return_on_activity = true,
    only_when_live = false,
}

local auto_switched = false
local previous_scene = nil
local hotkey_id = nil
local backend = "none"

-- Platform idle backends -----------------------------------------------------
local win_lii = nil
local mac_cg = nil
local x11 = nil
local xss = nil
local x11_display = nil
local x11_root = nil
local xss_info = nil
local x11_ptr = nil
local mouse_last = nil
local mouse_last_move = 0

if ffi.os == "Windows" then
    ffi.cdef([[
        typedef struct { unsigned int cbSize; unsigned int dwTime; } LASTINPUTINFO;
        int GetLastInputInfo(LASTINPUTINFO *plii);
        unsigned int GetTickCount(void);
    ]])
    win_lii = ffi.new("LASTINPUTINFO")
    win_lii.cbSize = ffi.sizeof("LASTINPUTINFO")
    backend = "GetLastInputInfo"
elseif ffi.os == "OSX" then
    ffi.cdef([[
        double CGEventSourceSecondsSinceLastEventType(int source, unsigned int eventType);
    ]])
    local ok, lib = pcall(ffi.load, "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    if ok then
        mac_cg = lib
        backend = "CoreGraphics"
    end
elseif ffi.os == "Linux" then
    ffi.cdef([[
        typedef unsigned long XID;
        typedef void Display;
        typedef struct {
            XID window; int state; int kind;
            unsigned long til_or_since; unsigned long idle; unsigned long eventMask;
        } XScreenSaverInfo;
        Display* XOpenDisplay(char*);
        XID XDefaultRootWindow(Display*);
        int XQueryPointer(Display*, XID, XID*, XID*, int*, int*, int*, int*, unsigned int*);
        int XCloseDisplay(Display*);
        XScreenSaverInfo* XScreenSaverAllocInfo(void);
        int XScreenSaverQueryInfo(Display*, XID, XScreenSaverInfo*);
        int XFree(void*);
    ]])
    local ok, lib = pcall(ffi.load, "X11.so.6")
    if ok then
        x11 = lib
        local dpy = x11.XOpenDisplay(nil)
        if dpy ~= nil then
            x11_display = dpy
            x11_root = x11.XDefaultRootWindow(dpy)
            local ok2, lib2 = pcall(ffi.load, "Xss.so.1")
            if ok2 then
                xss = lib2
                xss_info = xss.XScreenSaverAllocInfo()
                backend = "XScreenSaver"
            else
                x11_ptr = {
                    root = ffi.new("XID[1]"), child = ffi.new("XID[1]"),
                    rx = ffi.new("int[1]"), ry = ffi.new("int[1]"),
                    wx = ffi.new("int[1]"), wy = ffi.new("int[1]"),
                    mask = ffi.new("unsigned int[1]")
                }
                backend = "mouse (X11)"
            end
        end
    end
end

local function log(msg)
    obs.script_log(obs.OBS_LOG_INFO, "[afk] " .. msg)
end

---
-- System idle time in seconds, or nil if it can't be measured on this machine
function get_idle_seconds()
    if win_lii ~= nil then
        if ffi.C.GetLastInputInfo(win_lii) ~= 0 then
            -- unsigned 32-bit tick counter: keep the difference positive across the 49-day wrap
            return ((ffi.C.GetTickCount() - win_lii.dwTime) % 4294967296) / 1000
        end
    elseif mac_cg ~= nil then
        -- kCGEventSourceStateHIDSystemState = 1, kCGAnyInputEventType = ~0
        return mac_cg.CGEventSourceSecondsSinceLastEventType(1, 0xFFFFFFFF)
    elseif xss ~= nil then
        if xss.XScreenSaverQueryInfo(x11_display, x11_root, xss_info) ~= 0 then
            return tonumber(xss_info.idle) / 1000
        end
    elseif x11_ptr ~= nil then
        local now = obs.os_gettime_ns() / 1000000000
        if x11.XQueryPointer(x11_display, x11_root, x11_ptr.root, x11_ptr.child,
                x11_ptr.rx, x11_ptr.ry, x11_ptr.wx, x11_ptr.wy, x11_ptr.mask) ~= 0 then
            local pos = x11_ptr.rx[0] * 100000 + x11_ptr.ry[0] + x11_ptr.mask[0] * 0.5
            if pos ~= mouse_last then
                mouse_last = pos
                mouse_last_move = now
            end
            return now - mouse_last_move
        end
    end
    return nil
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
    local scenes = obs.obs_frontend_get_scenes()
    local found = false
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

local function is_live()
    return obs.obs_frontend_streaming_active() or obs.obs_frontend_recording_active()
end

function on_poll()
    if not cfg.enabled or cfg.brb_scene == NONE or cfg.brb_scene == "" then
        return
    end

    local idle = get_idle_seconds()
    if idle == nil then
        return
    end

    local current = current_scene_name()

    if not auto_switched then
        if idle >= cfg.idle_minutes * 60 and current ~= cfg.brb_scene and (not cfg.only_when_live or is_live()) then
            previous_scene = current
            auto_switched = true
            log(string.format("Idle %.0fs -> chuyển sang '%s'", idle, cfg.brb_scene))
            switch_scene(cfg.brb_scene)
        end
    elseif current ~= cfg.brb_scene then
        -- The user switched scene by hand: don't fight them
        auto_switched = false
        previous_scene = nil
    elseif idle < ACTIVE_THRESHOLD then
        auto_switched = false
        if cfg.return_on_activity and previous_scene ~= nil then
            log("Đã quay lại -> về '" .. previous_scene .. "'")
            switch_scene(previous_scene)
        end
        previous_scene = nil
    end
end

function on_toggle(pressed)
    if not pressed then
        return
    end
    cfg.enabled = not cfg.enabled
    log("AFK switcher " .. (cfg.enabled and "BẬT" or "TẮT"))
end

------------------------------------------------------------------------------
-- OBS script API

function script_description()
    return "<b>AFK Scene Switcher v" .. VERSION .. "</b><br>" ..
        "Rời máy quá lâu thì tự chuyển sang scene BRB, quay lại thì tự về scene cũ.<br>" ..
        "Cách đo idle trên máy này: <i>" .. backend .. "</i>"
end

function script_properties()
    local props = obs.obs_properties_create()

    obs.obs_properties_add_bool(props, "enabled", "Bật")
    obs.obs_properties_add_float_slider(props, "idle_minutes", "Rảnh bao lâu thì chuyển (phút)", 0.5, 60, 0.5)

    local list = obs.obs_properties_add_list(props, "brb_scene", "Scene BRB",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(list, "(chọn scene)", NONE)
    local scenes = obs.obs_frontend_get_scenes()
    if scenes ~= nil then
        for _, scene in ipairs(scenes) do
            local name = obs.obs_source_get_name(scene)
            obs.obs_property_list_add_string(list, name, name)
        end
        obs.source_list_release(scenes)
    end

    obs.obs_properties_add_bool(props, "return_on_activity", "Quay lại scene cũ khi có hoạt động")
    obs.obs_properties_add_bool(props, "only_when_live", "Chỉ khi đang Stream/Record")

    if backend == "none" then
        obs.obs_properties_add_text(props, "warn",
            "⚠ Không đo được thời gian rảnh trên máy này (Wayland?). Script sẽ không làm gì.", obs.OBS_TEXT_INFO)
    end

    return props
end

function script_defaults(settings)
    obs.obs_data_set_default_bool(settings, "enabled", true)
    obs.obs_data_set_default_double(settings, "idle_minutes", 5)
    obs.obs_data_set_default_string(settings, "brb_scene", NONE)
    obs.obs_data_set_default_bool(settings, "return_on_activity", true)
    obs.obs_data_set_default_bool(settings, "only_when_live", false)
end

function script_update(settings)
    cfg.enabled = obs.obs_data_get_bool(settings, "enabled")
    cfg.idle_minutes = obs.obs_data_get_double(settings, "idle_minutes")
    cfg.brb_scene = obs.obs_data_get_string(settings, "brb_scene")
    cfg.return_on_activity = obs.obs_data_get_bool(settings, "return_on_activity")
    cfg.only_when_live = obs.obs_data_get_bool(settings, "only_when_live")
end

function script_load(settings)
    hotkey_id = obs.obs_hotkey_register_frontend("afk_switcher_toggle", "AFK switcher: Bật/Tắt", on_toggle)
    local arr = obs.obs_data_get_array(settings, "afk_switcher_toggle")
    obs.obs_hotkey_load(hotkey_id, arr)
    obs.obs_data_array_release(arr)

    obs.timer_add(on_poll, POLL_MS)
    log("Idle backend: " .. backend)
end

function script_save(settings)
    local arr = obs.obs_hotkey_save(hotkey_id)
    obs.obs_data_set_array(settings, "afk_switcher_toggle", arr)
    obs.obs_data_array_release(arr)
end

function script_unload()
    obs.timer_remove(on_poll)
    if xss_info ~= nil then
        x11.XFree(xss_info)
        xss_info = nil
    end
    if x11_display ~= nil then
        x11.XCloseDisplay(x11_display)
        x11_display = nil
    end
end
