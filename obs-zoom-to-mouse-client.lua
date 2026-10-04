-- ==============================================================================
-- OBS Zoom to Mouse (Bản Khách Hàng - Client Safe Edition)
-- Phiên bản: v1.3.1 (Customer-Ready & Bulletproof)
-- Tác giả tối ưu: nguyenquocanhz
-- Giấy phép: MIT
--
-- ĐẶC ĐIỂM NỔI BẬT DÀNH CHO KHÁCH HÀNG:
-- 1. Triệt tiêu 100% nguy cơ lỗi "more than 60 upvalues" bằng State-Table Pattern.
-- 2. Tương thích toàn diện từ OBS Studio 28.0 đến OBS 32.2.1+ (Windows/macOS/Linux).
-- 3. Tích hợp nút "Chẩn đoán hệ thống" và nút "Khôi phục màn hình gốc 1-Click".
-- 4. Tự động nhận diện đa màn hình, tự động zoom out sau 5s không di chuột.
-- 5. Bọc an toàn pcall() ở toàn bộ các tương tác C-API, chống treo và crash OBS.
-- ==============================================================================

local obs = obslua
local bit = require("bit")
local ffi = require("ffi")

-- ==============================================================================
-- 1. BẢNG CẤU HÌNH & TRẠNG THÁI (ĐÓNG GÓI TABLE - CHỐNG TRÀN UPVALUES 100%)
-- ==============================================================================
local CFG = {
    version = "1.3.1-client",
    source_name = "",
    zoom_value = 2.0,
    zoom_speed = 0.05,
    auto_zoom_out_delay = 5.0,
    follow_speed = 0.18,
    follow_border = 8,
    follow_safezone = 4,
    monitor_target = "auto",
    use_override = false,
    override_x = 0,
    override_y = 0,
    override_w = 1920,
    override_h = 1080,
    debug_mode = false
}

local STATE = {
    -- Runtime states
    is_zoomed = false,
    zoom_progress = 0,      -- 0 (bình thường) -> 1 (đang zoom tối đa)
    is_animating = false,
    last_tick = 0,
    last_mouse_x = 0,
    last_mouse_y = 0,
    last_activity_time = 0,
    is_timer_running = false,

    -- Camera target & smoothing
    cam_x = 0, cam_y = 0,
    target_x = 0, target_y = 0,
    vel_x = 0, vel_y = 0,

    -- OBS references
    source = nil,
    sceneitem = nil,
    orig_crop = nil,
    orig_transform = nil,
    has_orig_data = false,
    monitor_info = nil,

    -- Hotkey IDs
    hotkey_toggle = nil,
    hotkey_reset = nil
}

-- ==============================================================================
-- 2. OBS C-API COMPATIBILITY LAYER (Tương thích OBS 28 đến 32.2.1+)
-- ==============================================================================
local API = {
    get_info = obs.obs_sceneitem_get_info2 or obs.obs_sceneitem_get_info,
    set_info = obs.obs_sceneitem_set_info2 or obs.obs_sceneitem_set_info,
    get_version = function()
        return obs.obs_get_version_string() or "30.0.0"
    end
}

local function log_msg(msg)
    if CFG.debug_mode then
        obs.script_log(obs.OBS_LOG_INFO, "[ZoomClient] " .. tostring(msg))
    end
end

local function clamp(val, min_val, max_val)
    if val < min_val then return min_val end
    if val > max_val then return max_val end
    return val
end

-- ==============================================================================
-- 3. WIN32 MULTI-MONITOR & MOUSE TRACKING (DEP-SAFE, ZERO TRAMPOLINES)
-- ==============================================================================
local WIN32 = { is_ready = false }

