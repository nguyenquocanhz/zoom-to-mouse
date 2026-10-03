--[[
    Cartoon Face — v1.0.0
    Biến mặt / camera thành hoạt hình, bật tắt bằng một phím.

    Hai cách, chọn trong cài đặt script:
      1. Filter hoạt hình : shader GPU (cel-shading) — viền đen, màu phẳng, da mịn.
                            Áp cả khung hình hoặc chỉ vùng mặt (hình elip, viền mờ).
      2. Thay bằng avatar : ẩn webcam, hiện ảnh/GIF/app VTuber (VTube Studio, Veadotube...)
                            ở mọi scene có webcam.

    Filter cũng dùng độc lập được: chuột phải source → Filters → + → "Cartoon Face (Hoạt hình)".

    Lua không chạy được AI nhận diện khuôn mặt. Muốn vùng hoạt hình bám theo mặt khi bạn di chuyển,
    dùng thêm plugin "Face Tracker" (norihiro/obs-face-tracker) để giữ mặt ở giữa khung,
    hoặc dùng chế độ avatar với một app VTuber.

    Author : nguyenquocanhz — License: MIT
]]--

local obs = obslua
local bit = require("bit")

local VERSION = "1.0.0"
local FILTER_ID = "algen_cartoon_face"
local FILTER_NAME = "Cartoon Face"
local NONE = "<none>"

------------------------------------------------------------------------------
-- Shader (OBS effect language, HLSL-like; OBS converts it to GLSL on macOS/Linux)

local EFFECT = [[
uniform float4x4 ViewProj;
uniform texture2d image;

uniform float2 texel;
uniform float levels;
uniform float edge_strength;
uniform float edge_threshold;
uniform float edge_width;
uniform float saturation;
uniform float smoothness;
uniform float intensity;
uniform float use_mask;
uniform float2 mask_center;
uniform float2 mask_radius;
uniform float mask_feather;
uniform float4 line_color;

sampler_state def_sampler {
    Filter   = Linear;
    AddressU = Clamp;
    AddressV = Clamp;
};

struct VertData {
    float4 pos : POSITION;
    float2 uv  : TEXCOORD0;
};

VertData VSDefault(VertData v_in)
{
    VertData vert_out;
    vert_out.pos = mul(float4(v_in.pos.xyz, 1.0), ViewProj);
    vert_out.uv  = v_in.uv;
    return vert_out;
}

float luma(float3 c)
{
    return dot(c, float3(0.299, 0.587, 0.114));
}

float lum_at(float2 uv)
{
    return luma(image.Sample(def_sampler, uv).rgb);
}

// One tap of a cheap bilateral blur: neighbours with a similar colour weigh more,
// so skin gets smooth while edges (eyes, mouth, hair) stay sharp.
float4 btap(float2 uv, float3 center)
{
    float3 c = image.Sample(def_sampler, uv).rgb;
    float d = distance(c, center);
    float w = exp(-d * d * 30.0);
    return float4(c * w, w);
}

float4 PSCartoon(VertData v_in) : TARGET
{
    float2 uv = v_in.uv;
    float4 orig = image.Sample(def_sampler, uv);

    // 1. Smooth (two rings of 8 taps)
    float2 o = texel * smoothness;
    float4 acc = float4(orig.rgb, 1.0);
    acc += btap(uv + float2(-o.x, -o.y), orig.rgb);
    acc += btap(uv + float2( 0.0, -o.y), orig.rgb);
    acc += btap(uv + float2( o.x, -o.y), orig.rgb);
    acc += btap(uv + float2(-o.x,  0.0), orig.rgb);
    acc += btap(uv + float2( o.x,  0.0), orig.rgb);
    acc += btap(uv + float2(-o.x,  o.y), orig.rgb);
    acc += btap(uv + float2( 0.0,  o.y), orig.rgb);
    acc += btap(uv + float2( o.x,  o.y), orig.rgb);
    float2 o2 = o * 2.0;
    acc += btap(uv + float2(-o2.x, -o2.y), orig.rgb);
    acc += btap(uv + float2(  0.0, -o2.y), orig.rgb);
    acc += btap(uv + float2( o2.x, -o2.y), orig.rgb);
    acc += btap(uv + float2(-o2.x,   0.0), orig.rgb);
    acc += btap(uv + float2( o2.x,   0.0), orig.rgb);
    acc += btap(uv + float2(-o2.x,  o2.y), orig.rgb);
    acc += btap(uv + float2(  0.0,  o2.y), orig.rgb);
    acc += btap(uv + float2( o2.x,  o2.y), orig.rgb);
    float3 col = acc.rgb / acc.a;

    // 2. Ink lines: difference of Gaussians on brightness. A line is drawn where a pixel is
    //    darker than its surroundings (eyes, brows, lips, hair, silhouettes). Unlike Sobel it
    //    ignores fine skin texture, so faces stay clean.
    float2 e = texel * edge_width;
    float g1 = lum_at(uv) * 0.4
        + (lum_at(uv + float2(e.x, 0.0)) + lum_at(uv - float2(e.x, 0.0))
         + lum_at(uv + float2(0.0, e.y)) + lum_at(uv - float2(0.0, e.y))) * 0.15;
    float2 f = e * 2.5;
    float g2 = (lum_at(uv + float2(-f.x, -f.y)) + lum_at(uv + float2(0.0, -f.y))
              + lum_at(uv + float2( f.x, -f.y)) + lum_at(uv + float2(-f.x, 0.0))
              + lum_at(uv + float2( f.x,  0.0)) + lum_at(uv + float2(-f.x, f.y))
              + lum_at(uv + float2( 0.0,  f.y)) + lum_at(uv + float2( f.x, f.y))) * 0.125;
    float t = edge_threshold * 0.25;
    float edge = smoothstep(t, t + 0.04, g2 - g1) * edge_strength;

    // 3. Flat colour bands with a soft step between them (keeps the hue, avoids blotchy skin)
    float l = luma(col);
    float x = l * levels;
    float q = (floor(x) + smoothstep(0.3, 0.7, frac(x))) / levels;
    col = saturate(col * (q / max(l, 0.0001)));

    // 4. Punchier colours
    float g = luma(col);
    col = saturate(lerp(float3(g, g, g), col, saturation));

    // 5. Ink
    col = lerp(col, line_color.rgb, saturate(edge));

    // 6. Optional face-only ellipse with a soft edge
    float m = 1.0;
    if (use_mask > 0.5) {
        float d = length((uv - mask_center) / max(mask_radius, float2(0.001, 0.001)));
        m = 1.0 - smoothstep(1.0 - mask_feather, 1.0, d);
    }

    return float4(lerp(orig.rgb, col, m * intensity), orig.a);
}

technique Draw
{
    pass
    {
        vertex_shader = VSDefault(v_in);
        pixel_shader  = PSCartoon(v_in);
    }
}
]]

