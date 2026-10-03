--[[
    Face Mask — v1.0.0
    Đeo mặt nạ lên mặt trên webcam, bật/tắt và đổi kiểu bằng phím tắt.

    Mặt nạ vẽ bằng shader (không cần file ảnh):
      - Hacker  : mặt nạ trắng ria vểnh, má hồng (phong cách "Anonymous")
      - Kitsune : mặt nạ cáo Nhật Bản, tai nhọn, hoa văn đỏ
      - Neko    : tai mèo, má hồng "///", ria mèo — vẫn lộ mặt, kiểu filter dễ thương
      - Ảnh PNG : mặt nạ của riêng bạn (PNG nền trong suốt)
    Tùy chọn "Khoét lỗ mắt" cho Hacker/Kitsune để thấy mắt thật qua mặt nạ.

    Lua không chạy được AI dò mặt, nên mặt nạ nằm ở vị trí bạn đặt. Muốn mặt nạ bám theo mặt khi
    di chuyển, dùng plugin Face Tracker (norihiro/obs-face-tracker) để giữ mặt ở giữa khung.

    Author : nguyenquocanhz — License: MIT
]]--

local obs = obslua

local VERSION = "1.0.0"
local FILTER_ID = "algen_face_mask"
local FILTER_NAME = "Face Mask"
local NONE = "<none>"
local MASKS = { "hacker", "kitsune", "neko", "image" }
local MASK_INDEX = { hacker = 0, kitsune = 1, neko = 2, image = 3 }