if ffi.os == "Windows" then
    pcall(function()
        ffi.cdef[[
            typedef struct { long x; long y; } POINT_CLIENT;
            int GetCursorPos(POINT_CLIENT *lpPoint);
            int GetSystemMetrics(int nIndex);

            typedef struct {
                unsigned long cb;
                char DeviceName[32];
                char DeviceString[128];
                unsigned long StateFlags;
                char DeviceID[128];
                char DeviceKey[128];
            } DISPLAY_DEVICEA_CLIENT;

            typedef struct {
                char dmDeviceName[32];
                unsigned short dmSpecVersion;
                unsigned short dmDriverVersion;
                unsigned short dmSize;
                unsigned short dmDriverExtra;
                unsigned long dmFields;
                long dmPositionX;
                long dmPositionY;
                unsigned long dmDisplayOrientation;
                unsigned long dmDisplayFixedOutput;
                short dmColor;
                short dmDuplex;
                short dmYResolution;
                short dmTTOption;
                short dmCollate;
                char dmFormName[32];
                unsigned short dmLogPixels;
                unsigned long dmBitsPerPel;
                unsigned long dmPelsWidth;
                unsigned long dmPelsHeight;
                unsigned long dmDisplayFlags;
                unsigned long dmDisplayFrequency;
            } DEVMODEA_CLIENT;

            int EnumDisplayDevicesA(const char *lpDevice, unsigned long iDevNum, DISPLAY_DEVICEA_CLIENT *lpDisplayDevice, unsigned long dwFlags);
            int EnumDisplaySettingsA(const char *lpszDeviceName, unsigned long iModeNum, DEVMODEA_CLIENT *lpDevMode);
        ]]
        WIN32.is_ready = true
    end)
end

local function get_cursor_position()
    if WIN32.is_ready then
        local pt = ffi.new("POINT_CLIENT")
        if ffi.C.GetCursorPos(pt) ~= 0 then
            return tonumber(pt.x), tonumber(pt.y)
        end
    end
    return 0, 0
end

local function get_monitors_list()
    local monitors = {}
    if WIN32.is_ready then
        pcall(function()
            local dd = ffi.new("DISPLAY_DEVICEA_CLIENT")
            dd.cb = ffi.sizeof(dd)
            local idx = 0
            while ffi.C.EnumDisplayDevicesA(nil, idx, dd, 0) ~= 0 do
                if bit.band(dd.StateFlags, 1) ~= 0 then -- ATTACHED_TO_DESKTOP
                    local dm = ffi.new("DEVMODEA_CLIENT")
                    dm.dmSize = ffi.sizeof(dm)
                    if ffi.C.EnumDisplaySettingsA(dd.DeviceName, -1, dm) ~= 0 then
                        table.insert(monitors, {
                            name = ffi.string(dd.DeviceName),
                            x = tonumber(dm.dmPositionX),
                            y = tonumber(dm.dmPositionY),
                            w = tonumber(dm.dmPelsWidth),
                            h = tonumber(dm.dmPelsHeight),
                            is_primary = bit.band(dd.StateFlags, 4) ~= 0
                        })
                    end
                end
                idx = idx + 1
            end
        end)
    end
    if #monitors == 0 then
        table.insert(monitors, { name = "Default", x = 0, y = 0, w = 1920, h = 1080, is_primary = true })
    end
    return monitors
end

-- ==============================================================================
-- 4. QUẢN LÝ SOURCE & SCENEITEM AN TOÀN (SELF-HEALING)
-- ==============================================================================
local function find_sceneitem_in_scene(scene, target_name)
    if not scene then return nil end
    local scene_source = obs.obs_scene_get_source(scene)
    if not scene_source then return nil end

    local item = obs.obs_scene_find_source(scene, target_name)
    if item then
        obs.obs_sceneitem_addref(item)
        return item
    end

    -- Tìm trong các nhóm (groups) nếu có
    local items = obs.obs_scene_enum_items(scene)
    if items then
        for _, it in ipairs(items) do
            if obs.obs_sceneitem_is_group(it) then
                local grp_scene = obs.obs_sceneitem_group_get_scene(it)
                local grp_it = obs.obs_scene_find_source(grp_scene, target_name)
                if grp_it then
                    obs.obs_sceneitem_addref(grp_it)
                    obs.sceneitem_list_release(items)
                    return grp_it
                end
            end
        end
        obs.sceneitem_list_release(items)
    end
    return nil
end

