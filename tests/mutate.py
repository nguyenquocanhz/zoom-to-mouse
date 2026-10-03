#!/usr/bin/env python3
"""Mutation check: cài lại từng lỗi vào bản sao script, test PHẢI đỏ.

Mỗi mutant là một lỗi thật (lỗi cũ đã sửa, hoặc lỗi dễ mắc). Nếu test vẫn xanh
với mutant nào thì test đang hở ở đó -> viết thêm test cho tới khi nó đỏ.

    python3 tests/mutate.py            # chạy tất cả
    python3 tests/mutate.py zoom       # chỉ mutant có id chứa "zoom"
"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

Z, C, P, A, R, CH, L, T = (
    "obs-zoom-to-mouse.lua", "countdown-pro.lua", "pomodoro-study.lua", "afk-scene-switcher.lua",
    "instant-replay.lua", "chapter-markers.lua", "live-timer.lua", "text-ticker.lua",
)
CF = "cartoon-face.lua"
FM = "face-mask.lua"
SW = "smooth-scene-switcher.lua"
TEST = {Z: "test_zoom.lua", C: "test_countdown.lua", P: "test_pomodoro.lua", A: "test_afk.lua",
        R: "test_replay.lua", CH: "test_chapters.lua", L: "test_live_timer.lua", T: "test_ticker.lua",
        CF: "test_cartoon.lua", FM: "test_mask.lua", SW: "test_switcher.lua"}

# (id, script, old, new) — `old` must appear exactly once
MUTANTS = [
    # --- lỗi có trong zoom-to-mouse v1.0.1 ---
    ("zoom-v101-restore-get-info", Z, "sceneitem_set_info(sceneitem, sceneitem_info_orig)",
     "sceneitem_get_info(sceneitem, sceneitem_info_orig)"),
    ("zoom-v101-monitor-off-by-one", Z, "for i = 0, item_count - 1 do", "for i = 0, item_count do"),
    ("zoom-v101-edge-1px-short", Z,
     "if math.abs(crop_filter_info.x - zoom_target.crop.x) < 0.5 then crop_filter_info.x = zoom_target.crop.x end", ""),
    ("zoom-v101-update-every-frame", Z,
     "if last.x == x and last.y == y and last.w == w and last.h == h then", "if false then"),
    ("zoom-v101-lerp-from-current", Z, "lerp(anim_from.x, zoom_target.crop.x, e)",
     "lerp(crop_filter_info.x, zoom_target.crop.x, e)"),
    ("zoom-v101-fps-dependent", Z, "zoom_time + zoom_speed * frames", "zoom_time + zoom_speed"),
    ("zoom-v101-follow-fps-dependent", Z, "local t = 1 - math.pow(1 - follow_speed, frames)",
     "local t = follow_speed"),
    ("zoom-v101-no-reverse", Z,
     "if zoom_state == ZoomState.ZoomedIn or zoom_state == ZoomState.ZoomingIn then\n        start_zoom_out()",
     "if zoom_state == ZoomState.ZoomedIn then\n        start_zoom_out()"),
    ("zoom-v101-no-restore-on-exit", Z, " or event == obs.OBS_FRONTEND_EVENT_EXIT", ""),
    ("zoom-v101-follow-timer-idle", Z, "            -- Nothing left to animate, free the per-frame callback\n            stop_timer()", ""),
    # --- lỗi dễ mắc trong phần mới ---
    ("zoom-display-check-always-true", Z,
     "return dc_info ~= nil and obs.obs_source_get_id(source_to_check) == dc_info.source_id", "return dc_info ~= nil"),
    ("zoom-scale-filter-not-restored", Z, "local want = scale_filter_orig", "local want = scale_filter_zoomed"),
    ("zoom-timer-kept-after-out", Z, "zoom_target = nil\n                stop_timer()", "zoom_target = nil"),
    ("zoom-click-other-monitor", Z,
     "if m.x < 0 or m.y < 0 or m.x > zoom_info.source_size.width or m.y > zoom_info.source_size.height then",
     "if false then"),
    ("zoom-auto-out-never", Z, "now - last_activity >= auto_zoom_out_delay then", "now - last_activity >= auto_zoom_out_delay * 100 then"),
    ("zoom-sharpen-not-progressive", Z, "clamp(0, 1, ratio - 1)", "1"),
    ("zoom-no-clamp-to-source", Z,
     "crop.x = math.floor(clamp(0, (zoom.source_size.width - new_size.width), crop.x))", "crop.x = math.floor(crop.x)"),
    ("zoom-level-unclamped", Z, "zoom_value = clamp(1, MAX_ZOOM, zoom_value + delta)", "zoom_value = zoom_value + delta"),
    ("zoom-hotkey-no-refresh", Z, '        log("Sceneitem is nil, attempting refresh...")\n        refresh_sceneitem(true)', ""),
    # --- countdown ---
    ("countdown-floor", C, "sec = math.max(0, math.ceil(sec))", "sec = math.max(0, math.floor(sec))"),
    ("countdown-clock-no-tomorrow", C, "target = target + 86400", "target = target"),
    ("countdown-no-end-scene", C, "        switch_scene(cfg.end_scene)\n", ""),
    ("countdown-add-minute-running", C, "end_ns = end_ns + 60 * 1000000000", "remaining_ns = remaining_ns + 60 * 1000000000"),
    ("countdown-pause-loses-time", C,
     "    running = false\n    remaining_ns = math.max(0, end_ns - obs.os_gettime_ns())", "    running = false"),
    # --- pomodoro ---
    ("pomodoro-drift", P, "end_ns = math.min(end_ns, obs.os_gettime_ns()) + remaining_ns",
     "end_ns = obs.os_gettime_ns() + remaining_ns"),
    ("pomodoro-long-break-late", P, "if cycle >= cfg.cycles then", "if cycle > cfg.cycles then"),
    ("pomodoro-cycle-not-reset", P, "        if phase == PHASE_LONG then\n            cycle = 1", "        if false then\n            cycle = 1"),
    ("pomodoro-ignores-auto-continue", P, "        if cfg.auto_continue then", "        if true then"),
    # --- afk ---
    ("afk-never-returns", A, "elseif idle < ACTIVE_THRESHOLD then", "elseif idle < 0 then"),
    ("afk-fights-manual-switch", A, "elseif current ~= cfg.brb_scene then", "elseif false then"),
    ("afk-ignores-only-live", A, "(not cfg.only_when_live or is_live())", "true"),
    # --- instant replay ---
    ("replay-plays-any-save", R, "path ~= nil and path ~= \"\" and path ~= replay_before then", "path ~= nil and path ~= \"\" then"),
    ("replay-yanks-scene-back", R, "and current_scene_name() == cfg.replay_scene then", "then"),
    ("replay-no-start-grace", R, "if elapsed > START_GRACE_S then", "if true then"),
    # --- chapters ---
    ("chapters-counts-pause", CH, "local paused = c.paused + (c.pause_start and (now_ns() - c.pause_start) or 0)",
     "local paused = 0"),
    ("chapters-agenda-off-by-one", CH, "cfg.titles[#session.markers]", "cfg.titles[#session.markers + 1]"),
    ("chapters-undo-noop", CH, "local m = table.remove(session.markers)", "local m = session.markers[#session.markers]"),
    # --- live timer ---
    ("live-timer-no-resume", L, "c.start = now_ns() - frames * obs.obs_get_frame_interval_ns()", "c.start = now_ns()"),
    ("live-timer-no-paused-label", L, "fmt = paused and cfg.paused_format or cfg.rec_format", "fmt = cfg.rec_format"),
    # --- ticker ---
    ("ticker-percent-unescaped", T, '(msg:gsub("%%", "%%%%"))', "msg"),
    ("ticker-bom-kept", T, 'line = trim(line:gsub("^\\239\\187\\191", ""))', "line = trim(line)"),
    ("ticker-shuffle-repeats", T, "if cfg.shuffle and #order > 1 and order[1] == previous then", "if false then"),
    # --- cartoon face (Lua side; the shader itself is checked in real OBS by e2e_obs.py) ---
    ("cartoon-color-bgr-swapped", CF, "data.line.x = bit.band(c, 0xFF) / 255", "data.line.x = bit.band(bit.rshift(c, 16), 0xFF) / 255"),
    ("cartoon-mask-diameter-as-radius", CF, 'data.radius.x = obs.obs_data_get_double(settings, "mask_w") / 200',
     'data.radius.x = obs.obs_data_get_double(settings, "mask_w") / 100'),
    ("cartoon-intensity-not-percent", CF, 'v.intensity = obs.obs_data_get_double(settings, "intensity") / 100',
     'v.intensity = obs.obs_data_get_double(settings, "intensity")'),
    ("cartoon-filter-added-twice", CF, "if not found and on then", "if on then"),
    ("cartoon-no-undo-on-settings-change", CF, "        apply(false) -- undo with the old webcam/mode before switching\n", ""),
    ("cartoon-render-before-size", CF, "if data.width == 0 or data.height == 0 then", "if false then"),
    ("cartoon-half-built-on-shader-error", CF, "    if data.effect == nil then\n        obs.script_log", "    if false then\n        obs.script_log"),
    # --- face mask ---
    ("mask-ear-color-bgr", FM, "data.tint.x = bit.band(c, 0xFF) / 255", "data.tint.x = bit.band(bit.rshift(c, 16), 0xFF) / 255"),
    ("mask-rotation-degrees", FM, 'math.rad(obs.obs_data_get_double(settings, "rotation"))', 'obs.obs_data_get_double(settings, "rotation")'),
    ("mask-size-not-fraction", FM, 'obs.obs_data_get_double(settings, "size") / 100', 'obs.obs_data_get_double(settings, "size") / 50'),
    ("mask-blend-inverted", FM, '"blend") == "mix" and 1 or 0', '"blend") == "over" and 1 or 0'),
    ("mask-not-on-top", FM, "        obs.obs_source_filter_set_order(cam, mask_filter, obs.OBS_ORDER_MOVE_BOTTOM)\n", ""),
    ("mask-cartoon-not-restored", FM, "                obs.obs_source_set_enabled(f, true)\n", ""),
    ("mask-enables-user-disabled-cartoon", FM, "== CARTOON_ID and obs.obs_source_enabled(f) then", "== CARTOON_ID then"),
    ("mask-cycles-into-missing-image", FM, 'if nxt == "image" and not has_image then', "if false then"),
    ("mask-reloads-same-image", FM, "if path == data.image_path then", "if false then"),
    ("mask-image-mode-renders-nothing", FM, " or (data.values.mode == 3 and data.image == nil)", ""),
    # --- smooth scene switcher ---
    ("switcher-direction-swapped", SW, 'dir == "prev" and "right" or "left"', 'dir == "prev" and "left" or "right"'),
    ("switcher-no-queue", SW, "    if busy then\n        pending = { name = name, dir = dir }\n        return\n    end", ""),
    ("switcher-restores-mid-queue", SW, "        if busy then\n            return -- keep", "        if false then\n            return -- keep"),
    ("switcher-step-ignores-queue", SW, "local base = (pending and pending.name) or busy_target or current_scene_name()",
     "local base = current_scene_name()"),
    ("switcher-no-end-timer", SW, "    obs.timer_add(on_transition_end, ms + 150)", "    local _ = ms"),
    ("switcher-end-too-early", SW, "    obs.timer_add(on_transition_end, ms + 150)", "    obs.timer_add(on_transition_end, 100)"),
    ("switcher-window-fights-manual", SW, "if title == nil or title == last_title then", "if title == nil then"),
    ("switcher-window-case-sensitive", SW, "local lower = title:lower()", "local lower = title"),
    ("switcher-ignores-studio-mode", SW,
     "    if obs.obs_frontend_preview_program_mode_active() then\n        obs.obs_frontend_set_current_preview_scene",
     "    if false then\n        obs.obs_frontend_set_current_preview_scene"),
    ("switcher-wrap-ignored", SW, "        if not cfg.wrap then return end\n", ""),
    ("switcher-restore-option-ignored", SW, "if not cfg.restore or saved_transition ~= nil then", "if saved_transition ~= nil then"),
    # --- deadlock class: frontend event callback + scene switching from hotkey/timer ---
    ("switcher-event-callback-deadlock", SW, "function script_load(settings)\n",
     "function script_load(settings)\n    obs.obs_frontend_add_event_callback(function(e) end)\n"),
    ("replay-event-callback-deadlock", R, "function script_load(settings)\n",
     "function script_load(settings)\n    obs.obs_frontend_add_event_callback(function(e) end)\n"),
    ("replay-poll-no-timeout", R, "elseif now_sec() - save_requested_at > SAVE_TIMEOUT_S then", "elseif false then"),
]


def main():
    flt = sys.argv[1] if len(sys.argv) > 1 else ""
    survivors = []
    for mid, script, old, new in MUTANTS:
        if flt not in mid:
            continue
        with tempfile.TemporaryDirectory() as tmp:
            dst = Path(tmp) / "obs-lua"
            shutil.copytree(ROOT, dst, ignore=shutil.ignore_patterns(".git"))
            path = dst / script if script == Z else dst / "plugins" / script
            src = path.read_text(encoding="utf-8")
            count = src.count(old)
            if count != 1:
                print(f"BAD MUTANT {mid}: pattern found {count}x")
                survivors.append(mid)
                continue
            path.write_text(src.replace(old, new), encoding="utf-8")
            res = subprocess.run(["luajit", TEST[script]], cwd=dst / "tests", capture_output=True, text=True)
            killed = res.returncode != 0
            print(f"{'KILLED  ' if killed else 'SURVIVED'} {mid}")
            if not killed:
                survivors.append(mid)
    print(f"\n{len(survivors)} mutant(s) survived" + (": " + ", ".join(survivors) if survivors else ""))
    sys.exit(1 if survivors else 0)


if __name__ == "__main__":
    main()