local EFFECT = [==[
uniform float4x4 ViewProj;
uniform texture2d image;
uniform texture2d mask_img;

uniform float2 texel;
uniform float aspect;
uniform float2 center;
uniform float size;
uniform float rotation;
uniform float mode;
uniform float opacity;
uniform float eye_holes;
uniform float img_aspect;
uniform float blend_mode;
uniform float4 tint;

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

// ---- 2D signed distance helpers (negative = inside) ----
float sd_ellipse(float2 p, float2 r)
{
    float k0 = length(p / r);
    float k1 = length(p / (r * r));
    return k0 * (k0 - 1.0) / max(k1, 0.00001);
}

float sd_seg(float2 p, float2 a, float2 b, float ra, float rb)
{
    float2 pa = p - a;
    float2 ba = b - a;
    float h = saturate(dot(pa, ba) / dot(ba, ba));
    return length(pa - ba * h) - lerp(ra, rb, h);
}

float sd_tri(float2 p, float2 p0, float2 p1, float2 p2)
{
    float2 e0 = p1 - p0;
    float2 e1 = p2 - p1;
    float2 e2 = p0 - p2;
    float2 v0 = p - p0;
    float2 v1 = p - p1;
    float2 v2 = p - p2;
    float2 pq0 = v0 - e0 * saturate(dot(v0, e0) / dot(e0, e0));
    float2 pq1 = v1 - e1 * saturate(dot(v1, e1) / dot(e1, e1));
    float2 pq2 = v2 - e2 * saturate(dot(v2, e2) / dot(e2, e2));
    float s = sign(e0.x * e2.y - e0.y * e2.x);
    float2 d = min(min(float2(dot(pq0, pq0), s * (v0.x * e0.y - v0.y * e0.x)),
                       float2(dot(pq1, pq1), s * (v1.x * e1.y - v1.y * e1.x))),
                       float2(dot(pq2, pq2), s * (v2.x * e2.y - v2.y * e2.x)));
    return -sqrt(d.x) * sign(d.y);
}

float smin(float a, float b, float k)
{
    float h = saturate(0.5 + 0.5 * (b - a) / k);
    return lerp(b, a, h) - k * h * (1.0 - h);
}

float2 rot(float2 v, float a)
{
    float c = cos(a);
    float s = sin(a);
    return float2(c * v.x - s * v.y, s * v.x + c * v.y);
}

float lum(float2 uv)
{
    return dot(image.Sample(def_sampler, uv).rgb, float3(0.299, 0.587, 0.114));
}

// Coverage of a shape with an anti-aliased edge
float cover(float d, float aa)
{
    return 1.0 - smoothstep(-aa, aa, d);
}

// Paint `col` with coverage `a` over the mask built so far
float4 paint(float4 m, float3 col, float a)
{
    return float4(lerp(m.rgb, col, a), max(m.a, a));
}

// Cut a see-through hole (shows the real face underneath)
float4 hole(float4 m, float a)
{
    return float4(m.rgb, m.a * (1.0 - a));
}

// ---- Masks. p: face space, (0,0) = face centre, y down, |p.y| = 1 at forehead/chin ----

float4 mask_hacker(float2 p, float aa)
{
    float2 q = float2(abs(p.x), p.y); // mirrored: draw the right half, get both
    float4 m = float4(0.0, 0.0, 0.0, 0.0);

    float2 fc = p - float2(0.0, 0.03);
    float2 fr = float2(0.72, lerp(0.95, 1.05, step(0.0, fc.y)));
    float face_d = sd_ellipse(fc, fr);
    float shade = 1.0 - 0.28 * smoothstep(0.45, 1.0, length(fc / fr)) - 0.06 * saturate(p.y);
    m = paint(m, float3(0.97, 0.94, 0.88) * shade, cover(face_d, aa));
    m = paint(m, float3(0.35, 0.30, 0.26), cover(abs(face_d) - 0.012, aa) * 0.8);

    // rosy cheeks
    m = paint(m, float3(0.92, 0.42, 0.42), cover(sd_ellipse(q - float2(0.37, 0.24), float2(0.15, 0.09)), 0.07) * 0.6);

    // arched eyebrows, thick near the nose
    float brow_t = lerp(0.045, 0.012, saturate((q.x - 0.08) / 0.4));
    float brow = cover(abs(sd_ellipse(q - float2(0.31, -0.08), float2(0.25, 0.18))) - brow_t, aa);
    brow *= 1.0 - smoothstep(-0.16, -0.10, q.y);
    m = paint(m, float3(0.10, 0.08, 0.07), brow);

    // eyes
    float eye = cover(sd_ellipse(q - float2(0.30, -0.05), float2(0.16, 0.05)), aa);
    m = paint(m, float3(0.05, 0.04, 0.04), eye);
    m = hole(m, eye * eye_holes);

    // nose line
    m = paint(m, float3(0.55, 0.45, 0.40), cover(sd_seg(p, float2(0.0, 0.0), float2(0.04, 0.24), 0.007, 0.012), aa) * 0.7);

    // curled moustache
    float must = min(sd_seg(q, float2(0.0, 0.35), float2(0.21, 0.37), 0.052, 0.034),
                     sd_seg(q, float2(0.21, 0.37), float2(0.38, 0.23), 0.034, 0.008));
    m = paint(m, float3(0.08, 0.06, 0.05), cover(must, aa));

    // thin smile under the moustache
    float smile = cover(abs(sd_ellipse(p - float2(0.0, 0.34), float2(0.24, 0.13))) - 0.011, aa);
    smile *= smoothstep(0.40, 0.44, p.y);
    m = paint(m, float3(0.15, 0.10, 0.09), smile);

    // goatee
    m = paint(m, float3(0.08, 0.06, 0.05), cover(sd_seg(p, float2(0.0, 0.56), float2(0.0, 0.88), 0.045, 0.006), aa));
    return m;
}

float4 mask_kitsune(float2 p, float aa)
{
    float2 q = float2(abs(p.x), p.y);
    float4 m = float4(0.0, 0.0, 0.0, 0.0);
    float3 white = float3(0.98, 0.97, 0.95);
    float3 red = float3(0.86, 0.10, 0.17);

    // ears
    m = paint(m, white * 0.93, cover(sd_tri(q, float2(0.20, -0.55), float2(0.68, -0.42), float2(0.56, -1.20)), aa));
    m = paint(m, red, cover(sd_tri(q, float2(0.32, -0.60), float2(0.60, -0.52), float2(0.53, -1.00)), aa));

    // head + snout
    float head = smin(sd_ellipse(p - float2(0.0, -0.08), float2(0.72, 0.68)),
                      sd_ellipse(p - float2(0.0, 0.45), float2(0.33, 0.52)), 0.18);
    float shade = 1.0 - 0.22 * smoothstep(0.3, 0.9, length(p * float2(1.1, 0.8))) ;
    m = paint(m, white * shade, cover(head, aa));
    m = paint(m, float3(0.55, 0.50, 0.48), cover(abs(head) - 0.01, aa) * 0.6);

    // slanted eyes
    float eye = cover(sd_ellipse(rot(q - float2(0.30, -0.10), 0.38), float2(0.17, 0.042)), aa);
    m = paint(m, float3(0.03, 0.02, 0.02), eye);
    m = hole(m, eye * eye_holes);

    // red markings around the eyes
    m = paint(m, red, cover(sd_seg(q, float2(0.12, -0.24), float2(0.52, -0.36), 0.035, 0.004), aa));
    m = paint(m, red, cover(sd_seg(q, float2(0.20, 0.02), float2(0.50, -0.10), 0.022, 0.004), aa));

    // forehead flame
    float flame = min(sd_ellipse(p - float2(0.0, -0.40), float2(0.065, 0.065)),
                      sd_tri(p, float2(-0.06, -0.42), float2(0.06, -0.42), float2(0.0, -0.62)));
    m = paint(m, red, cover(flame, aa));

    // whisker dots, nose, mouth
    m = paint(m, red, cover(sd_ellipse(q - float2(0.18, 0.60), float2(0.024, 0.024)), aa));
    m = paint(m, red, cover(sd_ellipse(q - float2(0.25, 0.55), float2(0.024, 0.024)), aa));
    m = paint(m, red, cover(sd_ellipse(q - float2(0.23, 0.67), float2(0.024, 0.024)), aa));
    m = paint(m, float3(0.05, 0.04, 0.04), cover(sd_ellipse(p - float2(0.0, 0.88), float2(0.085, 0.05)), aa));
    float mouth = cover(abs(sd_ellipse(p - float2(0.0, 0.74), float2(0.13, 0.10))) - 0.01, aa);
    m = paint(m, red, mouth * smoothstep(0.80, 0.83, p.y));
    return m;
}

float4 mask_neko(float2 p, float aa)
{
    float2 q = float2(abs(p.x), p.y);
    float4 m = float4(0.0, 0.0, 0.0, 0.0);
    float3 ear = tint.rgb;
    float3 inner = float3(1.0, 0.62, 0.74);

    // cat ears on top of the head
    float outer_d = sd_tri(q, float2(0.22, -1.02), float2(0.74, -0.80), float2(0.68, -1.55));
    m = paint(m, ear, cover(outer_d, aa));
    m = paint(m, inner, cover(sd_tri(q, float2(0.34, -1.00), float2(0.66, -0.87), float2(0.63, -1.38)), aa));
    m = paint(m, ear * 0.55, cover(abs(outer_d) - 0.012, aa));

    // blush with "///" strokes
    float blush = cover(sd_ellipse(q - float2(0.40, 0.22), float2(0.15, 0.075)), 0.06);
    m = paint(m, float3(1.0, 0.45, 0.56), blush * 0.55);
    float strokes = min(min(sd_seg(q, float2(0.31, 0.26), float2(0.35, 0.18), 0.008, 0.008),
                            sd_seg(q, float2(0.38, 0.26), float2(0.42, 0.18), 0.008, 0.008)),
                            sd_seg(q, float2(0.45, 0.26), float2(0.49, 0.18), 0.008, 0.008));
    m = paint(m, float3(1.0, 0.95, 0.97), cover(strokes, aa) * 0.85);

    // whiskers
    float wh = min(min(sd_seg(q, float2(0.56, 0.33), float2(0.86, 0.27), 0.006, 0.003),
                       sd_seg(q, float2(0.57, 0.39), float2(0.88, 0.40), 0.006, 0.003)),
                       sd_seg(q, float2(0.56, 0.45), float2(0.85, 0.52), 0.006, 0.003));
    m = paint(m, float3(0.20, 0.16, 0.18), cover(wh, aa) * 0.8);

    // little pink nose
    m = paint(m, float3(1.0, 0.50, 0.62), cover(sd_tri(p, float2(-0.045, 0.30), float2(0.045, 0.30), float2(0.0, 0.36)), aa));

    // sparkle next to an ear
    float2 sp = p - float2(0.92, -1.05);
    float star = min(sd_ellipse(sp, float2(0.018, 0.10)), sd_ellipse(sp, float2(0.10, 0.018)));
    m = paint(m, float3(1.0, 0.95, 0.6), cover(star, aa));
    return m;
}

float4 mask_image(float2 p)
{
    float2 t = float2(p.x / img_aspect, p.y) * 0.5 + 0.5;
    if (t.x < 0.0 || t.y < 0.0 || t.x > 1.0 || t.y > 1.0)
        return float4(0.0, 0.0, 0.0, 0.0);
    return mask_img.Sample(def_sampler, t);
}

float4 PSMask(VertData v_in) : TARGET
{
    float4 base = image.Sample(def_sampler, v_in.uv);

    float2 d = v_in.uv - center;
    d.x *= aspect;
    float2 p = rot(d, -rotation) / (size * 0.5);
    float aa = texel.y / (size * 0.5) * 1.2;

    float4 m;
    if (mode < 0.5)
        m = mask_hacker(p, aa);
    else if (mode < 1.5)
        m = mask_kitsune(p, aa);
    else if (mode < 2.5)
        m = mask_neko(p, aa);
    else
        m = mask_image(p);

    // "Hòa vào da": carry the room's light and shadow onto the mask. Only the low-frequency
    // brightness is used (a wide blur), so the real eyes/mouth don't ghost through.
    if (blend_mode > 0.5 && m.a > 0.0) {
        float2 r = float2(size * 0.22 / aspect, size * 0.22);
        float light = (lum(v_in.uv) * 2.0
            + lum(v_in.uv + float2(r.x, 0.0)) + lum(v_in.uv - float2(r.x, 0.0))
            + lum(v_in.uv + float2(0.0, r.y)) + lum(v_in.uv - float2(0.0, r.y))
            + lum(v_in.uv + r) + lum(v_in.uv - r)
            + lum(v_in.uv + float2(r.x, -r.y)) + lum(v_in.uv + float2(-r.x, r.y))) * 0.1;
        m.rgb = saturate(m.rgb * lerp(1.0, light * 1.9, 0.7));
    }

    return float4(lerp(base.rgb, m.rgb, m.a * opacity), base.a);
}

technique Draw
{
    pass
    {
        vertex_shader = VSDefault(v_in);
        pixel_shader  = PSMask(v_in);
    }
}
]==]