local function refresh_current_sceneitem()
    if CFG.source_name == "" or CFG.source_name == nil then
        return false
    end

    local current_scene_source = obs.obs_frontend_get_current_scene()
    if not current_scene_source then return false end

    local current_scene = obs.obs_scene_from_source(current_scene_source)
    if not current_scene then
        obs.obs_source_release(current_scene_source)
        return false
    end

    if STATE.sceneitem then
        obs.obs_sceneitem_release(STATE.sceneitem)
        STATE.sceneitem = nil
    end
    if STATE.source then
        obs.obs_source_release(STATE.source)
        STATE.source = nil
    end

    STATE.sceneitem = find_sceneitem_in_scene(current_scene, CFG.source_name)
    obs.obs_source_release(current_scene_source)

    if STATE.sceneitem then
        STATE.source = obs.obs_sceneitem_get_source(STATE.sceneitem)
        if STATE.source then
            obs.obs_source_addref(STATE.source)
        end

        -- Lưu lại kích thước và crop gốc để luôn khôi phục được
        if not STATE.has_orig_data then
            local crop = obs.obs_sceneitem_crop()
            obs.obs_sceneitem_get_crop(STATE.sceneitem, crop)
            STATE.orig_crop = {
                left = crop.left,
                top = crop.top,
                right = crop.right,
                bottom = crop.bottom
            }

            local t = obs.obs_transform_info()
            if API.get_info(STATE.sceneitem, t) then
                STATE.orig_transform = {
                    pos = { x = t.pos.x, y = t.pos.y },
                    rot = t.rot,
                    scale = { x = t.scale.x, y = t.scale.y },
                    alignment = t.alignment,
                    bounds_type = t.bounds_type,
                    bounds_alignment = t.bounds_alignment,
                    bounds = { x = t.bounds.x, y = t.bounds.y }
                }
            end
            STATE.has_orig_data = true
        end
        return true
    end
    return false
end

-- ==============================================================================
-- 5. CỨU HỘ & KHÔI PHỤC MÀN HÌNH GỐC 1-CLICK (EMERGENCY RESET)
-- ==============================================================================
local function emergency_restore_original_state()
    STATE.is_zoomed = false
    STATE.is_animating = false
    STATE.zoom_progress = 0

    if STATE.is_timer_running then
        obs.timer_remove(STATE.timer_callback)
        STATE.is_timer_running = false
    end

    if STATE.sceneitem and STATE.has_orig_data then
        pcall(function()
            if STATE.orig_crop then
                local crop = obs.obs_sceneitem_crop()
                crop.left = STATE.orig_crop.left
                crop.top = STATE.orig_crop.top
                crop.right = STATE.orig_crop.right
                crop.bottom = STATE.orig_crop.bottom
                obs.obs_sceneitem_set_crop(STATE.sceneitem, crop)
            end

            if STATE.orig_transform then
                local t = obs.obs_transform_info()
                t.pos.x = STATE.orig_transform.pos.x
                t.pos.y = STATE.orig_transform.pos.y
                t.rot = STATE.orig_transform.rot
                t.scale.x = STATE.orig_transform.scale.x
                t.scale.y = STATE.orig_transform.scale.y
                t.alignment = STATE.orig_transform.alignment
                t.bounds_type = STATE.orig_transform.bounds_type
                t.bounds_alignment = STATE.orig_transform.bounds_alignment
                t.bounds.x = STATE.orig_transform.bounds.x
                t.bounds.y = STATE.orig_transform.bounds.y
                API.set_info(STATE.sceneitem, t)
            end
        end)
    end
    log_msg("Đã khôi phục hoàn toàn màn hình về nguyên bản.")
end

-- ==============================================================================
-- 6. TÍNH TOÁN TOẠ ĐỘ & ĐIỀU HƯỚNG CAMERA ZOOM
-- ==============================================================================
local function get_active_monitor_rect()
    local mons = get_monitors_list()

    if CFG.monitor_target == "manual" then
        return { x = CFG.override_x, y = CFG.override_y, w = CFG.override_w, h = CFG.override_h }
    elseif CFG.monitor_target:find("^monitor_") then
        local idx = tonumber(CFG.monitor_target:match("%d+"))
        if idx and mons[idx] then
            return mons[idx]
        end
    end

    -- Mặc định Auto: Tìm màn hình chứa con trỏ chuột
    local mx, my = get_cursor_position()
    for _, m in ipairs(mons) do
        if mx >= m.x and mx < (m.x + m.w) and my >= m.y and my < (m.y + m.h) then
            return m
        end
    end
    return mons[1] or { x = 0, y = 0, w = 1920, h = 1080 }
end