------------------------------------------------------------------------------
-- Presets

local PRESETS = {
    anime = { levels = 6, edge_strength = 1.0, edge_threshold = 0.22, edge_width = 1.0, saturation = 1.35, smoothness = 1.6 },
    comic = { levels = 4, edge_strength = 1.0, edge_threshold = 0.12, edge_width = 1.5, saturation = 1.6, smoothness = 1.2 },
    soft  = { levels = 9, edge_strength = 0.6, edge_threshold = 0.3, edge_width = 1.0, saturation = 1.15, smoothness = 2.5 },
    sketch = { levels = 3, edge_strength = 1.0, edge_threshold = 0.08, edge_width = 1.2, saturation = 0.2, smoothness = 1.0 },
}

local PARAMS = {
    "levels", "edge_strength", "edge_threshold", "edge_width", "saturation", "smoothness", "intensity",
    "use_mask", "mask_feather",
}

------------------------------------------------------------------------------
-- Filter

local filter = {}
filter.id = FILTER_ID
filter.type = obs.OBS_SOURCE_TYPE_FILTER
filter.output_flags = obs.OBS_SOURCE_VIDEO

filter.get_name = function()
    return "Cartoon Face (Hoạt hình)"
end

filter.create = function(settings, source)
    local data = {
        source = source,
        width = 0,
        height = 0,
        values = {},
        texel = obs.vec2(),
        center = obs.vec2(),
        radius = obs.vec2(),
        line = obs.vec4(),
        params = {},
    }

    obs.obs_enter_graphics()
    data.effect = obs.gs_effect_create(EFFECT, "cartoon_face.effect", nil)
    if data.effect ~= nil then
        for _, name in ipairs(PARAMS) do
            data.params[name] = obs.gs_effect_get_param_by_name(data.effect, name)
        end
        data.params.texel = obs.gs_effect_get_param_by_name(data.effect, "texel")
        data.params.mask_center = obs.gs_effect_get_param_by_name(data.effect, "mask_center")
        data.params.mask_radius = obs.gs_effect_get_param_by_name(data.effect, "mask_radius")
        data.params.line_color = obs.gs_effect_get_param_by_name(data.effect, "line_color")
    end
    obs.obs_leave_graphics()

    if data.effect == nil then
        obs.script_log(obs.OBS_LOG_ERROR, "[cartoon] Không biên dịch được shader (xem log OBS để biết dòng lỗi)")
        return nil
    end

    filter.update(data, settings)
    return data