local FLOAT_PARAMS = { "aspect", "size", "rotation", "mode", "opacity", "eye_holes", "img_aspect", "blend_mode" }

------------------------------------------------------------------------------
-- Filter

local filter = {}
filter.id = FILTER_ID
filter.type = obs.OBS_SOURCE_TYPE_FILTER
filter.output_flags = obs.OBS_SOURCE_VIDEO

filter.get_name = function()
    return "Face Mask (Mặt nạ)"
end

local function free_image(data)
    if data.image ~= nil then
        obs.obs_enter_graphics()
        obs.gs_image_file_free(data.image)
        obs.obs_leave_graphics()
        data.image = nil
    end
end

local function load_image(data, path)
    if path == data.image_path then
        return
    end
    free_image(data)
    data.image_path = path
    if path == nil or path == "" then
        return
    end
    local img = obs.gs_image_file()
    obs.gs_image_file_init(img, path)
    obs.obs_enter_graphics()
    obs.gs_image_file_init_texture(img)
    obs.obs_leave_graphics()
    if not img.loaded then
        obs.script_log(obs.OBS_LOG_WARNING, "[mask] Không đọc được ảnh: " .. path)
        obs.obs_enter_graphics()
        obs.gs_image_file_free(img)
        obs.obs_leave_graphics()
        return
    end
    data.image = img