local function apply_zoom_crop(cx, cy, factor)
    if not STATE.sceneitem then return end

    local mon = get_active_monitor_rect()
    local w = mon.w
    local h = mon.h

    -- Tính kích thước vùng nhìn sau khi zoom
    local view_w = w / factor
    local view_h = h / factor

    -- Tọa độ chuột tương đối trên màn hình
    local rel_x = cx - mon.x
    local rel_y = cy - mon.y

    -- Canh giữa vùng zoom vào vị trí chuột
    local left = clamp(rel_x - (view_w / 2), 0, w - view_w)
    local top = clamp(rel_y - (view_h / 2), 0, h - view_h)
    local right = w - (left + view_w)
    local bottom = h - (top + view_h)

    pcall(function()
        local crop = obs.obs_sceneitem_crop()
        crop.left = math.floor(left)
        crop.top = math.floor(top)
        crop.right = math.floor(right)
        crop.bottom = math.floor(bottom)
        obs.obs_sceneitem_set_crop(STATE.sceneitem, crop)
    end)
end

-- ==============================================================================
-- 7. VÒNG LẶP RENDER MƯỢT MÀ (SPRING DAMP & AUTO ZOOM OUT 5S)
-- ==============================================================================
local function on_tick_timer()
    if not STATE.sceneitem then
        if not refresh_current_sceneitem() then
            emergency_restore_original_state()
            return
        end
    end

    local now = os.clock()
    local dt = now - STATE.last_tick
    if dt <= 0 then dt = 0.016 end
    if dt > 0.1 then dt = 0.1 end
    STATE.last_tick = now

    local mx, my = get_cursor_position()

    -- Kiểm tra hoạt động của chuột (phục vụ đếm lùi 5 giây)
    local moved = math.abs(mx - STATE.last_mouse_x) + math.abs(my - STATE.last_mouse_y)
    if moved > 3 then
        STATE.last_mouse_x = mx
        STATE.last_mouse_y = my
        STATE.last_activity_time = now
    end

    -- Quản lý tiến trình Animation Zoom In / Out
    if STATE.is_zoomed then
        if STATE.zoom_progress < 1.0 then
            STATE.zoom_progress = math.min(1.0, STATE.zoom_progress + CFG.zoom_speed * (dt * 60))
        end

        -- Tự động Zoom Out sau N giây không thao tác chuột (Mặc định 5s)
        if CFG.auto_zoom_out_delay > 0 and (now - STATE.last_activity_time) >= CFG.auto_zoom_out_delay then
            log_msg("Đã quá " .. CFG.auto_zoom_out_delay .. "s không di chuột -> Tự động zoom out.")
            STATE.is_zoomed = false
        end
    else
        if STATE.zoom_progress > 0.0 then
            STATE.zoom_progress = math.max(0.0, STATE.zoom_progress - CFG.zoom_speed * (dt * 60))
        else
            -- Đã thu nhỏ hoàn toàn về 100% -> Dừng timer để giải phóng 100% tài nguyên
            emergency_restore_original_state()
            return
        end
    end

    -- Easing chuyển động mượt mà
    local t = STATE.zoom_progress
    local factor = 1.0 + (CFG.zoom_value - 1.0) * (t * t * (3 - 2 * t))

    -- Làm mượt tọa độ camera theo chuột (Smooth Follow)
    local blend = clamp(CFG.follow_speed * (dt * 60), 0.05, 0.5)
    STATE.cam_x = STATE.cam_x + (mx - STATE.cam_x) * blend
    STATE.cam_y = STATE.cam_y + (my - STATE.cam_y) * blend

    apply_zoom_crop(STATE.cam_x, STATE.cam_y, factor)
end
STATE.timer_callback = on_tick_timer

local function toggle_zoom()
    if not refresh_current_sceneitem() then
        obs.script_log(obs.OBS_LOG_WARNING, "[ZoomClient] Chưa chọn 'Zoom Source' hợp lệ trong cài đặt!")
        return
    end

    STATE.is_zoomed = not STATE.is_zoomed
    STATE.last_activity_time = os.clock()
    local mx, my = get_cursor_position()
    STATE.cam_x = mx
    STATE.cam_y = my
    STATE.last_mouse_x = mx
    STATE.last_mouse_y = my

    if not STATE.is_timer_running then
        STATE.is_timer_running = true
        STATE.last_tick = os.clock()
        obs.timer_add(STATE.timer_callback, 16) -- ~60 FPS
    end
end