end

filter.destroy = function(data)
    if data.effect ~= nil then
        obs.obs_enter_graphics()
        obs.gs_effect_destroy(data.effect)
        obs.obs_leave_graphics()
        data.effect = nil
    end
end

filter.get_width = function(data)
    return data.width
end

filter.get_height = function(data)
    return data.height
end

filter.video_tick = function(data, seconds)
    local target = obs.obs_filter_get_target(data.source)
    if target ~= nil then
        data.width = obs.obs_source_get_base_width(target)
        data.height = obs.obs_source_get_base_height(target)
    else
        data.width, data.height = 0, 0
    end
end

filter.video_render = function(data, effect)
    if data.width == 0 or data.height == 0 then
        obs.obs_source_skip_video_filter(data.source)
        return
    end

    if not obs.obs_source_process_filter_begin(data.source, obs.GS_RGBA, obs.OBS_NO_DIRECT_RENDERING) then
        return
    end

    data.texel.x = 1 / data.width
    data.texel.y = 1 / data.height
    obs.gs_effect_set_vec2(data.params.texel, data.texel)
    for _, name in ipairs(PARAMS) do
        obs.gs_effect_set_float(data.params[name], data.values[name])
    end
    obs.gs_effect_set_vec2(data.params.mask_center, data.center)
    obs.gs_effect_set_vec2(data.params.mask_radius, data.radius)
    obs.gs_effect_set_vec4(data.params.line_color, data.line)

    obs.obs_source_process_filter_end(data.source, data.effect, data.width, data.height)
end

filter.update = function(data, settings)
    local v = data.values
    v.levels = obs.obs_data_get_double(settings, "levels")
    v.edge_strength = obs.obs_data_get_double(settings, "edge_strength")
    v.edge_threshold = obs.obs_data_get_double(settings, "edge_threshold")
    v.edge_width = obs.obs_data_get_double(settings, "edge_width")
    v.saturation = obs.obs_data_get_double(settings, "saturation")
    v.smoothness = obs.obs_data_get_double(settings, "smoothness")
    v.intensity = obs.obs_data_get_double(settings, "intensity") / 100
    v.use_mask = obs.obs_data_get_bool(settings, "use_mask") and 1 or 0
    v.mask_feather = obs.obs_data_get_double(settings, "mask_feather") / 100

    data.center.x = obs.obs_data_get_double(settings, "mask_x") / 100
    data.center.y = obs.obs_data_get_double(settings, "mask_y") / 100
    data.radius.x = obs.obs_data_get_double(settings, "mask_w") / 200
    data.radius.y = obs.obs_data_get_double(settings, "mask_h") / 200

    -- OBS stores colours as 0xAABBGGRR
    local c = obs.obs_data_get_int(settings, "line_color")
    data.line.x = bit.band(c, 0xFF) / 255
    data.line.y = bit.band(bit.rshift(c, 8), 0xFF) / 255
    data.line.z = bit.band(bit.rshift(c, 16), 0xFF) / 255
    data.line.w = 1
end

function apply_preset(props, prop, settings)
    local p = PRESETS[obs.obs_data_get_string(settings, "preset")]
    if p == nil then
        return false
    end
    for k, val in pairs(p) do
        obs.obs_data_set_double(settings, k, val)
    end
    return true
end

local function set_mask_visible(props, visible)
    for _, name in ipairs({ "mask_x", "mask_y", "mask_w", "mask_h", "mask_feather" }) do
        obs.obs_property_set_visible(obs.obs_properties_get(props, name), visible)
    end
end

function on_mask_toggled(props, prop, settings)
    set_mask_visible(props, obs.obs_data_get_bool(settings, "use_mask"))
    return true
end