end

filter.create = function(settings, source)
    local data = {
        source = source,
        width = 0,
        height = 0,
        values = {},
        texel = obs.vec2(),
        center = obs.vec2(),
        tint = obs.vec4(),
        params = {},
    }

    obs.obs_enter_graphics()
    data.effect = obs.gs_effect_create(EFFECT, "face_mask.effect", nil)
    if data.effect ~= nil then
        for _, name in ipairs(FLOAT_PARAMS) do
            data.params[name] = obs.gs_effect_get_param_by_name(data.effect, name)
        end
        for _, name in ipairs({ "texel", "center", "tint", "mask_img" }) do
            data.params[name] = obs.gs_effect_get_param_by_name(data.effect, name)
        end
    end
    obs.obs_leave_graphics()

    if data.effect == nil then
        obs.script_log(obs.OBS_LOG_ERROR, "[mask] Không biên dịch được shader (xem log OBS để biết dòng lỗi)")
        return nil
    end

    filter.update(data, settings)
    return data
end

filter.destroy = function(data)
    free_image(data)
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
    -- Nothing to draw: no size yet, or "image" mode without a loaded image
    if data.width == 0 or data.height == 0 or (data.values.mode == 3 and data.image == nil) then
        obs.obs_source_skip_video_filter(data.source)
        return
    end

    if not obs.obs_source_process_filter_begin(data.source, obs.GS_RGBA, obs.OBS_NO_DIRECT_RENDERING) then
        return
    end

    local v = data.values
    v.aspect = data.width / data.height
    v.img_aspect = 1
    if data.image ~= nil and data.image.cy > 0 then
        v.img_aspect = data.image.cx / data.image.cy
        obs.gs_effect_set_texture(data.params.mask_img, data.image.texture)
    end

    data.texel.x = 1 / data.width
    data.texel.y = 1 / data.height
    obs.gs_effect_set_vec2(data.params.texel, data.texel)
    obs.gs_effect_set_vec2(data.params.center, data.center)
    obs.gs_effect_set_vec4(data.params.tint, data.tint)
    for _, name in ipairs(FLOAT_PARAMS) do
        obs.gs_effect_set_float(data.params[name], v[name])
    end

    obs.obs_source_process_filter_end(data.source, data.effect, data.width, data.height)