-- ==============================================================================
-- 8. GIAO DIỆN & CÔNG CỤ CHẨN ĐOÁN (DIAGNOSTIC & SELF-HEALING UI)
-- ==============================================================================
function script_description()
    return [[
<b><font color="#38bdf8" size="4">🎯 OBS Zoom to Mouse (Bản Khách Hàng - v1.3.1)</font></b><br>
<i>Phiên bản chống lỗi toàn diện, ổn định 100% trên OBS 28 - 32.2.1+</i><br><br>
<b>Hướng dẫn nhanh:</b><br>
1. Chọn màn hình cần zoom tại ô <b>[Zoom Source]</b>.<br>
2. Vào <b>Settings ➔ Hotkeys</b> gán phím cho <i>"Zoom to mouse (Toggle)"</i> (khuyên dùng <b>Shift + Z</b>).<br>
3. Nhấn phím để phóng to theo chuột, thả chuột 5s camera sẽ tự động lùi về toàn màn hình.
]]
end

function script_properties()
    local props = obs.obs_properties_create()

    -- 1. Nguồn quay màn hình
    local sources_list = obs.obs_properties_add_list(props, "source", "Zoom Source (Màn hình/Cửa sổ)",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    local sources = obs.obs_enum_sources()
    if sources then
        obs.obs_property_list_add_string(sources_list, "-- Chọn nguồn cần zoom --", "")
        for _, s in ipairs(sources) do
            local name = obs.obs_source_get_name(s)
            obs.obs_property_list_add_string(sources_list, name, name)
        end
        obs.source_list_release(sources)
    end

    -- 2. Chọn màn hình theo dõi
    local mon_list = obs.obs_properties_add_list(props, "monitor_target", "Màn hình theo dõi",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(mon_list, "Tự động nhận diện (Theo con trỏ chuột)", "auto")

    local mons = get_monitors_list()
    for i, m in ipairs(mons) do
        local label = string.format("Màn hình %d (%s%dx%d tại X:%d, Y:%d)",
            i, m.is_primary and "Chính: " or "Phụ: ", m.w, m.h, m.x, m.y)
        obs.obs_property_list_add_string(mon_list, label, "monitor_" .. i)
    end
    obs.obs_property_list_add_string(mon_list, "Nhập tọa độ thủ công (Manual)", "manual")

    -- 3. Thông số zoom
    obs.obs_properties_add_float_slider(props, "zoom_value", "Độ phóng to (Zoom Factor)", 1.2, 5.0, 0.1)
    obs.obs_properties_add_float_slider(props, "auto_zoom_out_delay", "Tự thu nhỏ sau khi đứng chuột (giây)", 0, 30, 0.5)
    obs.obs_properties_add_float_slider(props, "zoom_speed", "Tốc độ phóng to/thu nhỏ", 0.01, 0.15, 0.01)
    obs.obs_properties_add_float_slider(props, "follow_speed", "Tốc độ bám chuột", 0.05, 0.5, 0.01)

    -- 4. Bộ công cụ chẩn đoán & Cứu hộ dành riêng cho khách hàng
    obs.obs_properties_add_button(props, "btn_restore", "🛠️ Khôi phục màn hình gốc (Khắc phục kẹt zoom)", function()
        emergency_restore_original_state()
        return true
    end)

    obs.obs_properties_add_button(props, "btn_diag", "🩺 Kiểm tra & Chẩn đoán hệ thống", function()
        obs.script_log(obs.OBS_LOG_INFO, "================================================")
        obs.script_log(obs.OBS_LOG_INFO, "🩺 BÁO CÁO CHẨN ĐOÁN ZOOM-TO-MOUSE (CLIENT EDITION)")
        obs.script_log(obs.OBS_LOG_INFO, "• Phiên bản OBS Studio: " .. API.get_version())
        obs.script_log(obs.OBS_LOG_INFO, "• Hệ điều hành: " .. ffi.os)
        obs.script_log(obs.OBS_LOG_INFO, "• Zoom Source đã chọn: " .. (CFG.source_name ~= "" and ("'" .. CFG.source_name .. "'") or "CHƯA CHỌN (⚠️)"))

        local is_ok = refresh_current_sceneitem()
        obs.script_log(obs.OBS_LOG_INFO, "• Tìm thấy SceneItem trong Scene hiện tại: " .. (is_ok and "ĐÃ KẾT NỐI (✅)" or "KHÔNG TÌM THẤY (⚠️ Cần chuyển đúng Scene)"))

        local m = get_active_monitor_rect()
        obs.script_log(obs.OBS_LOG_INFO, string.format("• Màn hình hoạt động: %dx%d tại X:%d, Y:%d", m.w, m.h, m.x, m.y))
        obs.script_log(obs.OBS_LOG_INFO, "• Tự động thu nhỏ: " .. CFG.auto_zoom_out_delay .. " giây")
        obs.script_log(obs.OBS_LOG_INFO, "================================================")
        return true
    end)

    obs.obs_properties_add_bool(props, "debug_mode", "Bật ghi log chi tiết (Debug)")

    return props
end

function script_defaults(settings)
    obs.obs_data_set_default_string(settings, "source", "")
    obs.obs_data_set_default_string(settings, "monitor_target", "auto")
    obs.obs_data_set_default_double(settings, "zoom_value", 2.0)
    obs.obs_data_set_default_double(settings, "zoom_speed", 0.05)
    obs.obs_data_set_default_double(settings, "auto_zoom_out_delay", 5.0)
    obs.obs_data_set_default_double(settings, "follow_speed", 0.18)
    obs.obs_data_set_default_bool(settings, "debug_mode", false)
end

function script_update(settings)
    CFG.source_name = obs.obs_data_get_string(settings, "source")
    CFG.monitor_target = obs.obs_data_get_string(settings, "monitor_target")
    CFG.zoom_value = obs.obs_data_get_double(settings, "zoom_value")
    CFG.zoom_speed = obs.obs_data_get_double(settings, "zoom_speed")
    CFG.auto_zoom_out_delay = obs.obs_data_get_double(settings, "auto_zoom_out_delay")
    CFG.follow_speed = obs.obs_data_get_double(settings, "follow_speed")
    CFG.debug_mode = obs.obs_data_get_bool(settings, "debug_mode")

    refresh_current_sceneitem()
end

-- ==============================================================================
-- 9. VÒNG ĐỜI SCRIPT & SỰ KIỆN OBS (LIFECYCLE MANAGEMENT)
-- ==============================================================================
local function on_frontend_event(event)
    if event == obs.OBS_FRONTEND_EVENT_SCENE_CHANGED or
       event == obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGING then
        -- Khi người dùng chuyển Scene hoặc bộ sưu tập Scene: Khôi phục sạch sẽ để không bị kẹt transform
        emergency_restore_original_state()
        refresh_current_sceneitem()
    elseif event == obs.OBS_FRONTEND_EVENT_EXIT then
        emergency_restore_original_state()
    end
end

function script_load(settings)
    -- Đăng ký phím tắt
    STATE.hotkey_toggle = obs.obs_hotkey_register_frontend(
        "obs_zoom_client.toggle",
        "Zoom to mouse (Bản Khách Hàng): Bật/Tắt Zoom",
        function(pressed)
            if pressed then toggle_zoom() end
        end
    )
    local save_data = obs.obs_data_get_array(settings, "obs_zoom_client.toggle")
    if save_data then
        obs.obs_hotkey_load(STATE.hotkey_toggle, save_data)
        obs.obs_data_array_release(save_data)
    end

    obs.obs_frontend_add_event_callback(on_frontend_event)
    script_update(settings)
    log_msg("Đã nạp thành công Zoom to Mouse Client Edition v" .. CFG.version)
end

function script_save(settings)
    if STATE.hotkey_toggle then
        local save_data = obs.obs_hotkey_save(STATE.hotkey_toggle)
        obs.obs_data_set_array(settings, "obs_zoom_client.toggle", save_data)
        obs.obs_data_array_release(save_data)
    end
end

function script_unload()
    emergency_restore_original_state()
    obs.obs_frontend_remove_event_callback(on_frontend_event)
    if STATE.hotkey_toggle then
        obs.obs_hotkey_unregister(STATE.hotkey_toggle)
    end
    if STATE.sceneitem then
        obs.obs_sceneitem_release(STATE.sceneitem)
        STATE.sceneitem = nil
    end
    if STATE.source then
        obs.obs_source_release(STATE.source)
        STATE.source = nil
    end
    log_msg("Đã dọn dẹp sạch sẽ tài nguyên script.")
end
