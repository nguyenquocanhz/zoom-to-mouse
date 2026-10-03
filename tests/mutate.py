#!/usr/bin/env python3
"""Mutation check: cài lại từng lỗi vào bản sao script, test PHẢI đỏ.

Mỗi mutant là một lỗi thật (lỗi của v1.0.1 đã sửa, hoặc lỗi dễ mắc). Nếu test vẫn xanh
với mutant nào thì test đang hở ở đó -> viết thêm test cho tới khi nó đỏ.

    python3 tests/mutate.py            # chạy tất cả
    python3 tests/mutate.py v101       # chỉ mutant có id chứa "v101"
"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
Z = "obs-zoom-to-mouse.lua"

# (id, script, old, new) — `old` must appear exactly once
MUTANTS = [
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
]


def main():
    flt = sys.argv[1] if len(sys.argv) > 1 else ""
    survivors = []
    for mid, script, old, new in MUTANTS:
        if flt not in mid:
            continue
        with tempfile.TemporaryDirectory() as tmp:
            dst = Path(tmp) / "repo"
            shutil.copytree(ROOT, dst, ignore=shutil.ignore_patterns(".git"))
            path = dst / script
            src = path.read_text(encoding="utf-8")
            count = src.count(old)
            if count != 1:
                print(f"BAD MUTANT {mid}: pattern found {count}x")
                survivors.append(mid)
                continue
            path.write_text(src.replace(old, new), encoding="utf-8")
            res = subprocess.run(["luajit", "test_zoom.lua"], cwd=dst / "tests", capture_output=True, text=True)
            killed = res.returncode != 0
            print(f"{'KILLED  ' if killed else 'SURVIVED'} {mid}")
            if not killed:
                survivors.append(mid)
    print(f"\n{len(survivors)} mutant(s) survived" + (": " + ", ".join(survivors) if survivors else ""))
    sys.exit(1 if survivors else 0)


if __name__ == "__main__":
    main()