end

filter.update = function(data, settings)
    local v = data.values
    v.mode = MASK_INDEX[obs.obs_data_get_string(settings, "mask")] or 0
    v.size = obs.obs_data_get_double(settings, "size") / 100
    v.rotation = math.rad(obs.obs_data_get_double(settings, "rotation"))
    v.opacity = obs.obs_data_get_double(settings, "opacity") / 100
    v.eye_holes = obs.obs_data_get_bool(settings, "eye_holes") and 1 or 0
    v.blend_mode = obs.obs_data_get_string(settings, "blend") == "mix" and 1 or 0

    data.center.x = obs.obs_data_get_double(settings, "x") / 100
    data.center.y = obs.obs_data_get_double(settings, "y") / 100

    -- OBS stores colours as 0xAABBGGRR
    local c = obs.obs_data_get_int(settings, "ear_color")
    data.tint.x = bit.band(c, 0xFF) / 255
    data.tint.y = bit.band(bit.rshift(c, 8), 0xFF) / 255
    data.tint.z = bit.band(bit.rshift(c, 16), 0xFF) / 255
    data.tint.w = 1

    load_image(data, obs.obs_data_get_string(settings, "image_path"))
end

function on_mask_changed(props, prop, settings)
    local m = obs.obs_data_get_string(settings, "mask")
    obs.obs_property_set_visible(obs.obs_properties_get(props, "image_path"), m == "image")
    obs.obs_property_set_visible(obs.obs_properties_get(props, "ear_color"), m == "neko")
    obs.obs_property_set_visible(obs.obs_properties_get(props, "eye_holes"), m == "hacker" or m == "kitsune")
    return true
end

