--[[
    OBS Zoom to Mouse — v1.2.0
    Zoom a display-capture source to focus on the mouse cursor.

    Original script : BlankSourceCode (https://github.com/BlankSourceCode/obs-zoom-to-mouse)
    Optimize & fixes: nguyenquocanhz (https://github.com/nguyenquocanhz/zoom-to-mouse)
    License         : MIT (see LICENSE)

    ------------------------------------------------------------------------
    GIẤY PHÉP VÀ TỪ CHỐI TRÁCH NHIỆM (DISCLAIMER / LICENSE)
    Kịch bản (script) này được cung cấp dựa trên nguyên tắc "NGUYÊN TRẠNG"
    (AS IS), không đi kèm với bất kỳ bảo đảm nào, dù là rõ ràng hay ngụ ý.
    Tác giả và người đóng góp TỪ CHỐI MỌI TRÁCH NHIỆM đối với bất kỳ thiệt
    hại trực tiếp, gián tiếp, vô ý hoặc hậu quả nào (bao gồm nhưng không
    giới hạn: lỗi gián đoạn luồng phát trực tiếp, hỏng dữ liệu, crash OBS
    hay hư hỏng phần mềm/phần cứng) phát sinh từ việc sử dụng kịch bản này.
    Người dùng hoàn toàn tự chịu rủi ro khi cài đặt và sử dụng.
    ------------------------------------------------------------------------
]]--

local obs = obslua
local ffi = require("ffi")
local bit = require("bit")

local VERSION = "1.2.0"
local CROP_FILTER_NAME = "obs-zoom-to-mouse-crop"
local SHARPEN_FILTER_NAME = "obs-zoom-to-mouse-sharpen"
local NONE_SOURCE = "obs-zoom-to-mouse-none"
local MAX_ZOOM = 10

-- obs_scale_type values (numeric fallbacks for older bindings)
local SCALE_KEEP = -1
local SCALE_BICUBIC = obs.OBS_SCALE_BICUBIC or 2
local SCALE_BILINEAR = obs.OBS_SCALE_BILINEAR or 3
local SCALE_LANCZOS = obs.OBS_SCALE_LANCZOS or 4
local SCALE_AREA = obs.OBS_SCALE_AREA or 5

-- OBS 30 renamed the transform getters/setters (the old ones still exist but warn).
-- Fall back to the old names so the script keeps working on OBS 28/29.
local sceneitem_get_info = obs.obs_sceneitem_get_info2 or obs.obs_sceneitem_get_info
local sceneitem_set_info = obs.obs_sceneitem_set_info2 or obs.obs_sceneitem_set_info

local source_name = ""
local source = nil
local sceneitem = nil
local sceneitem_info_orig = nil
local sceneitem_crop_orig = nil
local sceneitem_info = nil
local sceneitem_crop = nil
local crop_filter = nil
local crop_filter_temp = nil
local crop_filter_settings = nil
local crop_filter_info_orig = { x = 0, y = 0, w = 0, h = 0 }
local crop_filter_info = { x = 0, y = 0, w = 0, h = 0 }
local crop_last_applied = { x = -1, y = -1, w = -1, h = -1 }
local sharpen_filter = nil
local sharpen_settings = nil
local sharpen_last = -1
local scale_filter_orig = nil
local scale_filter_current = nil
local monitor_info = nil
local zoom_info = {
    source_size = { width = 0, height = 0 },
    source_crop = { x = 0, y = 0, w = 0, h = 0 },
    source_crop_filter = { x = 0, y = 0, w = 0, h = 0 },
    zoom_to = 2
}
local zoom_time = 0
local zoom_target = nil
local anim_from = nil
local last_tick = 0
local locked_center = nil
local locked_last_pos = nil
local hotkey_zoom_id = nil
local hotkey_follow_id = nil
local hotkey_zoom_more_id = nil
local hotkey_zoom_less_id = nil
local hotkey_calibrate_id = nil
local is_timer_running = false

local win_point = nil
local x11_lib = nil
local x11_display = nil
local x11_root = nil
local x11_mouse = nil
local osx_lib = nil
local osx_nsevent = nil
local osx_mouse_location = nil
local osx_pressed_buttons = nil
local osx_cg = nil
local win_physical_cursor = false
local win_dpi_context = false
local x11_randr = nil
local script_settings = nil
local CALIBRATE_DELAY_MS = 3000

local use_auto_follow_mouse = true
local use_follow_outside_bounds = false
local is_following_mouse = false
local follow_speed = 0.1
local follow_border = 0
local follow_safezone_sensitivity = 10
local use_follow_auto_lock = false
local zoom_value = 2
local zoom_speed = 0.1
local zoom_step = 0.5
local use_click_zoom = false
local auto_zoom_out_delay = 3
local scale_filter_zoomed = SCALE_LANCZOS
local sharpen_strength = 0.1
local allow_all_sources = false
local use_monitor_override = false
local monitor_override_x = 0
local monitor_override_y = 0
local monitor_override_w = 0
local monitor_override_h = 0
local monitor_override_sx = 0
local monitor_override_sy = 0
local monitor_override_dw = 0
local monitor_override_dh = 0
local debug_logs = false

-- Click-to-zoom state
local CLICK_POLL_MS = 30
local is_click_poll_running = false
local click_was_down = false
local last_activity = 0
local last_mouse = nil
local zoomed_by_click = false

local ZoomState = {
    None = 0,
    ZoomingIn = 1,
    ZoomingOut = 2,
    ZoomedIn = 3,
}
local zoom_state = ZoomState.None

local version = obs.obs_get_version_string()
local major = tonumber(version:match("(%d+%.%d+)")) or 0

-- Define the mouse cursor functions for each platform.
-- Every native call is guarded: a missing library (e.g. no X11 under a pure Wayland session)
-- must never stop the script from loading.
if ffi.os == "Windows" then
    ffi.cdef([[
        typedef int BOOL;
        typedef struct{
            long x;
            long y;
        } POINT, *LPPOINT;
        BOOL GetCursorPos(LPPOINT);
        short GetAsyncKeyState(int vKey);

        typedef struct { long left; long top; long right; long bottom; } RECT;
        typedef struct { unsigned long cbSize; RECT rcMonitor; RECT rcWork; unsigned long dwFlags; } MONITORINFO;
        typedef BOOL (__stdcall *MONITORENUMPROC)(void*, void*, RECT*, intptr_t);
        BOOL EnumDisplayMonitors(void* hdc, const RECT* clip, MONITORENUMPROC callback, intptr_t data);
        BOOL GetMonitorInfoA(void* monitor, MONITORINFO* info);
        BOOL GetPhysicalCursorPos(LPPOINT);
        void* SetThreadDpiAwarenessContext(void* context);
    ]])
    win_point = ffi.new("POINT[1]")
    -- Monitors with different Scale (e.g. laptop 150% + external 100%): GetCursorPos can return
    -- DPI-virtualised coordinates, while the Display Capture works in physical pixels.
    -- GetPhysicalCursorPos (Vista+) and a per-monitor-aware thread (Win10 1607+) avoid that.
    win_physical_cursor = pcall(function() return ffi.C.GetPhysicalCursorPos end)
    win_dpi_context = pcall(function() return ffi.C.SetThreadDpiAwarenessContext end)
elseif ffi.os == "Linux" then
    ffi.cdef([[
        typedef unsigned long XID;
        typedef XID Window;
        typedef void Display;
        Display* XOpenDisplay(char*);
        XID XDefaultRootWindow(Display *display);
        int XQueryPointer(Display*, Window, Window*, Window*, int*, int*, int*, int*, unsigned int*);
        int XCloseDisplay(Display*);

        typedef unsigned long Atom;
        typedef struct {
            Atom name; int primary; int automatic; int noutput;
            int x; int y; int width; int height; int mwidth; int mheight;
            unsigned long *outputs;
        } XRRMonitorInfo;
        XRRMonitorInfo* XRRGetMonitors(Display* dpy, Window window, int get_active, int* nmonitors);
        void XRRFreeMonitors(XRRMonitorInfo* monitors);
    ]])

    local ok, lib = pcall(ffi.load, "X11.so.6")
    if ok then
        x11_lib = lib
        x11_display = x11_lib.XOpenDisplay(nil)
        if x11_display ~= nil then
            x11_root = x11_lib.XDefaultRootWindow(x11_display)
            x11_mouse = {
                root_win = ffi.new("Window[1]"),
                child_win = ffi.new("Window[1]"),
                root_x = ffi.new("int[1]"),
                root_y = ffi.new("int[1]"),
                win_x = ffi.new("int[1]"),
                win_y = ffi.new("int[1]"),
                mask = ffi.new("unsigned int[1]")
            }
            local ok_randr, randr = pcall(ffi.load, "Xrandr.so.2")
            if ok_randr then
                x11_randr = randr
            end
        else
            x11_display = nil
        end
    end
elseif ffi.os == "OSX" then
    ffi.cdef([[
        typedef struct {
            double x;
            double y;
        } CGPoint;
        typedef void* SEL;
        typedef void* id;
        typedef void* Method;

        SEL sel_registerName(const char *str);
        id objc_getClass(const char*);
        Method class_getClassMethod(id cls, SEL name);
        void* method_getImplementation(Method);
        int access(const char *path, int amode);

        typedef uint32_t CGDirectDisplayID;
        typedef struct { double width; double height; } CGSize;
        typedef struct { CGPoint origin; CGSize size; } CGRect;
        int32_t CGGetActiveDisplayList(uint32_t maxDisplays, CGDirectDisplayID* displays, uint32_t* count);
        CGRect CGDisplayBounds(CGDirectDisplayID display);
        void* CGDisplayCopyDisplayMode(CGDirectDisplayID display);
        size_t CGDisplayModeGetPixelWidth(void* mode);
        void CGDisplayModeRelease(void* mode);
        void* CGEventCreate(void* source);
        CGPoint CGEventGetLocation(void* event);
        void CFRelease(const void* cf);
    ]])

    -- CoreGraphics gives the mouse and every display in one coordinate system
    -- (points, origin at the top-left of the main display), which works for external monitors
    local ok_cg, cg = pcall(ffi.load, "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    if ok_cg then
        osx_cg = cg
    end

    local ok, lib = pcall(ffi.load, "libobjc")
    if ok then
        osx_lib = lib
        osx_nsevent = {
            class = osx_lib.objc_getClass("NSEvent"),
            sel = osx_lib.sel_registerName("mouseLocation"),
            sel_buttons = osx_lib.sel_registerName("pressedMouseButtons")
        }
        local method = osx_lib.class_getClassMethod(osx_nsevent.class, osx_nsevent.sel)
        if method ~= nil then
            local imp = osx_lib.method_getImplementation(method)
            osx_mouse_location = ffi.cast("CGPoint(*)(void*, void*)", imp)
        end
        local method_buttons = osx_lib.class_getClassMethod(osx_nsevent.class, osx_nsevent.sel_buttons)
        if method_buttons ~= nil then
            local imp = osx_lib.method_getImplementation(method_buttons)
            osx_pressed_buttons = ffi.cast("unsigned long(*)(void*, void*)", imp)
        end
    end
end

---
-- Seconds since an arbitrary point, used for frame-rate independent animation
---@return number
function now_sec()
    return obs.os_gettime_ns() / 1000000000
end

---
-- Query X11 for the pointer. Shared by get_mouse_pos and is_left_button_down.
---@return boolean ok
function x11_query_pointer()
    if x11_lib == nil or x11_display == nil or x11_root == nil or x11_mouse == nil then
        return false
    end
    return x11_lib.XQueryPointer(x11_display, x11_root, x11_mouse.root_win, x11_mouse.child_win,
        x11_mouse.root_x, x11_mouse.root_y, x11_mouse.win_x, x11_mouse.win_y, x11_mouse.mask) ~= 0
end

---
-- Get the current mouse position
---@return table Mouse position
function get_mouse_pos()
    local mouse = { x = 0, y = 0 }

    if ffi.os == "Windows" then
        if win_point and win_physical_cursor and ffi.C.GetPhysicalCursorPos(win_point) ~= 0 then
            mouse.x = win_point[0].x
            mouse.y = win_point[0].y
        elseif win_point and ffi.C.GetCursorPos(win_point) ~= 0 then
            mouse.x = win_point[0].x
            mouse.y = win_point[0].y
        end
    elseif ffi.os == "Linux" then
        if x11_query_pointer() then
            mouse.x = tonumber(x11_mouse.win_x[0])
            mouse.y = tonumber(x11_mouse.win_y[0])
        end
    elseif ffi.os == "OSX" then
        if osx_cg ~= nil then
            local event = osx_cg.CGEventCreate(nil)
            if event ~= nil then
                local point = osx_cg.CGEventGetLocation(event)
                osx_cg.CFRelease(event)
                mouse.x = point.x
                mouse.y = point.y
            end
        elseif osx_mouse_location ~= nil then
            -- Fallback: NSEvent has its origin at the bottom-left of the main display
            local point = osx_mouse_location(osx_nsevent.class, osx_nsevent.sel)
            mouse.x = point.x
            if monitor_info ~= nil then
                if monitor_info.display_height > 0 then
                    mouse.y = monitor_info.display_height - point.y
                else
                    mouse.y = monitor_info.height - point.y
                end
            end
        end
    end

    return mouse
end

---
-- Check whether the left mouse button is currently held down
---@return boolean
function is_left_button_down()
    if ffi.os == "Windows" then
        -- 0x8000 = held now, 0x0001 = pressed since the last call (catches very quick clicks)
        return bit.band(ffi.C.GetAsyncKeyState(0x01), 0x8001) ~= 0
    elseif ffi.os == "Linux" then
        if x11_query_pointer() then
            return bit.band(x11_mouse.mask[0], 256) ~= 0 -- Button1Mask
        end
    elseif ffi.os == "OSX" then
        if osx_pressed_buttons ~= nil then
            return bit.band(tonumber(osx_pressed_buttons(osx_nsevent.class, osx_nsevent.sel_buttons)), 1) ~= 0
        end
    end
    return false
end

---
-- Get the information about display capture sources for the current platform
---@return any
function get_dc_info()
    if ffi.os == "Windows" then
        return {
            source_id = "monitor_capture",
            prop_id = "monitor_id",
            prop_type = "string"
        }
    elseif ffi.os == "Linux" then
        return {
            source_id = "xshm_input",
            prop_id = "screen",
            prop_type = "int"
        }
    elseif ffi.os == "OSX" then
        if major > 29.0 then
            return {
                source_id = "screen_capture",
                prop_id = "display_uuid",
                prop_type = "string"
            }
        else
            return {
                source_id = "display_capture",
                prop_id = "display",
                prop_type = "int"
            }
        end
    end

    return nil
end

---
-- Logs a message to the OBS script console
---@param msg string The message to log
function log(msg)
    if debug_logs then
        obs.script_log(obs.OBS_LOG_INFO, msg)
    end
end

---
-- Format the given lua table into a string
---@param tbl any
---@param indent any
---@return string result The formatted string
function format_table(tbl, indent)
    if not indent then
        indent = 0
    end

    local str = "{\n"
    for key, value in pairs(tbl) do
        local tabs = string.rep("  ", indent + 1)
        if type(value) == "table" then
            str = str .. tabs .. key .. " = " .. format_table(value, indent + 1) .. ",\n"
        else
            str = str .. tabs .. key .. " = " .. tostring(value) .. ",\n"
        end
    end
    str = str .. string.rep("  ", indent) .. "}"

    return str
end

---
-- Linear interpolate between v0 and v1
function lerp(v0, v1, t)
    return v0 * (1 - t) + v1 * t
end

---
-- Ease a time value in and out (cubic)
---@param t number Time between 0 and 1
---@return number
function ease_in_out(t)
    t = t * 2
    if t < 1 then
        return 0.5 * t * t * t
    else
        t = t - 2
        return 0.5 * (t * t * t + 2)
    end
end

---
-- Clamps a given value between min and max
function clamp(min, max, value)
    return math.max(min, math.min(max, value))
end

---
-- Get the size and position of the monitor so that we know the top-left mouse point
---
-- Every monitor as the OS sees it, in the same coordinates as get_mouse_pos().
-- scale = source pixels per mouse unit (2 on a Retina display, else 1).
---@return table list of { x, y, width, height, scale, primary }
function get_monitor_rects()
    local rects = {}

    if ffi.os == "Windows" then
        local ok = pcall(function()
            local cb = ffi.cast("MONITORENUMPROC", function(hmon, hdc, rect, data)
                local mi = ffi.new("MONITORINFO")
                mi.cbSize = ffi.sizeof("MONITORINFO")
                if ffi.C.GetMonitorInfoA(hmon, mi) ~= 0 then
                    local r = mi.rcMonitor
                    table.insert(rects, {
                        x = tonumber(r.left), y = tonumber(r.top),
                        width = tonumber(r.right - r.left), height = tonumber(r.bottom - r.top),
                        scale = 1, primary = bit.band(tonumber(mi.dwFlags), 1) ~= 0
                    })
                end
                return 1
            end)
            -- Physical pixels for every monitor, whatever its Scale setting (-4 = PER_MONITOR_AWARE_V2)
            local old_ctx = nil
            if win_dpi_context then
                old_ctx = ffi.C.SetThreadDpiAwarenessContext(ffi.cast("void*", -4))
            end
            ffi.C.EnumDisplayMonitors(nil, nil, cb, 0)
            if old_ctx ~= nil then
                ffi.C.SetThreadDpiAwarenessContext(old_ctx)
            end
            cb:free()
        end)
        if not ok then
            rects = {}
        end
    elseif ffi.os == "Linux" then
        if x11_randr ~= nil and x11_display ~= nil then
            local n = ffi.new("int[1]")
            local mons = x11_randr.XRRGetMonitors(x11_display, x11_root, 1, n)
            if mons ~= nil then
                for i = 0, n[0] - 1 do
                    local m = mons[i]
                    table.insert(rects, {
                        x = m.x, y = m.y, width = m.width, height = m.height,
                        scale = 1, primary = m.primary ~= 0
                    })
                end
                x11_randr.XRRFreeMonitors(mons)
            end
        end
    elseif ffi.os == "OSX" then
        if osx_cg ~= nil then
            local ids = ffi.new("CGDirectDisplayID[16]")
            local count = ffi.new("uint32_t[1]")
            if osx_cg.CGGetActiveDisplayList(16, ids, count) == 0 then
                for i = 0, count[0] - 1 do
                    local b = osx_cg.CGDisplayBounds(ids[i])
                    local scale = 1
                    local mode = osx_cg.CGDisplayCopyDisplayMode(ids[i])
                    if mode ~= nil then
                        local pw = tonumber(osx_cg.CGDisplayModeGetPixelWidth(mode))
                        osx_cg.CGDisplayModeRelease(mode)
                        if b.size.width > 0 and pw > 0 then
                            scale = pw / b.size.width
                        end
                    end
                    table.insert(rects, {
                        x = b.origin.x, y = b.origin.y, width = b.size.width, height = b.size.height,
                        scale = scale, primary = b.origin.x == 0 and b.origin.y == 0
                    })
                end
            end
        end
    end

    return rects
end

function info_from_rect(r)
    return {
        x = r.x, y = r.y,
        width = math.floor(r.width * r.scale + 0.5), height = math.floor(r.height * r.scale + 0.5),
        scale_x = r.scale, scale_y = r.scale,
        display_width = r.width, display_height = r.height
    }
end

---
-- Decide which monitor a display capture shows.
--   parsed      : position/size read from the capture's monitor name, or nil
--   rects       : get_monitor_rects()
--   src_w/src_h : capture size in pixels
--   trust_parsed: names are in desktop pixels (Windows/Linux) — use them even without a matching rect
---@return table|nil monitor info, string how it was found
function pick_monitor(parsed, rects, src_w, src_h, trust_parsed)
    if parsed ~= nil then
        for _, r in ipairs(rects) do
            if math.abs(r.x - parsed.x) <= 2 and math.abs(r.y - parsed.y) <= 2 then
                return info_from_rect(r), "name+os"
            end
        end
        if trust_parsed or #rects == 0 then
            return parsed, "name"
        end
    end

    -- No usable name: the monitor whose pixel size matches the capture
    local hits = {}
    for _, r in ipairs(rects) do
        if math.abs(r.width * r.scale - src_w) <= 2 and math.abs(r.height * r.scale - src_h) <= 2 then
            table.insert(hits, r)
        end
    end
    if #hits == 1 then
        return info_from_rect(hits[1]), "size"
    end
    if #hits > 1 then
        log("WARNING: " .. #hits .. " màn hình cùng độ phân giải " .. src_w .. "x" .. src_h ..
            " — không biết capture màn nào. Đưa chuột sang màn đó và dùng 'Dùng màn hình đang có chuột'.")
    end
    return parsed, "none"
end

---@param source any The OBS source
---@return table|nil monitor_info The monitor size/top-left point
function get_monitor_info(source)
    local info = nil

    -- Only do the expensive look up if we are using automatic calculations on a display source
    if is_display_capture(source) and not use_monitor_override then
        local dc_info = get_dc_info()
        if dc_info ~= nil then
            local props = obs.obs_source_properties(source)
            if props ~= nil then
                local monitor_id_prop = obs.obs_properties_get(props, dc_info.prop_id)
                if monitor_id_prop then
                    local found = nil
                    local settings = obs.obs_source_get_settings(source)
                    if settings ~= nil then
                        local to_match
                        if dc_info.prop_type == "string" then
                            to_match = obs.obs_data_get_string(settings, dc_info.prop_id)
                        elseif dc_info.prop_type == "int" then
                            to_match = obs.obs_data_get_int(settings, dc_info.prop_id)
                        end

                        local item_count = obs.obs_property_list_item_count(monitor_id_prop)
                        for i = 0, item_count - 1 do
                            local name = obs.obs_property_list_item_name(monitor_id_prop, i)
                            local value
                            if dc_info.prop_type == "string" then
                                value = obs.obs_property_list_item_string(monitor_id_prop, i)
                            elseif dc_info.prop_type == "int" then
                                value = obs.obs_property_list_item_int(monitor_id_prop, i)
                            end

                            if value == to_match then
                                found = name
                                break
                            end
                        end
                        obs.obs_data_release(settings)
                    end

                    -- Monitor names look like "U2790B: 3840x2160 @ -1920,0 (Primary Monitor)"
                    if found then
                        log("Parsing display name: " .. found)
                        local x, y = found:match("(-?%d+),(-?%d+)")
                        local width, height = found:match("(%d+)x(%d+)")

                        info = {
                            x = tonumber(x, 10) or 0,
                            y = tonumber(y, 10) or 0,
                            width = tonumber(width, 10) or 0,
                            height = tonumber(height, 10) or 0,
                            scale_x = 1,
                            scale_y = 1
                        }
                        info.display_width = info.width
                        info.display_height = info.height

                        log("Parsed the following display information\n" .. format_table(info))

                        if info.width == 0 and info.height == 0 then
                            info = nil
                        end
                    end
                end

                obs.obs_properties_destroy(props)
            end
        end

        -- Check the name against the monitors the OS reports (fixes external monitors whose name
        -- can't be parsed, and Retina scaling on macOS)
        local src_w = obs.obs_source_get_base_width(source)
        local src_h = obs.obs_source_get_base_height(source)
        local how
        info, how = pick_monitor(info, get_monitor_rects(), src_w, src_h, ffi.os ~= "OSX")
        if info ~= nil then
            log("Monitor (" .. how .. "): " .. info.x .. "," .. info.y .. " " .. info.width .. "x" .. info.height ..
                " scale " .. info.scale_x)
        end
    end

    if use_monitor_override then
        info = {
            x = monitor_override_x,
            y = monitor_override_y,
            width = monitor_override_w,
            height = monitor_override_h,
            scale_x = monitor_override_sx,
            scale_y = monitor_override_sy,
            display_width = monitor_override_dw,
            display_height = monitor_override_dh
        }
    end

    if not info then
        log("WARNING: Could not auto calculate zoom source position and size.\n" ..
            "         Try using the 'Set manual source position' option and adding override values")
    end

    return info
end

---
-- Check to see if the specified source is a display capture source
---@param source_to_check any The source to check
---@return boolean result True if source is a display capture, false if it is nil or some other source type
function is_display_capture(source_to_check)
    if source_to_check == nil then
        return false
    end

    local dc_info = get_dc_info()
    return dc_info ~= nil and obs.obs_source_get_id(source_to_check) == dc_info.source_id
end

function start_timer()
    if not is_timer_running then
        is_timer_running = true
        last_tick = now_sec()
        local timer_interval = math.max(1, math.floor(obs.obs_get_frame_interval_ns() / 1000000))
        obs.timer_add(on_timer, timer_interval)
    end
end

function stop_timer()
    if is_timer_running then
        is_timer_running = false
        obs.timer_remove(on_timer)
    end
end

---
-- Releases the current sceneitem and resets data back to default
function release_sceneitem()
    stop_timer()

    zoom_state = ZoomState.None
    zoom_target = nil
    anim_from = nil
    zoomed_by_click = false
    is_following_mouse = false

    if sceneitem ~= nil then
        if crop_filter ~= nil and source ~= nil then
            log("Zoom crop filter removed")
            obs.obs_source_filter_remove(source, crop_filter)
            obs.obs_source_release(crop_filter)
            crop_filter = nil
        end

        if crop_filter_temp ~= nil and source ~= nil then
            log("Conversion crop filter removed")
            obs.obs_source_filter_remove(source, crop_filter_temp)
            obs.obs_source_release(crop_filter_temp)
            crop_filter_temp = nil
        end

        if crop_filter_settings ~= nil then
            obs.obs_data_release(crop_filter_settings)
            crop_filter_settings = nil
        end

        if sharpen_filter ~= nil and source ~= nil then
            log("Sharpen filter removed")
            obs.obs_source_filter_remove(source, sharpen_filter)
            obs.obs_source_release(sharpen_filter)
            sharpen_filter = nil
        end

        if sharpen_settings ~= nil then
            obs.obs_data_release(sharpen_settings)
            sharpen_settings = nil
        end
        sharpen_last = -1

        if scale_filter_orig ~= nil then
            obs.obs_sceneitem_set_scale_filter(sceneitem, scale_filter_orig)
            scale_filter_orig = nil
            scale_filter_current = nil
        end

        if sceneitem_info_orig ~= nil then
            log("Transform info reset back to original")
            sceneitem_set_info(sceneitem, sceneitem_info_orig)
            sceneitem_info_orig = nil
        end

        if sceneitem_crop_orig ~= nil then
            log("Transform crop reset back to original")
            obs.obs_sceneitem_set_crop(sceneitem, sceneitem_crop_orig)
            sceneitem_crop_orig = nil
        end

        obs.obs_sceneitem_release(sceneitem)
        sceneitem = nil
    end

    if source ~= nil then
        obs.obs_source_release(source)
        source = nil
    end
end

---
-- Find the sceneitem for source_name starting at root_scene.
-- BFS through nested scenes and groups. Returns an addref'd sceneitem or nil.
function find_scene_item_by_name(root_scene)
    local queue = { root_scene }
    local visited = {}

    while #queue > 0 do
        local s = table.remove(queue, 1)
        local scene_name = obs.obs_source_get_name(obs.obs_scene_get_source(s))

        if not visited[scene_name] then
            visited[scene_name] = true
            log("Checking scene '" .. scene_name .. "'")

            local found = obs.obs_scene_find_source(s, source_name)
            if found ~= nil then
                log("Found sceneitem '" .. source_name .. "'")
                obs.obs_sceneitem_addref(found)
                return found
            end

            local all_items = obs.obs_scene_enum_items(s)
            if all_items then
                for _, item in ipairs(all_items) do
                    if obs.obs_sceneitem_is_group(item) then
                        table.insert(queue, obs.obs_sceneitem_group_get_scene(item))
                    else
                        local nested = obs.obs_sceneitem_get_source(item)
                        if nested ~= nil and obs.obs_source_is_scene(nested) then
                            table.insert(queue, obs.obs_scene_from_source(nested))
                        end
                    end
                end
                obs.sceneitem_list_release(all_items)
            end
        end
    end

    return nil
end

---
-- Updates the current sceneitem with a refreshed set of data from the source
-- Optionally will release the existing sceneitem and get a new one from the current scene
---@param find_newest boolean True to release the current sceneitem and get a new one
function refresh_sceneitem(find_newest)
    local source_raw = { width = 0, height = 0 }

    if find_newest then
        release_sceneitem()

        -- "<None>" lets users reset the crop data back to the original, update it,
        -- and then force the conversion to happen again by re-selecting the source.
        if source_name == nil or source_name == "" or source_name == NONE_SOURCE then
            return
        end

        log("Finding sceneitem for Zoom Source '" .. source_name .. "'")
        source = obs.obs_get_source_by_name(source_name)
        if source ~= nil then
            -- The named source reports a valid size during load even when the sceneitem source doesn't
            source_raw.width = obs.obs_source_get_width(source)
            source_raw.height = obs.obs_source_get_height(source)

            local scene_source = obs.obs_frontend_get_current_scene()
            if scene_source ~= nil then
                sceneitem = find_scene_item_by_name(obs.obs_scene_from_source(scene_source))
                obs.obs_source_release(scene_source)
            end

            if not sceneitem then
                log("WARNING: Source not part of the current scene hierarchy.\n" ..
                    "         Try selecting a different zoom source or switching scenes.")
                obs.obs_source_release(source)
                source = nil
                return
            end
        end
    end

    -- Nothing to set up yet (e.g. the script loads before OBS has created the sources)
    if source == nil then
        return
    end

    -- Always re-read: the capture may have been switched to another monitor since last time
    monitor_info = get_monitor_info(source)

    local is_non_display_capture = not is_display_capture(source)
    if is_non_display_capture and not use_monitor_override then
        log("ERROR: Nguồn zoom không phải là Display Capture.\n" ..
            "       Bạn PHẢI bật 'Set manual source position' và đặt giá trị override đúng cho kích thước và vị trí.")
    end

    if sceneitem == nil or source == nil then
        return
    end

    -- Capture the original settings so we can restore them later
    sceneitem_info_orig = obs.obs_transform_info()
    sceneitem_get_info(sceneitem, sceneitem_info_orig)

    sceneitem_crop_orig = obs.obs_sceneitem_crop()
    obs.obs_sceneitem_get_crop(sceneitem, sceneitem_crop_orig)

    sceneitem_info = obs.obs_transform_info()
    sceneitem_get_info(sceneitem, sceneitem_info)

    sceneitem_crop = obs.obs_sceneitem_crop()
    obs.obs_sceneitem_get_crop(sceneitem, sceneitem_crop)

    scale_filter_orig = obs.obs_sceneitem_get_scale_filter(sceneitem)
    scale_filter_current = scale_filter_orig

    if is_non_display_capture then
        -- Non-Display Capture sources don't correctly report crop values
        sceneitem_crop_orig.left = 0
        sceneitem_crop_orig.top = 0
        sceneitem_crop_orig.right = 0
        sceneitem_crop_orig.bottom = 0
    end

    -- Get the current source size (this will be the value after any applied crop filters)
    local source_width = obs.obs_source_get_base_width(source)
    local source_height = obs.obs_source_get_base_height(source)
    zoom_info.base_w, zoom_info.base_h = source_width, source_height
    zoom_info.crop_sig = user_crop_signature(source)

    if source_width == 0 then
        source_width = source_raw.width
    end
    if source_height == 0 then
        source_height = source_raw.height
    end

    if source_width == 0 or source_height == 0 then
        log("ERROR: Không xác định được kích thước nguồn.\n" ..
            "       Hãy bật 'Set manual source position' và nhập giá trị override")

        if monitor_info ~= nil then
            source_width = monitor_info.width
            source_height = monitor_info.height
        end
    else
        log("Using source size: " .. source_width .. ", " .. source_height)
    end

    -- Convert the current transform into a bounding box one that we can modify for zooming
    if sceneitem_info.bounds_type == obs.OBS_BOUNDS_NONE then
        sceneitem_info.bounds_type = obs.OBS_BOUNDS_SCALE_INNER
        sceneitem_info.bounds_alignment = 5 -- (5 == OBS_ALIGN_TOP | OBS_ALIGN_LEFT)
        sceneitem_info.bounds.x = source_width * sceneitem_info.scale.x
        sceneitem_info.bounds.y = source_height * sceneitem_info.scale.y

        sceneitem_set_info(sceneitem, sceneitem_info)

        log("WARNING: Transform không dùng bounding box nên đã được tự chuyển sang 'Scale to inner bounds'.\n" ..
            "         Transform gốc sẽ được khôi phục khi bỏ chọn nguồn / đổi scene / tắt OBS.")
    end

    -- Get information about any existing crop filters (that aren't ours)
    zoom_info.source_crop_filter = { x = 0, y = 0, w = 0, h = 0 }
    local found_crop_filter = false
    local filters = obs.obs_source_enum_filters(source)
    if filters ~= nil then
        for _, v in ipairs(filters) do
            if obs.obs_source_get_id(v) == "crop_filter" then
                local name = obs.obs_source_get_name(v)
                if name ~= CROP_FILTER_NAME and name ~= "temp_" .. CROP_FILTER_NAME then
                    found_crop_filter = true
                    local settings = obs.obs_source_get_settings(v)
                    if settings ~= nil then
                        if not obs.obs_data_get_bool(settings, "relative") then
                            local f = zoom_info.source_crop_filter
                            f.x = f.x + obs.obs_data_get_int(settings, "left")
                            f.y = f.y + obs.obs_data_get_int(settings, "top")
                            f.w = f.w + obs.obs_data_get_int(settings, "cx")
                            f.h = f.h + obs.obs_data_get_int(settings, "cy")
                            log("Existing crop/pad filter (" .. name .. "). Applying " .. format_table(f))
                        else
                            log("WARNING: Filter crop/pad '" .. name .. "' đang bật 'Relative'.\n" ..
                                "         Điều này sẽ gây lỗi khi zoom. Hãy tắt 'Relative' trong filter đó.")
                        end
                        obs.obs_data_release(settings)
                    end
                end
            end
        end

        obs.source_list_release(filters)
    end

    -- A transform crop has to become a crop filter so that it works correctly with zooming
    local c = sceneitem_crop_orig
    if not found_crop_filter and (c.left ~= 0 or c.top ~= 0 or c.right ~= 0 or c.bottom ~= 0) then
        log("Creating new crop filter")

        source_width = source_width - (c.left + c.right)
        source_height = source_height - (c.top + c.bottom)

        zoom_info.source_crop_filter.x = c.left
        zoom_info.source_crop_filter.y = c.top
        zoom_info.source_crop_filter.w = source_width
        zoom_info.source_crop_filter.h = source_height

        local settings = obs.obs_data_create()
        obs.obs_data_set_bool(settings, "relative", false)
        obs.obs_data_set_int(settings, "left", zoom_info.source_crop_filter.x)
        obs.obs_data_set_int(settings, "top", zoom_info.source_crop_filter.y)
        obs.obs_data_set_int(settings, "cx", zoom_info.source_crop_filter.w)
        obs.obs_data_set_int(settings, "cy", zoom_info.source_crop_filter.h)
        crop_filter_temp = obs.obs_source_create_private("crop_filter", "temp_" .. CROP_FILTER_NAME, settings)
        obs.obs_source_filter_add(source, crop_filter_temp)
        obs.obs_data_release(settings)

        sceneitem_crop.left = 0
        sceneitem_crop.top = 0
        sceneitem_crop.right = 0
        sceneitem_crop.bottom = 0
        obs.obs_sceneitem_set_crop(sceneitem, sceneitem_crop)

        log("WARNING: Transform crop đã được tự chuyển thành filter crop/pad tạm thời.\n" ..
            "         Crop gốc sẽ được khôi phục khi bỏ chọn nguồn / đổi scene / tắt OBS.")
    elseif found_crop_filter then
        source_width = zoom_info.source_crop_filter.w
        source_height = zoom_info.source_crop_filter.h
    end

    zoom_info.source_size = { width = source_width, height = source_height }
    zoom_info.source_crop = { l = c.left, t = c.top, r = c.right, b = c.bottom }

    crop_filter_info_orig = { x = 0, y = 0, w = source_width, h = source_height }
    crop_filter_info = { x = 0, y = 0, w = source_width, h = source_height }

    -- Get or create our crop filter that we change during zoom
    crop_filter = obs.obs_source_get_filter_by_name(source, CROP_FILTER_NAME)
    if crop_filter == nil then
        crop_filter_settings = obs.obs_data_create()
        obs.obs_data_set_bool(crop_filter_settings, "relative", false)
        crop_filter = obs.obs_source_create_private("crop_filter", CROP_FILTER_NAME, crop_filter_settings)
        obs.obs_source_filter_add(source, crop_filter)
    else
        crop_filter_settings = obs.obs_source_get_settings(crop_filter)
    end

    obs.obs_source_filter_set_order(source, crop_filter, obs.OBS_ORDER_MOVE_BOTTOM)
    crop_last_applied.x = -1 -- force the first update through
    set_crop_settings(crop_filter_info_orig)
end

---
-- Make sure we have a sceneitem to zoom, refreshing it if needed (fix hotkey not working after load)
---@return boolean ok
function ensure_sceneitem()
    if sceneitem == nil and source_name ~= nil and source_name ~= "" and source_name ~= NONE_SOURCE then
        log("Sceneitem is nil, attempting refresh...")
        refresh_sceneitem(true)
    end

    if sceneitem == nil then
        log("WARNING: Không thể zoom - không tìm thấy Zoom Source trong scene hiện tại.\n" ..
            "         Đảm bảo Zoom Source đã được chọn và nằm trong scene đang phát.")
        return false
    end
    return true
end

---
-- Convert the desktop mouse position into the zoom source's pixel space
---@return table
function get_mouse_in_source(zoom)
    local mouse = get_mouse_pos()

    -- The display capture's top-left is 0,0 but the mouse uses the whole desktop
    -- (a second monitor might start at x:1920), so offset by the monitor position
    if monitor_info then
        mouse.x = mouse.x - monitor_info.x
        mouse.y = mouse.y - monitor_info.y
    end

    -- Mouse units -> source pixels (Retina = 2, cloned / scaled sources). This must happen before
    -- the crop offset, which is already in source pixels.
    if monitor_info and monitor_info.scale_x and monitor_info.scale_y then
        mouse.x = mouse.x * monitor_info.scale_x
        mouse.y = mouse.y * monitor_info.scale_y
    end

    -- Offset by any crop filter so a 100px crop makes 100,0 become 0,0
    mouse.x = mouse.x - zoom.source_crop_filter.x
    mouse.y = mouse.y - zoom.source_crop_filter.y

    return mouse
end

---
-- Get the target position that we will attempt to zoom towards
---@param zoom any
---@return table
function get_target_position(zoom)
    local mouse = get_mouse_in_source(zoom)

    -- Dividing the crop size by the zoom factor shows less of the image in the same space = zoomed in
    local new_size = {
        width = zoom.source_size.width / zoom.zoom_to,
        height = zoom.source_size.height / zoom.zoom_to
    }

    local crop = {
        x = mouse.x - new_size.width * 0.5,
        y = mouse.y - new_size.height * 0.5,
        w = new_size.width,
        h = new_size.height,
    }

    -- Keep the zoom inside the source so we never show something the user is hiding with a crop
    crop.x = math.floor(clamp(0, (zoom.source_size.width - new_size.width), crop.x))
    crop.y = math.floor(clamp(0, (zoom.source_size.height - new_size.height), crop.y))

    return {
        crop = crop,
        raw_center = mouse,
        clamped_center = { x = math.floor(crop.x + crop.w * 0.5), y = math.floor(crop.y + crop.h * 0.5) }
    }
end

---
-- Start an animation from the current crop to the target
function begin_animation(state, target)
    zoom_state = state
    zoom_time = 0
    zoom_target = target
    anim_from = { x = crop_filter_info.x, y = crop_filter_info.y, w = crop_filter_info.w, h = crop_filter_info.h }
    start_timer()
end

---
-- The user's own crop/pad filters on the capture, as a comparable string
function user_crop_signature(src)
    local parts = {}
    local filters = obs.obs_source_enum_filters(src)
    if filters ~= nil then
        for _, f in ipairs(filters) do
            local name = obs.obs_source_get_name(f)
            if obs.obs_source_get_id(f) == "crop_filter" and name ~= CROP_FILTER_NAME
                and name ~= "temp_" .. CROP_FILTER_NAME then
                local st = obs.obs_source_get_settings(f)
                table.insert(parts, table.concat({ name, tostring(obs.obs_source_enabled(f)),
                    tostring(obs.obs_data_get_bool(st, "relative")),
                    obs.obs_data_get_int(st, "left"), obs.obs_data_get_int(st, "top"),
                    obs.obs_data_get_int(st, "cx"), obs.obs_data_get_int(st, "cy") }, ":"))
                obs.obs_data_release(st)
            end
        end
        obs.source_list_release(filters)
    end
    return table.concat(parts, "|")
end

---
-- Before zooming in from the normal view: pick up a capture that was switched to another monitor,
-- changed resolution, or got its crop filters edited since the scene was set up.
---@return boolean ok still have a sceneitem to zoom
function sync_with_capture()
    if zoom_state ~= ZoomState.None or sceneitem == nil or source == nil then
        return sceneitem ~= nil
    end
    local w = obs.obs_source_get_base_width(source)
    local h = obs.obs_source_get_base_height(source)
    if w ~= zoom_info.base_w or h ~= zoom_info.base_h or user_crop_signature(source) ~= zoom_info.crop_sig then
        log("Capture changed (" .. tostring(zoom_info.base_w) .. "x" .. tostring(zoom_info.base_h) ..
            " -> " .. w .. "x" .. h .. " or crop filters), refreshing")
        refresh_sceneitem(true)
    elseif not use_monitor_override then
        monitor_info = get_monitor_info(source)
    end
    return sceneitem ~= nil
end

function start_zoom_in(by_click)
    log("Zooming in" .. (by_click and " (click)" or ""))
    zoom_info.zoom_to = zoom_value
    locked_center = nil
    locked_last_pos = nil
    zoomed_by_click = by_click and true or false
    last_activity = now_sec()
    local target = get_target_position(zoom_info)
    if debug_logs then
        local m = get_mouse_pos()
        log("Mouse " .. m.x .. "," .. m.y .. " -> source " .. math.floor(target.raw_center.x) .. "," ..
            math.floor(target.raw_center.y) .. " (source " .. zoom_info.source_size.width .. "x" ..
            zoom_info.source_size.height .. ", monitor " .. (monitor_info and (monitor_info.x .. "," .. monitor_info.y)
            or "?") .. ")")
    end
    begin_animation(ZoomState.ZoomingIn, target)
end

function start_zoom_out()
    log("Zooming out")
    locked_center = nil
    locked_last_pos = nil
    zoomed_by_click = false
    if is_following_mouse then
        is_following_mouse = false
        log("Tracking mouse is off (due to zoom out)")
    end
    begin_animation(ZoomState.ZoomingOut, { crop = crop_filter_info_orig })
end

function on_toggle_follow(pressed)
    if not pressed then
        return
    end

    is_following_mouse = not is_following_mouse
    log("Tracking mouse is " .. (is_following_mouse and "on" or "off"))

    if zoom_state == ZoomState.ZoomedIn then
        if is_following_mouse then
            start_timer()
        else
            -- Nothing left to animate, free the per-frame callback
            stop_timer()
        end
    end
end

function on_toggle_zoom(pressed)
    if not pressed or not ensure_sceneitem() then
        return
    end

    -- Pressing during an animation reverses it from wherever it currently is
    if zoom_state == ZoomState.ZoomedIn or zoom_state == ZoomState.ZoomingIn then
        start_zoom_out()
    elseif sync_with_capture() then
        start_zoom_in(false)
    end
end

---
-- Change the zoom factor live (hotkeys "Zoom in more" / "Zoom in less")
function change_zoom_level(delta)
    zoom_value = clamp(1, MAX_ZOOM, zoom_value + delta)
    log("Zoom factor is now " .. zoom_value)

    if sceneitem == nil or not (zoom_state == ZoomState.ZoomedIn or zoom_state == ZoomState.ZoomingIn) then
        return
    end

    if zoom_value <= 1 then
        start_zoom_out()
        return
    end

    zoom_info.zoom_to = zoom_value
    locked_center = nil
    begin_animation(ZoomState.ZoomingIn, get_target_position(zoom_info))
end

---
-- "Dùng màn hình đang có chuột": take the monitor under the cursor as the zoom source's monitor and
-- store it as the manual position, so it also survives restarts.
function calibrate_monitor()
    local m = get_mouse_pos()
    for _, r in ipairs(get_monitor_rects()) do
        if m.x >= r.x and m.x < r.x + r.width and m.y >= r.y and m.y < r.y + r.height then
            local info = info_from_rect(r)
            use_monitor_override = true
            monitor_override_x = math.floor(r.x + 0.5)
            monitor_override_y = math.floor(r.y + 0.5)
            monitor_override_w = info.width
            monitor_override_h = info.height
            monitor_override_sx = r.scale
            monitor_override_sy = r.scale
            monitor_override_dw = math.floor(r.width + 0.5)
            monitor_override_dh = math.floor(r.height + 0.5)
            if script_settings ~= nil then
                obs.obs_data_set_bool(script_settings, "use_monitor_override", true)
                obs.obs_data_set_int(script_settings, "monitor_override_x", monitor_override_x)
                obs.obs_data_set_int(script_settings, "monitor_override_y", monitor_override_y)
                obs.obs_data_set_int(script_settings, "monitor_override_w", monitor_override_w)
                obs.obs_data_set_int(script_settings, "monitor_override_h", monitor_override_h)
                obs.obs_data_set_double(script_settings, "monitor_override_sx", r.scale)
                obs.obs_data_set_double(script_settings, "monitor_override_sy", r.scale)
                obs.obs_data_set_int(script_settings, "monitor_override_dw", monitor_override_dw)
                obs.obs_data_set_int(script_settings, "monitor_override_dh", monitor_override_dh)
            end
            monitor_info = get_monitor_info(source)
            obs.script_log(obs.OBS_LOG_INFO, string.format(
                "[zoom-to-mouse] Dùng màn hình tại %d,%d (%dx%d, scale %.2f) cho Zoom Source",
                monitor_override_x, monitor_override_y, info.width, info.height, r.scale))
            return true
        end
    end
    obs.script_log(obs.OBS_LOG_WARNING, "[zoom-to-mouse] Không đọc được danh sách màn hình từ hệ điều hành " ..
        "— hãy nhập 'Set manual source position' bằng tay")
    return false
end

function on_calibrate(pressed)
    if pressed then
        calibrate_monitor()
    end
end

function on_calibrate_timer()
    obs.timer_remove(on_calibrate_timer)
    calibrate_monitor()
end

function on_zoom_more(pressed)
    if pressed then
        change_zoom_level(zoom_step)
    end
end

function on_zoom_less(pressed)
    if pressed then
        change_zoom_level(-zoom_step)
    end
end

---
-- Follow the mouse while zoomed in (only x/y move, width/height stay constant)
---@param frames number How many 60fps frames have passed since the last tick
function update_follow(frames)
    zoom_target = get_target_position(zoom_info)

    if not use_follow_outside_bounds then
        local rc = zoom_target.raw_center
        local cr = zoom_target.crop
        if rc.x < cr.x or rc.x > cr.x + cr.w or rc.y < cr.y or rc.y > cr.y + cr.h then
            return
        end
    end

    -- A locked_center means we are in a safe zone and shouldn't track until the mouse leaves it
    if locked_center ~= nil then
        local diff = {
            x = zoom_target.raw_center.x - locked_center.x,
            y = zoom_target.raw_center.y - locked_center.y
        }

        local track = {
            x = zoom_target.crop.w * (0.5 - (follow_border * 0.01)),
            y = zoom_target.crop.h * (0.5 - (follow_border * 0.01))
        }

        if math.abs(diff.x) > track.x or math.abs(diff.y) > track.y then
            locked_center = nil
            locked_last_pos = {
                x = zoom_target.raw_center.x,
                y = zoom_target.raw_center.y,
                diff_x = diff.x,
                diff_y = diff.y
            }
            log("Left the locked zone - resume tracking")
        end
    end

    if locked_center == nil and (zoom_target.crop.x ~= crop_filter_info.x or zoom_target.crop.y ~= crop_filter_info.y) then
        -- Same feel as a per-frame lerp at 60fps, but independent of the OBS frame rate
        local t = 1 - math.pow(1 - follow_speed, frames)
        crop_filter_info.x = lerp(crop_filter_info.x, zoom_target.crop.x, t)
        crop_filter_info.y = lerp(crop_filter_info.y, zoom_target.crop.y, t)
        -- Snap the last half pixel, otherwise the lerp never reaches the edge and floor() leaves it 1px short
        if math.abs(crop_filter_info.x - zoom_target.crop.x) < 0.5 then crop_filter_info.x = zoom_target.crop.x end
        if math.abs(crop_filter_info.y - zoom_target.crop.y) < 0.5 then crop_filter_info.y = zoom_target.crop.y end
        set_crop_settings(crop_filter_info)

        -- Check to see if the mouse has stopped moving long enough to create a new safe zone
        if locked_last_pos ~= nil then
            local diff = {
                x = math.abs(crop_filter_info.x - zoom_target.crop.x),
                y = math.abs(crop_filter_info.y - zoom_target.crop.y),
                auto_x = zoom_target.raw_center.x - locked_last_pos.x,
                auto_y = zoom_target.raw_center.y - locked_last_pos.y
            }

            locked_last_pos.x = zoom_target.raw_center.x
            locked_last_pos.y = zoom_target.raw_center.y

            local lock = false
            if math.abs(locked_last_pos.diff_x) > math.abs(locked_last_pos.diff_y) then
                lock = (diff.auto_x < 0 and locked_last_pos.diff_x > 0) or (diff.auto_x > 0 and locked_last_pos.diff_x < 0)
            else
                lock = (diff.auto_y < 0 and locked_last_pos.diff_y > 0) or (diff.auto_y > 0 and locked_last_pos.diff_y < 0)
            end

            if (lock and use_follow_auto_lock) or (diff.x <= follow_safezone_sensitivity and diff.y <= follow_safezone_sensitivity) then
                -- The new center is the camera position (which lags the mouse because we lerp towards it)
                locked_center = {
                    x = math.floor(crop_filter_info.x + zoom_target.crop.w * 0.5),
                    y = math.floor(crop_filter_info.y + zoom_target.crop.h * 0.5)
                }
                log("Cursor stopped. Locked at " .. locked_center.x .. ", " .. locked_center.y)
            end
        end
    end
end

function on_timer()
    -- Safety guard: stop if the sceneitem or crop filter got released mid animation
    if sceneitem == nil or crop_filter == nil then
        stop_timer()
        zoom_state = ZoomState.None
        return
    end

    if zoom_target == nil then
        return
    end

    local now = now_sec()
    local frames = clamp(0, 6, (now - last_tick) * 60)
    last_tick = now

    if zoom_state == ZoomState.ZoomingIn or zoom_state == ZoomState.ZoomingOut then
        zoom_time = math.min(1, zoom_time + zoom_speed * frames)

        -- Keep the mouse in view while zooming in, in case the animation is slow
        if zoom_state == ZoomState.ZoomingIn and use_auto_follow_mouse then
            zoom_target = get_target_position(zoom_info)
        end

        local e = ease_in_out(zoom_time)
        crop_filter_info.x = lerp(anim_from.x, zoom_target.crop.x, e)
        crop_filter_info.y = lerp(anim_from.y, zoom_target.crop.y, e)
        crop_filter_info.w = lerp(anim_from.w, zoom_target.crop.w, e)
        crop_filter_info.h = lerp(anim_from.h, zoom_target.crop.h, e)
        set_crop_settings(crop_filter_info)

        if zoom_time >= 1 then
            if zoom_state == ZoomState.ZoomingOut then
                log("Zoomed out")
                zoom_state = ZoomState.None
                zoom_target = nil
                stop_timer()
            else
                log("Zoomed in")
                zoom_state = ZoomState.ZoomedIn

                if use_auto_follow_mouse then
                    is_following_mouse = true
                    log("Tracking mouse is on (due to auto follow)")
                end

                if is_following_mouse then
                    -- Use the current position as the center for the follow safezone
                    if follow_border < 50 then
                        locked_center = { x = zoom_target.clamped_center.x, y = zoom_target.clamped_center.y }
                        log("Tracking locked to " .. locked_center.x .. ", " .. locked_center.y)
                    end
                else
                    stop_timer()
                end
            end
        end
    elseif zoom_state == ZoomState.ZoomedIn and is_following_mouse then
        update_follow(frames)
    end
end

---
-- Push the crop to OBS, but only when the integer values actually changed.
-- While the camera rests (locked or converged) this skips the filter update every frame.
function set_crop_settings(crop)
    if crop_filter == nil or crop_filter_settings == nil then
        return
    end

    local x = math.floor(crop.x)
    local y = math.floor(crop.y)
    local w = math.floor(crop.w)
    local h = math.floor(crop.h)
    local last = crop_last_applied
    if last.x == x and last.y == y and last.w == w and last.h == h then
        return
    end
    last.x, last.y, last.w, last.h = x, y, w, h

    obs.obs_data_set_int(crop_filter_settings, "left", x)
    obs.obs_data_set_int(crop_filter_settings, "top", y)
    obs.obs_data_set_int(crop_filter_settings, "cx", w)
    obs.obs_data_set_int(crop_filter_settings, "cy", h)
    obs.obs_source_update(crop_filter, crop_filter_settings)

    update_zoom_quality(w)
end

---
-- Create (or reuse) our Sharpen filter. It sits after the crop so it sharpens the zoomed area.
function ensure_sharpen_filter()
    if sharpen_filter ~= nil or source == nil then
        return sharpen_filter ~= nil
    end

    sharpen_filter = obs.obs_source_get_filter_by_name(source, SHARPEN_FILTER_NAME)
    if sharpen_filter == nil then
        sharpen_settings = obs.obs_data_create()
        obs.obs_data_set_double(sharpen_settings, "sharpness", 0)
        sharpen_filter = obs.obs_source_create_private("sharpness_filter_v2", SHARPEN_FILTER_NAME, sharpen_settings)
        if sharpen_filter == nil then
            obs.obs_data_release(sharpen_settings)
            sharpen_settings = nil
            return false
        end
        obs.obs_source_filter_add(source, sharpen_filter)
    else
        sharpen_settings = obs.obs_source_get_settings(sharpen_filter)
    end

    obs.obs_source_filter_set_order(source, sharpen_filter, obs.OBS_ORDER_MOVE_BOTTOM)
    obs.obs_source_set_enabled(sharpen_filter, false)
    sharpen_last = -1
    return true
end

---
-- Fight the blur of upscaling a small crop back to full size:
--  * switch the sceneitem to a sharper scale filter (Lanczos by default) while zoomed in
--  * fade a Sharpen filter in proportionally to the zoom (full strength from 2x)
-- Both go back to the original setting once fully zoomed out.
---@param crop_w number Current crop width in pixels
function update_zoom_quality(crop_w)
    if sceneitem == nil or crop_w <= 0 then
        return
    end

    local ratio = crop_filter_info_orig.w / crop_w
    local zoomed = ratio > 1.001

    if scale_filter_orig ~= nil then
        local want = scale_filter_orig
        if zoomed and scale_filter_zoomed ~= SCALE_KEEP then
            want = scale_filter_zoomed
        end
        if want ~= scale_filter_current then
            obs.obs_sceneitem_set_scale_filter(sceneitem, want)
            scale_filter_current = want
            log("Scale filter set to " .. want)
        end
    end

    local strength = 0
    if zoomed and sharpen_strength > 0 then
        strength = math.floor(sharpen_strength * clamp(0, 1, ratio - 1) * 100 + 0.5) / 100
    end

    if strength == sharpen_last then
        return
    end
    if strength > 0 and not ensure_sharpen_filter() then
        return
    end
    if sharpen_filter ~= nil then
        if strength > 0 then
            obs.obs_data_set_double(sharpen_settings, "sharpness", strength)
            obs.obs_source_update(sharpen_filter, sharpen_settings)
        end
        obs.obs_source_set_enabled(sharpen_filter, strength > 0)
    end
    sharpen_last = strength
end

---
-- Auto zoom on click (Screen Studio style): a left click inside the zoom source zooms in,
-- and after `auto_zoom_out_delay` seconds without mouse activity it zooms back out.
function on_click_poll()
    local now = now_sec()
    local mouse = get_mouse_pos()
    local down = is_left_button_down()

    if last_mouse == nil or math.abs(mouse.x - last_mouse.x) + math.abs(mouse.y - last_mouse.y) > 2 then
        last_mouse = mouse
        last_activity = now
    end
    if down then
        last_activity = now
    end

    if down and not click_was_down then
        on_mouse_click()
    end
    click_was_down = down

    if auto_zoom_out_delay > 0 and zoomed_by_click and zoom_state == ZoomState.ZoomedIn and
        now - last_activity >= auto_zoom_out_delay then
        log("No mouse activity for " .. auto_zoom_out_delay .. "s - auto zoom out")
        start_zoom_out()
    end
end

function on_mouse_click()
    if zoom_state ~= ZoomState.None and zoom_state ~= ZoomState.ZoomingOut then
        return
    end
    if not ensure_sceneitem() or not sync_with_capture() then
        return
    end

    -- Ignore clicks on other monitors
    local m = get_mouse_in_source(zoom_info)
    if m.x < 0 or m.y < 0 or m.x > zoom_info.source_size.width or m.y > zoom_info.source_size.height then
        return
    end

    start_zoom_in(true)
end

function update_click_poll()
    if use_click_zoom and not is_click_poll_running then
        is_click_poll_running = true
        click_was_down = is_left_button_down()
        last_mouse = nil
        last_activity = now_sec()
        obs.timer_add(on_click_poll, CLICK_POLL_MS)
    elseif not use_click_zoom and is_click_poll_running then
        is_click_poll_running = false
        obs.timer_remove(on_click_poll)
    end
end

function on_transition_start(t)
    log("Transition started")
    -- Remove the crop as the transition starts to avoid a visible jump from old crop to new
    release_sceneitem()
end

function on_frontend_event(event)
    if event == obs.OBS_FRONTEND_EVENT_SCENE_CHANGED then
        log("Scene changed")
        -- Look for a source with the same name in the new scene
        refresh_sceneitem(true)
    elseif event == obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGING or event == obs.OBS_FRONTEND_EVENT_EXIT then
        -- Restore the user's transform before OBS saves the scene collection
        release_sceneitem()
    end
end

local OVERRIDE_PROPS = {
    "monitor_override_x", "monitor_override_y", "monitor_override_w", "monitor_override_h",
    "monitor_override_sx", "monitor_override_sy", "monitor_override_dw", "monitor_override_dh"
}

function on_settings_modified(props, prop, settings)
    local name = obs.obs_property_name(prop)

    if name == "use_monitor_override" then
        local visible = obs.obs_data_get_bool(settings, "use_monitor_override")
        for _, p in ipairs(OVERRIDE_PROPS) do
            obs.obs_property_set_visible(obs.obs_properties_get(props, p), visible)
        end
        return true
    elseif name == "click_zoom" then
        obs.obs_property_set_visible(obs.obs_properties_get(props, "auto_zoom_out_delay"),
            obs.obs_data_get_bool(settings, "click_zoom"))
        return true
    elseif name == "allow_all_sources" then
        allow_all_sources = obs.obs_data_get_bool(settings, "allow_all_sources")
        populate_zoom_sources(obs.obs_properties_get(props, "source"))
        return true
    elseif name == "debug_logs" then
        if obs.obs_data_get_bool(settings, "debug_logs") then
            debug_logs = true
            log_current_settings()
        end
    end

    return false
end

---
-- Write the current settings into the log for debugging and user issue reports
function log_current_settings()
    local settings = {
        zoom_value = zoom_value,
        zoom_speed = zoom_speed,
        zoom_step = zoom_step,
        use_click_zoom = use_click_zoom,
        auto_zoom_out_delay = auto_zoom_out_delay,
        scale_filter_zoomed = scale_filter_zoomed,
        sharpen_strength = sharpen_strength,
        use_auto_follow_mouse = use_auto_follow_mouse,
        use_follow_outside_bounds = use_follow_outside_bounds,
        follow_speed = follow_speed,
        follow_border = follow_border,
        follow_safezone_sensitivity = follow_safezone_sensitivity,
        use_follow_auto_lock = use_follow_auto_lock,
        use_monitor_override = use_monitor_override,
        monitor_override_x = monitor_override_x,
        monitor_override_y = monitor_override_y,
        monitor_override_w = monitor_override_w,
        monitor_override_h = monitor_override_h,
        monitor_override_sx = monitor_override_sx,
        monitor_override_sy = monitor_override_sy,
        monitor_override_dw = monitor_override_dw,
        monitor_override_dh = monitor_override_dh,
        debug_logs = debug_logs
    }

    log("Zoom to Mouse v" .. VERSION .. " | OBS " .. version .. " | " .. ffi.os)
    log("Current settings:")
    log(format_table(settings))
end

function on_print_help()
    local help = "\n----------------------------------------------------\n" ..
        "Help Information for OBS-Zoom-To-Mouse v" .. VERSION .. "\n" ..
        "https://github.com/nguyenquocanhz/zoom-to-mouse\n" ..
        "----------------------------------------------------\n" ..
        "This script will zoom the selected display-capture source to focus on the mouse\n\n" ..
        "Zoom Source: The display capture in the current scene to use for zooming\n" ..
        "Zoom Factor: How much to zoom in by\n" ..
        "Zoom Step: How much the 'Zoom in more/less' hotkeys change the zoom factor\n" ..
        "Zoom Speed: The speed of the zoom in/out animation (frame-rate independent)\n" ..
        "Scale filter while zoomed: Lanczos/Bicubic keep the zoomed image sharper than bilinear\n" ..
        "Sharpen while zoomed: Strength of a Sharpen filter that fades in with the zoom (0 = off)\n" ..
        "Auto zoom on click: Left click inside the source zooms in automatically\n" ..
        "Auto zoom out after: Seconds without mouse activity before a click-zoom zooms out (0 = never)\n" ..
        "Auto follow mouse: True to track the cursor while you are zoomed in\n" ..
        "Follow outside bounds: True to track the cursor even when it is outside the bounds of the source\n" ..
        "Follow Speed: The speed at which the zoomed area will follow the mouse when tracking\n" ..
        "Follow Border: The %distance from the edge of the source that will re-enable mouse tracking\n" ..
        "Lock Sensitivity: How close the tracking needs to get before it locks into position\n" ..
        "Auto Lock on reverse direction: Automatically stop tracking if you reverse the direction of the mouse\n" ..
        "Allow any zoom source: Any source can be the Zoom Source - you MUST set manual source position for it\n" ..
        "Set manual source position: Override x/y, width/height and scale for the selected source\n" ..
        "Dùng màn hình đang có chuột: auto-fill the manual position from the monitor under the cursor\n" ..
        "More Info: Show this text in the script log\n" ..
        "Enable debug logging: Show additional debug information in the script log\n\n" ..
        "Hotkeys (Settings > Hotkeys): Toggle zoom to mouse, Toggle follow mouse during zoom,\n" ..
        "                              Zoom in more, Zoom in less\n"

    obs.script_log(obs.OBS_LOG_INFO, help)
end

function script_description()
    return "<b>Zoom to Mouse v" .. VERSION .. "</b><br>" ..
        "Zoom Display Capture theo con trỏ chuột. Gán phím ở <i>Settings → Hotkeys</i>, " ..
        "hoặc bật <i>Auto zoom on click</i> để tự zoom khi click (kiểu Screen Studio)."
end

function script_properties()
    local props = obs.obs_properties_create()

    local sources_list = obs.obs_properties_add_list(props, "source", "Zoom Source", obs.OBS_COMBO_TYPE_LIST,
        obs.OBS_COMBO_FORMAT_STRING)
    populate_zoom_sources(sources_list)

    local refresh_sources = obs.obs_properties_add_button(props, "refresh", "Refresh zoom sources",
        function()
            populate_zoom_sources(sources_list)
            monitor_info = get_monitor_info(source)
            return true
        end)
    obs.obs_property_set_long_description(refresh_sources,
        "Click to re-populate Zoom Sources dropdown with available sources")

    obs.obs_properties_add_float(props, "zoom_value", "Zoom Factor", 1, MAX_ZOOM, 0.1)
    local step = obs.obs_properties_add_float(props, "zoom_step", "Zoom Step (hotkey)", 0.1, 2, 0.1)
    obs.obs_property_set_long_description(step, "How much 'Zoom in more' / 'Zoom in less' hotkeys change the zoom")
    obs.obs_properties_add_float_slider(props, "zoom_speed", "Zoom Speed", 0.01, 1, 0.01)

    local click = obs.obs_properties_add_bool(props, "click_zoom", "Auto zoom on click ")
    obs.obs_property_set_long_description(click,
        "Left click inside the zoom source to zoom in automatically (Screen Studio style)")
    local delay = obs.obs_properties_add_float_slider(props, "auto_zoom_out_delay", "Auto zoom out after (s)", 0, 30, 0.5)
    obs.obs_property_set_long_description(delay,
        "Zoom back out after this many seconds without mouse activity (0 = never). Only for click zooms.")

    local scale = obs.obs_properties_add_list(props, "scale_filter", "Scale filter while zoomed",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_INT)
    obs.obs_property_list_add_int(scale, "Lanczos (sharpest)", SCALE_LANCZOS)
    obs.obs_property_list_add_int(scale, "Bicubic", SCALE_BICUBIC)
    obs.obs_property_list_add_int(scale, "Bilinear (OBS default, blurry)", SCALE_BILINEAR)
    obs.obs_property_list_add_int(scale, "Area", SCALE_AREA)
    obs.obs_property_list_add_int(scale, "Keep source setting", SCALE_KEEP)
    obs.obs_property_set_long_description(scale,
        "Upscaling the zoomed area with Lanczos keeps text much crisper than the default bilinear filter")
    local sharpen = obs.obs_properties_add_float_slider(props, "sharpen", "Sharpen while zoomed", 0, 1, 0.01)
    obs.obs_property_set_long_description(sharpen,
        "Strength of a Sharpen filter that fades in while zooming (0 = off). 0.1 - 0.2 is usually enough")

    local follow = obs.obs_properties_add_bool(props, "follow", "Auto follow mouse ")
    obs.obs_property_set_long_description(follow,
        "When enabled mouse tracking will auto-start when zoomed in without waiting for tracking toggle hotkey")

    local follow_outside_bounds = obs.obs_properties_add_bool(props, "follow_outside_bounds", "Follow outside bounds ")
    obs.obs_property_set_long_description(follow_outside_bounds,
        "When enabled the mouse will be tracked even when the cursor is outside the bounds of the zoom source")

    obs.obs_properties_add_float_slider(props, "follow_speed", "Follow Speed", 0.01, 1, 0.01)
    obs.obs_properties_add_int_slider(props, "follow_border", "Follow Border", 0, 50, 1)
    obs.obs_properties_add_int_slider(props, "follow_safezone_sensitivity", "Lock Sensitivity", 1, 20, 1)
    local follow_auto_lock = obs.obs_properties_add_bool(props, "follow_auto_lock", "Auto Lock on reverse direction ")
    obs.obs_property_set_long_description(follow_auto_lock,
        "When enabled moving the mouse to edge of the zoom source will begin tracking,\n" ..
        "but moving back towards the center will stop tracking similar to panning the camera in a RTS game")

    local allow_all = obs.obs_properties_add_bool(props, "allow_all_sources", "Allow any zoom source ")
    obs.obs_property_set_long_description(allow_all, "Enable to allow selecting any source as the Zoom Source\n" ..
        "You MUST set manual source position for non-display capture sources")

    local calib = obs.obs_properties_add_button(props, "calibrate", "Dùng màn hình đang có chuột (sau 3 giây)",
        function()
            obs.script_log(obs.OBS_LOG_INFO, "[zoom-to-mouse] Đưa chuột sang màn hình cần zoom trong 3 giây...")
            obs.timer_remove(on_calibrate_timer)
            obs.timer_add(on_calibrate_timer, CALIBRATE_DELAY_MS)
            return false
        end)
    obs.obs_property_set_long_description(calib,
        "Bấm rồi đưa chuột sang màn hình mà Zoom Source đang capture (vd màn rời). Sau 3 giây script tự lấy " ..
        "vị trí, kích thước, tỉ lệ của màn đó và điền vào 'Set manual source position'.")

    local override = obs.obs_properties_add_bool(props, "use_monitor_override", "Set manual source position ")
    obs.obs_property_set_long_description(override,
        "When enabled the specified size/position settings will be used for the zoom source instead of the auto-calculated ones")

    obs.obs_properties_add_int(props, "monitor_override_x", "X", -10000, 10000, 1)
    obs.obs_properties_add_int(props, "monitor_override_y", "Y", -10000, 10000, 1)
    obs.obs_properties_add_int(props, "monitor_override_w", "Width", 0, 10000, 1)
    obs.obs_properties_add_int(props, "monitor_override_h", "Height", 0, 10000, 1)
    local override_sx = obs.obs_properties_add_float(props, "monitor_override_sx", "Scale X ", 0, 100, 0.01)
    local override_sy = obs.obs_properties_add_float(props, "monitor_override_sy", "Scale Y ", 0, 100, 0.01)
    local override_dw = obs.obs_properties_add_int(props, "monitor_override_dw", "Monitor Width ", 0, 10000, 1)
    local override_dh = obs.obs_properties_add_int(props, "monitor_override_dh", "Monitor Height ", 0, 10000, 1)

    obs.obs_property_set_long_description(override_sx, "Usually 1 - unless you are using a scaled source")
    obs.obs_property_set_long_description(override_sy, "Usually 1 - unless you are using a scaled source")
    obs.obs_property_set_long_description(override_dw, "X resolution of your monitor")
    obs.obs_property_set_long_description(override_dh, "Y resolution of your monitor")

    local help = obs.obs_properties_add_button(props, "help_button", "More Info", on_print_help)
    obs.obs_property_set_long_description(help, "Click to show help information (via the script log)")

    local debug = obs.obs_properties_add_bool(props, "debug_logs", "Enable debug logging ")
    obs.obs_property_set_long_description(debug,
        "When enabled the script will output diagnostics messages to the script log (useful for debugging/github issues)")

    for _, p in ipairs(OVERRIDE_PROPS) do
        obs.obs_property_set_visible(obs.obs_properties_get(props, p), use_monitor_override)
    end
    obs.obs_property_set_visible(delay, use_click_zoom)

    obs.obs_property_set_modified_callback(override, on_settings_modified)
    obs.obs_property_set_modified_callback(click, on_settings_modified)
    obs.obs_property_set_modified_callback(allow_all, on_settings_modified)
    obs.obs_property_set_modified_callback(debug, on_settings_modified)

    return props
end

---
-- Read every setting into the script variables (shared by script_load and script_update)
function read_settings(settings)
    zoom_value = obs.obs_data_get_double(settings, "zoom_value")
    zoom_step = obs.obs_data_get_double(settings, "zoom_step")
    zoom_speed = obs.obs_data_get_double(settings, "zoom_speed")
    use_click_zoom = obs.obs_data_get_bool(settings, "click_zoom")
    auto_zoom_out_delay = obs.obs_data_get_double(settings, "auto_zoom_out_delay")
    scale_filter_zoomed = obs.obs_data_get_int(settings, "scale_filter")
    sharpen_strength = obs.obs_data_get_double(settings, "sharpen")
    use_auto_follow_mouse = obs.obs_data_get_bool(settings, "follow")
    use_follow_outside_bounds = obs.obs_data_get_bool(settings, "follow_outside_bounds")
    follow_speed = obs.obs_data_get_double(settings, "follow_speed")
    follow_border = obs.obs_data_get_int(settings, "follow_border")
    follow_safezone_sensitivity = obs.obs_data_get_int(settings, "follow_safezone_sensitivity")
    use_follow_auto_lock = obs.obs_data_get_bool(settings, "follow_auto_lock")
    allow_all_sources = obs.obs_data_get_bool(settings, "allow_all_sources")
    use_monitor_override = obs.obs_data_get_bool(settings, "use_monitor_override")
    monitor_override_x = obs.obs_data_get_int(settings, "monitor_override_x")
    monitor_override_y = obs.obs_data_get_int(settings, "monitor_override_y")
    monitor_override_w = obs.obs_data_get_int(settings, "monitor_override_w")
    monitor_override_h = obs.obs_data_get_int(settings, "monitor_override_h")
    monitor_override_sx = obs.obs_data_get_double(settings, "monitor_override_sx")
    monitor_override_sy = obs.obs_data_get_double(settings, "monitor_override_sy")
    monitor_override_dw = obs.obs_data_get_int(settings, "monitor_override_dw")
    monitor_override_dh = obs.obs_data_get_int(settings, "monitor_override_dh")
    debug_logs = obs.obs_data_get_bool(settings, "debug_logs")
end

local HOTKEYS = {
    { id = "toggle_zoom_hotkey", desc = "Toggle zoom to mouse", save = "obs_zoom_to_mouse.hotkey.zoom" },
    { id = "toggle_follow_hotkey", desc = "Toggle follow mouse during zoom", save = "obs_zoom_to_mouse.hotkey.follow" },
    { id = "zoom_more_hotkey", desc = "Zoom to mouse: zoom in more", save = "obs_zoom_to_mouse.hotkey.zoom_more" },
    { id = "zoom_less_hotkey", desc = "Zoom to mouse: zoom in less", save = "obs_zoom_to_mouse.hotkey.zoom_less" },
    { id = "zoom_calibrate_hotkey", desc = "Zoom to mouse: dùng màn hình đang có chuột",
      save = "obs_zoom_to_mouse.hotkey.calibrate" },
}

function script_load(settings)
    sceneitem_info_orig = nil

    script_settings = settings
    local callbacks = { on_toggle_zoom, on_toggle_follow, on_zoom_more, on_zoom_less, on_calibrate }
    local ids = {}
    for i, hk in ipairs(HOTKEYS) do
        ids[i] = obs.obs_hotkey_register_frontend(hk.id, hk.desc, callbacks[i])
        local save_array = obs.obs_data_get_array(settings, hk.save)
        obs.obs_hotkey_load(ids[i], save_array)
        obs.obs_data_array_release(save_array)
    end
    hotkey_zoom_id, hotkey_follow_id, hotkey_zoom_more_id, hotkey_zoom_less_id = ids[1], ids[2], ids[3], ids[4]
    hotkey_calibrate_id = ids[5]

    read_settings(settings)

    obs.obs_frontend_add_event_callback(on_frontend_event)

    if debug_logs then
        log_current_settings()
    end

    -- Add the transition_start handler to each transition (the global source_transition_start event never fires)
    local transitions = obs.obs_frontend_get_transitions()
    if transitions ~= nil then
        for _, s in ipairs(transitions) do
            log("Adding transition_start listener to " .. obs.obs_source_get_name(s))
            local handler = obs.obs_source_get_signal_handler(s)
            obs.signal_handler_connect(handler, "transition_start", on_transition_start)
        end
        obs.source_list_release(transitions)
    end

    if ffi.os == "Linux" and not x11_display then
        obs.script_log(obs.OBS_LOG_WARNING, "[zoom-to-mouse] Could not open the X11 display " ..
            "(Wayland session?). Mouse position will be incorrect - log in with an X11 session.")
    end
end

function script_unload()
    if is_click_poll_running then
        is_click_poll_running = false
        obs.timer_remove(on_click_poll)
    end
    obs.timer_remove(on_calibrate_timer)

    if major > 29.0 then -- 29.0 seems to crash if you do this, so we ignore it as the script is closing anyway
        local transitions = obs.obs_frontend_get_transitions()
        if transitions ~= nil then
            for _, s in ipairs(transitions) do
                local handler = obs.obs_source_get_signal_handler(s)
                obs.signal_handler_disconnect(handler, "transition_start", on_transition_start)
            end
            obs.source_list_release(transitions)
        end

        obs.obs_hotkey_unregister(on_toggle_zoom)
        obs.obs_hotkey_unregister(on_toggle_follow)
        obs.obs_hotkey_unregister(on_zoom_more)
        obs.obs_hotkey_unregister(on_zoom_less)
        obs.obs_hotkey_unregister(on_calibrate)
        obs.obs_frontend_remove_event_callback(on_frontend_event)
        release_sceneitem()
    end

    if x11_lib ~= nil and x11_display ~= nil then
        x11_lib.XCloseDisplay(x11_display)
        x11_display = nil
    end
end

function script_defaults(settings)
    obs.obs_data_set_default_double(settings, "zoom_value", 2)
    obs.obs_data_set_default_double(settings, "zoom_step", 0.5)
    obs.obs_data_set_default_double(settings, "zoom_speed", 0.06)
    obs.obs_data_set_default_bool(settings, "click_zoom", false)
    obs.obs_data_set_default_double(settings, "auto_zoom_out_delay", 3)
    obs.obs_data_set_default_int(settings, "scale_filter", SCALE_LANCZOS)
    obs.obs_data_set_default_double(settings, "sharpen", 0.1)
    obs.obs_data_set_default_bool(settings, "follow", true)
    obs.obs_data_set_default_bool(settings, "follow_outside_bounds", false)
    obs.obs_data_set_default_double(settings, "follow_speed", 0.25)
    obs.obs_data_set_default_int(settings, "follow_border", 8)
    obs.obs_data_set_default_int(settings, "follow_safezone_sensitivity", 4)
    obs.obs_data_set_default_bool(settings, "follow_auto_lock", false)
    obs.obs_data_set_default_bool(settings, "allow_all_sources", false)
    obs.obs_data_set_default_bool(settings, "use_monitor_override", false)
    obs.obs_data_set_default_int(settings, "monitor_override_x", 0)
    obs.obs_data_set_default_int(settings, "monitor_override_y", 0)
    obs.obs_data_set_default_int(settings, "monitor_override_w", 1920)
    obs.obs_data_set_default_int(settings, "monitor_override_h", 1080)
    obs.obs_data_set_default_double(settings, "monitor_override_sx", 1)
    obs.obs_data_set_default_double(settings, "monitor_override_sy", 1)
    obs.obs_data_set_default_int(settings, "monitor_override_dw", 1920)
    obs.obs_data_set_default_int(settings, "monitor_override_dh", 1080)
    obs.obs_data_set_default_bool(settings, "debug_logs", false)
end

function script_save(settings)
    local ids = { hotkey_zoom_id, hotkey_follow_id, hotkey_zoom_more_id, hotkey_zoom_less_id, hotkey_calibrate_id }
    for i, hk in ipairs(HOTKEYS) do
        if ids[i] ~= nil then
            local save_array = obs.obs_hotkey_save(ids[i])
            obs.obs_data_set_array(settings, hk.save, save_array)
            obs.obs_data_array_release(save_array)
        end
    end
end

function script_update(settings)
    local old_source_name = source_name
    local old_override = {
        use_monitor_override, monitor_override_x, monitor_override_y, monitor_override_w, monitor_override_h,
        monitor_override_sx, monitor_override_sy, monitor_override_dw, monitor_override_dh
    }

    source_name = obs.obs_data_get_string(settings, "source")
    read_settings(settings)

    -- Only do the expensive refresh if the user selected a new source
    if source_name ~= old_source_name then
        refresh_sceneitem(true)
    end

    local new_override = {
        use_monitor_override, monitor_override_x, monitor_override_y, monitor_override_w, monitor_override_h,
        monitor_override_sx, monitor_override_sy, monitor_override_dw, monitor_override_dh
    }
    local override_changed = false
    for i = 1, #new_override do
        if new_override[i] ~= old_override[i] then
            override_changed = true
            break
        end
    end

    if source_name ~= old_source_name or override_changed then
        monitor_info = get_monitor_info(source)
    end

    update_click_poll()
end

function populate_zoom_sources(list)
    obs.obs_property_list_clear(list)

    local sources = obs.obs_enum_sources()
    if sources ~= nil then
        local dc_info = get_dc_info()
        obs.obs_property_list_add_string(list, "<None>", NONE_SOURCE)
        for _, s in ipairs(sources) do
            local source_type = obs.obs_source_get_id(s)
            if allow_all_sources or (dc_info ~= nil and source_type == dc_info.source_id) then
                local name = obs.obs_source_get_name(s)
                obs.obs_property_list_add_string(list, name, name)
            end
        end

        obs.source_list_release(sources)
    end
end