filter.get_properties = function(data)
    local props = obs.obs_properties_create()

    local preset = obs.obs_properties_add_list(props, "preset", "Kiểu",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(preset, "Anime", "anime")
    obs.obs_property_list_add_string(preset, "Truyện tranh (Comic)", "comic")
    obs.obs_property_list_add_string(preset, "Hoạt hình mềm", "soft")
    obs.obs_property_list_add_string(preset, "Phác thảo (Sketch)", "sketch")
    obs.obs_property_list_add_string(preset, "Tùy chỉnh", "custom")
    obs.obs_property_set_modified_callback(preset, apply_preset)

    obs.obs_properties_add_float_slider(props, "intensity", "Độ mạnh (%)", 0, 100, 1)
    obs.obs_properties_add_float_slider(props, "levels", "Số dải màu (ít = phẳng hơn)", 2, 16, 1)
    obs.obs_properties_add_float_slider(props, "smoothness", "Làm mịn da", 0, 4, 0.1)
    obs.obs_properties_add_float_slider(props, "saturation", "Độ rực màu", 0, 2, 0.05)
    obs.obs_properties_add_float_slider(props, "edge_strength", "Độ đậm viền", 0, 1, 0.05)
    obs.obs_properties_add_float_slider(props, "edge_threshold", "Ngưỡng viền (thấp = nhiều viền)", 0.02, 0.8, 0.01)
    obs.obs_properties_add_float_slider(props, "edge_width", "Độ dày viền", 0.5, 4, 0.1)
    obs.obs_properties_add_color(props, "line_color", "Màu viền")

    local mask = obs.obs_properties_add_bool(props, "use_mask", "Chỉ áp vào vùng mặt (elip)")
    obs.obs_property_set_modified_callback(mask, on_mask_toggled)
    obs.obs_properties_add_float_slider(props, "mask_x", "Tâm X (%)", 0, 100, 0.5)
    obs.obs_properties_add_float_slider(props, "mask_y", "Tâm Y (%)", 0, 100, 0.5)
    obs.obs_properties_add_float_slider(props, "mask_w", "Rộng (%)", 5, 100, 0.5)
    obs.obs_properties_add_float_slider(props, "mask_h", "Cao (%)", 5, 100, 0.5)
    obs.obs_properties_add_float_slider(props, "mask_feather", "Viền mờ (%)", 0, 100, 1)

    return props
end

filter.get_defaults = function(settings)
    obs.obs_data_set_default_string(settings, "preset", "anime")
    for k, val in pairs(PRESETS.anime) do
        obs.obs_data_set_default_double(settings, k, val)
    end
    obs.obs_data_set_default_double(settings, "intensity", 100)
    obs.obs_data_set_default_int(settings, "line_color", 0xFF1A1A1A)
    obs.obs_data_set_default_bool(settings, "use_mask", false)
    obs.obs_data_set_default_double(settings, "mask_x", 50)
    obs.obs_data_set_default_double(settings, "mask_y", 42)
    obs.obs_data_set_default_double(settings, "mask_w", 45)
    obs.obs_data_set_default_double(settings, "mask_h", 75)
    obs.obs_data_set_default_double(settings, "mask_feather", 35)
end

obs.obs_register_source(filter)

------------------------------------------------------------------------------
-- Script: one hotkey to switch the webcam between real and cartoon

local cfg = {
    webcam = NONE,
    mode = "filter",
    avatar = NONE,
}
local cartoon_on = false
local hotkey_id = nil

local function log(msg)
    obs.script_log(obs.OBS_LOG_INFO, "[cartoon] " .. msg)
end

---
-- Enable/disable every Cartoon Face filter on the webcam, adding one if needed
function set_filter_enabled(on)
    local cam = obs.obs_get_source_by_name(cfg.webcam)
    if cam == nil then
        log("Không tìm thấy webcam '" .. tostring(cfg.webcam) .. "'")
        return
    end

    local found = false
    local filters = obs.obs_source_enum_filters(cam)
    if filters ~= nil then
        for _, f in ipairs(filters) do
            if obs.obs_source_get_unversioned_id(f) == FILTER_ID then
                obs.obs_source_set_enabled(f, on)
                found = true
            end
        end
        obs.source_list_release(filters)
    end

    if not found and on then
        local f = obs.obs_source_create(FILTER_ID, FILTER_NAME, nil, nil)
        if f ~= nil then
            obs.obs_source_filter_add(cam, f)
            obs.obs_source_release(f)
            log("Đã thêm filter '" .. FILTER_NAME .. "' vào " .. cfg.webcam)
        end
    end
    obs.obs_source_release(cam)
end

local function find_item(scene, name)
    if obs.obs_scene_find_source_recursive then
        return obs.obs_scene_find_source_recursive(scene, name)
    end
    return obs.obs_scene_find_source(scene, name)
end

---
-- In every scene that contains the webcam: hide it and show the avatar (or the reverse)
function set_avatar_shown(on)
    local scenes = obs.obs_frontend_get_scenes()
    if scenes == nil then
        return
    end
    for _, scene_source in ipairs(scenes) do
        local scene = obs.obs_scene_from_source(scene_source)
        local cam_item = find_item(scene, cfg.webcam)
        if cam_item ~= nil then
            obs.obs_sceneitem_set_visible(cam_item, not on)
            local avatar_item = find_item(scene, cfg.avatar)
            if avatar_item ~= nil then
                obs.obs_sceneitem_set_visible(avatar_item, on)
            elseif on then
                log("Scene '" .. obs.obs_source_get_name(scene_source) .. "' có webcam nhưng chưa có avatar '" ..
                    cfg.avatar .. "' — thêm avatar vào scene đó (đặt cùng chỗ webcam)")
            end
        end
    end
    obs.source_list_release(scenes)
end

function apply(on)
    cartoon_on = on
    if cfg.webcam == NONE or cfg.webcam == "" then
        log("Chưa chọn webcam trong cài đặt script")
        return
    end
    if cfg.mode == "avatar" then
        set_filter_enabled(false)
        set_avatar_shown(on)
    else
        set_avatar_shown(false)
        set_filter_enabled(on)
    end
    log("Mặt hoạt hình: " .. (on and "BẬT" or "TẮT"))
end

function on_toggle(pressed)
    if pressed then
        apply(not cartoon_on)
    end
end

function script_description()
    return "<b>Cartoon Face v" .. VERSION .. "</b><br>" ..
        "Một phím biến webcam thành hoạt hình: filter cel-shading, hoặc thay hẳn bằng avatar / app VTuber.<br>" ..
        "Chỉnh kiểu hoạt hình trong <i>Filters</i> của webcam → <i>Cartoon Face (Hoạt hình)</i>."
end

function script_properties()
    local props = obs.obs_properties_create()

    local cam = obs.obs_properties_add_list(props, "webcam", "Webcam",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    local avatar = obs.obs_properties_add_list(props, "avatar", "Avatar (ảnh / GIF / app VTuber)",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(cam, "(chọn)", NONE)
    obs.obs_property_list_add_string(avatar, "(chọn)", NONE)

    local sources = obs.obs_enum_sources()
    if sources ~= nil then
        for _, s in ipairs(sources) do
            local flags = obs.obs_source_get_output_flags(s)
            if bit.band(flags, obs.OBS_SOURCE_VIDEO) ~= 0 then
                local name = obs.obs_source_get_name(s)
                obs.obs_property_list_add_string(cam, name, name)
                obs.obs_property_list_add_string(avatar, name, name)
            end
        end
        obs.source_list_release(sources)
    end

    local mode = obs.obs_properties_add_list(props, "mode", "Cách biến hình",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(mode, "Filter hoạt hình lên webcam", "filter")
    obs.obs_property_list_add_string(mode, "Thay webcam bằng avatar", "avatar")

    obs.obs_properties_add_button(props, "btn_toggle", "Bật / Tắt mặt hoạt hình", function()
        on_toggle(true)
        return false
    end)

    return props
end

function script_defaults(settings)
    obs.obs_data_set_default_string(settings, "webcam", NONE)
    obs.obs_data_set_default_string(settings, "avatar", NONE)
    obs.obs_data_set_default_string(settings, "mode", "filter")
end

function script_update(settings)
    local was_on = cartoon_on
    if was_on then
        apply(false) -- undo with the old webcam/mode before switching
    end
    cfg.webcam = obs.obs_data_get_string(settings, "webcam")
    cfg.avatar = obs.obs_data_get_string(settings, "avatar")
    cfg.mode = obs.obs_data_get_string(settings, "mode")
    if was_on then
        apply(true)
    end
end

function script_load(settings)
    hotkey_id = obs.obs_hotkey_register_frontend("cartoon_face_toggle", "Cartoon Face: Bật/Tắt", on_toggle)
    local arr = obs.obs_data_get_array(settings, "cartoon_face_toggle")
    obs.obs_hotkey_load(hotkey_id, arr)
    obs.obs_data_array_release(arr)
end

function script_save(settings)
    local arr = obs.obs_hotkey_save(hotkey_id)
    obs.obs_data_set_array(settings, "cartoon_face_toggle", arr)
    obs.obs_data_array_release(arr)
end