filter.get_properties = function(data)
    local props = obs.obs_properties_create()

    local list = obs.obs_properties_add_list(props, "mask", "Mặt nạ",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(list, "Hacker (Anonymous)", "hacker")
    obs.obs_property_list_add_string(list, "Kitsune — mặt nạ cáo", "kitsune")
    obs.obs_property_list_add_string(list, "Neko — tai mèo, má hồng", "neko")
    obs.obs_property_list_add_string(list, "Ảnh PNG của tôi", "image")
    obs.obs_property_set_modified_callback(list, on_mask_changed)

    obs.obs_properties_add_path(props, "image_path", "Ảnh mặt nạ (PNG nền trong suốt)",
        obs.OBS_PATH_FILE, "Ảnh (*.png *.webp *.gif *.jpg)", nil)
    obs.obs_properties_add_color(props, "ear_color", "Màu tai")
    obs.obs_properties_add_bool(props, "eye_holes", "Khoét lỗ mắt (thấy mắt thật)")

    obs.obs_properties_add_float_slider(props, "x", "Tâm mặt X (%)", 0, 100, 0.5)
    obs.obs_properties_add_float_slider(props, "y", "Tâm mặt Y (%)", 0, 100, 0.5)
    obs.obs_properties_add_float_slider(props, "size", "Cỡ (% chiều cao khung)", 5, 150, 0.5)
    obs.obs_properties_add_float_slider(props, "rotation", "Xoay (độ)", -45, 45, 0.5)
    obs.obs_properties_add_float_slider(props, "opacity", "Độ đậm (%)", 0, 100, 1)

    local blend = obs.obs_properties_add_list(props, "blend", "Kiểu phủ",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(blend, "Đè lên gốc (che kín)", "over")
    obs.obs_property_list_add_string(blend, "Hòa vào da (giữ sáng tối của mặt thật)", "mix")

    return props
end

filter.get_defaults = function(settings)
    obs.obs_data_set_default_string(settings, "mask", "hacker")
    obs.obs_data_set_default_string(settings, "image_path", "")
    obs.obs_data_set_default_int(settings, "ear_color", 0xFFF2E6FB) -- pastel pink-white
    obs.obs_data_set_default_bool(settings, "eye_holes", false)
    obs.obs_data_set_default_double(settings, "x", 50)
    obs.obs_data_set_default_double(settings, "y", 40)
    obs.obs_data_set_default_double(settings, "size", 45)
    obs.obs_data_set_default_double(settings, "rotation", 0)
    obs.obs_data_set_default_double(settings, "opacity", 100)
    obs.obs_data_set_default_string(settings, "blend", "over")
end

obs.obs_register_source(filter)

------------------------------------------------------------------------------
-- Script: hotkeys to toggle the mask and cycle through the styles on the webcam

local CARTOON_ID = "algen_cartoon_face"

local cfg = { webcam = NONE, on_original = true }
local hotkeys = {}
local paused_filters = {} -- names of Cartoon Face filters we turned off while the mask is on

local function log(msg)
    obs.script_log(obs.OBS_LOG_INFO, "[mask] " .. msg)
end

---
-- Find our filter on the webcam, creating it (disabled) if needed. Caller releases it.
function get_mask_filter(create)
    local cam = obs.obs_get_source_by_name(cfg.webcam)
    if cam == nil then
        log("Không tìm thấy webcam '" .. tostring(cfg.webcam) .. "'")
        return nil
    end

    local found = nil
    local filters = obs.obs_source_enum_filters(cam)
    if filters ~= nil then
        for _, f in ipairs(filters) do
            if found == nil and obs.obs_source_get_unversioned_id(f) == FILTER_ID then
                found = f
                obs.obs_source_get_ref(f)
            end
        end
        obs.source_list_release(filters)
    end

    if found == nil and create then
        found = obs.obs_source_create(FILTER_ID, FILTER_NAME, nil, nil)
        if found ~= nil then
            obs.obs_source_set_enabled(found, false)
            obs.obs_source_filter_add(cam, found)
            log("Đã thêm filter '" .. FILTER_NAME .. "' vào " .. cfg.webcam)
        end
    end
    obs.obs_source_release(cam)
    return found
end

---
-- "Đè lên ảnh gốc": while the mask is on, pause Cartoon Face on the same webcam and keep the mask
-- as the last filter, so it sits on the untouched camera picture. Turning the mask off restores them.
function apply_on_original(mask_filter, on)
    local cam = obs.obs_get_source_by_name(cfg.webcam)
    if cam == nil then
        return
    end

    if on and cfg.on_original then
        obs.obs_source_filter_set_order(cam, mask_filter, obs.OBS_ORDER_MOVE_BOTTOM)
        local filters = obs.obs_source_enum_filters(cam)
        if filters ~= nil then
            for _, f in ipairs(filters) do
                if obs.obs_source_get_unversioned_id(f) == CARTOON_ID and obs.obs_source_enabled(f) then
                    obs.obs_source_set_enabled(f, false)
                    table.insert(paused_filters, obs.obs_source_get_name(f))
                end
            end
            obs.source_list_release(filters)
        end
    elseif not on then
        for _, name in ipairs(paused_filters) do
            local f = obs.obs_source_get_filter_by_name(cam, name)
            if f ~= nil then
                obs.obs_source_set_enabled(f, true)
                obs.obs_source_release(f)
            end
        end
        paused_filters = {}
    end
    obs.obs_source_release(cam)
end

function set_mask_enabled(f, on)
    obs.obs_source_set_enabled(f, on)
    apply_on_original(f, on)
end

function toggle_mask()
    local f = get_mask_filter(true)
    if f == nil then return end
    local on = not obs.obs_source_enabled(f)
    set_mask_enabled(f, on)
    log("Mặt nạ: " .. (on and "BẬT" or "TẮT"))
    obs.obs_source_release(f)
end

function next_mask()
    local f = get_mask_filter(true)
    if f == nil then return end
    local settings = obs.obs_source_get_settings(f)
    local current = obs.obs_data_get_string(settings, "mask")
    if current == "" then current = "hacker" end
    local has_image = obs.obs_data_get_string(settings, "image_path") ~= ""
    local idx = (MASK_INDEX[current] or 0) + 1
    local nxt = MASKS[idx % #MASKS + 1]
    if nxt == "image" and not has_image then
        nxt = MASKS[1] -- skip "image" until a PNG is chosen
    end
    obs.obs_data_set_string(settings, "mask", nxt)
    obs.obs_source_update(f, settings)
    obs.obs_data_release(settings)
    if not obs.obs_source_enabled(f) then
        set_mask_enabled(f, true)
    end
    log("Mặt nạ: " .. nxt)
    obs.obs_source_release(f)
end

function on_toggle(pressed)
    if pressed then toggle_mask() end
end

function on_next(pressed)
    if pressed then next_mask() end
end

function script_description()
    return "<b>Face Mask v" .. VERSION .. "</b><br>" ..
        "Đeo mặt nạ Hacker / Kitsune / Neko (hoặc PNG riêng) lên webcam. Chỉnh vị trí trong " ..
        "<i>Filters</i> của webcam → <i>Face Mask (Mặt nạ)</i>."
end

function script_properties()
    local props = obs.obs_properties_create()
    local cam = obs.obs_properties_add_list(props, "webcam", "Webcam",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(cam, "(chọn)", NONE)
    local sources = obs.obs_enum_sources()
    if sources ~= nil then
        for _, s in ipairs(sources) do
            if bit.band(obs.obs_source_get_output_flags(s), obs.OBS_SOURCE_VIDEO) ~= 0 then
                local name = obs.obs_source_get_name(s)
                obs.obs_property_list_add_string(cam, name, name)
            end
        end
        obs.source_list_release(sources)
    end
    obs.obs_properties_add_bool(props, "on_original",
        "Đè lên ảnh gốc (tạm tắt Cartoon Face khi đeo mặt nạ, mặt nạ nằm trên cùng)")
    obs.obs_properties_add_button(props, "btn_toggle", "Bật / Tắt mặt nạ", function() toggle_mask() return false end)
    obs.obs_properties_add_button(props, "btn_next", "Mặt nạ tiếp theo", function() next_mask() return false end)
    return props
end

function script_defaults(settings)
    obs.obs_data_set_default_string(settings, "webcam", NONE)
    obs.obs_data_set_default_bool(settings, "on_original", true)
end

function script_update(settings)
    cfg.webcam = obs.obs_data_get_string(settings, "webcam")
    cfg.on_original = obs.obs_data_get_bool(settings, "on_original")
end

local HOTKEYS = {
    { "face_mask_toggle", "Face Mask: Bật/Tắt", on_toggle },
    { "face_mask_next", "Face Mask: Mặt nạ tiếp theo", on_next },
}

function script_load(settings)
    for _, hk in ipairs(HOTKEYS) do
        local id = obs.obs_hotkey_register_frontend(hk[1], hk[2], hk[3])
        local arr = obs.obs_data_get_array(settings, hk[1])
        obs.obs_hotkey_load(id, arr)
        obs.obs_data_array_release(arr)
        hotkeys[hk[1]] = id
    end
end

function script_save(settings)
    for _, hk in ipairs(HOTKEYS) do
        local arr = obs.obs_hotkey_save(hotkeys[hk[1]])
        obs.obs_data_set_array(settings, hk[1], arr)
        obs.obs_data_array_release(arr)
    end
end
