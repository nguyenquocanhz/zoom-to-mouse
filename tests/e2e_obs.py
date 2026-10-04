#!/usr/bin/env python3
"""Chạy thử các script trong OBS THẬT (headless, Linux).

- Dựng một profile/scene collection tạm, load obs-zoom-to-mouse.lua và toàn bộ plugins/*.lua
- Bật obs-websocket, gắn filter "Cartoon Face" lên một ảnh khuôn mặt và chụp ảnh từng kiểu
- Quét log OBS: script nào lỗi Lua / gọi API không tồn tại là test đỏ

Cần: obs-studio (có obslua), Xvfb, Mesa (llvmpipe), pip install websocket-client

    python3 tests/e2e_obs.py ảnh_mặt.png thư_mục_ra/
"""
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import struct
import zlib

import websocket

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = [ROOT / "obs-zoom-to-mouse.lua"] + sorted((ROOT / "plugins").glob("*.lua"))
W, H = 1280, 720
DESKTOP_W = 2560  # the virtual X screen; the real mouse is moved on it with xdotool
SCRIPT_SETTINGS = {
    "obs-zoom-to-mouse.lua": {"source": "Desktop", "debug_logs": True, "click_zoom": False},
    "live-timer.lua": {"text_source": "Timer"},
    "face-mask.lua": {"webcam": "Face", "on_original": True},
    "smooth-scene-switcher.lua": {"next_transition": "Slide", "prev_transition": "Slide", "duration": 300,
                                  "order": [{"value": "Main"}, {"value": "Scene B"}, {"value": "Scene C"}]},
    "instant-replay.lua": {"media_source": "Replay Video", "replay_scene": "Replay", "max_seconds": 3},
}
# Where the face is in the sample photo (NASA astronaut portrait used by scikit-image)
FACE = dict(x=43.5, y=21.0, size=21.0)

PRESETS = {
    "anime": dict(levels=6, edge_strength=1.0, edge_threshold=0.22, edge_width=1.0, saturation=1.35, smoothness=1.6),
    "comic": dict(levels=4, edge_strength=1.0, edge_threshold=0.12, edge_width=1.5, saturation=1.6, smoothness=1.2),
    "soft": dict(levels=9, edge_strength=0.6, edge_threshold=0.3, edge_width=1.0, saturation=1.15, smoothness=2.5),
    "sketch": dict(levels=3, edge_strength=1.0, edge_threshold=0.08, edge_width=1.2, saturation=0.2, smoothness=1.0),
}


def write_png(path: Path, rows):
    """Tiny RGBA PNG writer (no Pillow needed). rows: list of lists of (r, g, b, a)."""
    h, w = len(rows), len(rows[0])
    raw = b"".join(b"\x00" + bytes(c for px in row for c in px) for row in rows)
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def pixel_glasses(path: Path):
    """'Deal with it' pixel sunglasses, transparent background, 2:1 aspect."""
    art = [
        "................................",
        "................................",
        "................................",
        "................................",
        "................................",
        "................................",
        "................................",
        "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
        "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
        "...XXXXXXXXXX....XXXXXXXXXX.....",
        "...XWWXXXXXXX....XWWXXXXXXX.....",
        "...XXWWXXXXXX....XXWWXXXXXX.....",
        "....XXXXXXXX......XXXXXXXX......",
        ".....XXXXXX........XXXXXX.......",
        "................................",
        "................................",
    ]
    px = {".": (0, 0, 0, 0), "X": (10, 10, 12, 255), "W": (255, 255, 255, 255)}
    scale = 8
    rows = []
    for line in art:
        row = [px[c] for c in line for _ in range(scale)]
        rows += [row] * scale
    write_png(path, rows)


def write_config(home: Path, face: Path):
    cfg = home / ".config" / "obs-studio"
    (cfg / "basic" / "profiles" / "Test").mkdir(parents=True)
    (cfg / "basic" / "scenes").mkdir(parents=True)
    (cfg / "plugin_config" / "obs-websocket").mkdir(parents=True)

    (cfg / "global.ini").write_text(
        "[General]\nFirstRun=true\n"
        "[Basic]\nProfile=Test\nProfileDir=Test\nSceneCollection=Test\nSceneCollectionFile=Test\n"
        "[OBSWebSocket]\nFirstLoad=false\nServerEnabled=true\nServerPort=4455\nAuthRequired=false\n"
    )
    (cfg / "plugin_config" / "obs-websocket" / "config.json").write_text(json.dumps({
        "alerts_enabled": False, "auth_required": False, "first_load": False,
        "server_enabled": True, "server_password": "", "server_port": 4455,
    }))
    (cfg / "basic" / "profiles" / "Test" / "basic.ini").write_text(
        f"[General]\nName=Test\n[Video]\nBaseCX={W}\nBaseCY={H}\nOutputCX={W}\nOutputCY={H}\nFPSType=0\nFPSCommon=30\n"
        "[Output]\nMode=Simple\n"
        f"[SimpleOutput]\nFilePath={home / 'rec'}\nRecFormat2=mkv\nRecQuality=Stream\nStreamEncoder=x264\n"
        "VBitrate=800\nRecRB=true\nRecRBTime=5\n"
    )
    (home / "rec").mkdir()

    scene = {
        "name": "Test",
        "current_scene": "Main",
        "current_program_scene": "Main",
        "scene_order": [{"name": "Main"}, {"name": "Scene B"}, {"name": "Scene C"}, {"name": "Replay"}],
        "transitions": [{"id": "slide_transition", "name": "Slide", "settings": {}}],
        "current_transition": "Fade",
        "transition_duration": 700,
        "sources": [
            {"id": "image_source", "versioned_id": "image_source", "name": "Face",
             "settings": {"file": str(face)}},
            {"id": "text_ft2_source", "versioned_id": "text_ft2_source_v2", "name": "Timer",
             "settings": {"text": "..."}},
            {"id": "xshm_input", "versioned_id": "xshm_input", "name": "Desktop",
             "settings": {"screen": 0, "show_cursor": False}},
            {"id": "scene", "versioned_id": "scene", "name": "Main", "settings": {
                "id_counter": 3,
                "items": [
                    {"name": "Desktop", "id": 3, "visible": True, "pos": {"x": 0, "y": 0},
                     "scale": {"x": 0.5, "y": 0.5}, "align": 5},
                    {"name": "Face", "id": 1, "visible": True, "pos": {"x": 0, "y": 0},
                     "scale": {"x": 1, "y": 1}, "align": 5, "bounds_type": 2,
                     "bounds_align": 0, "bounds": {"x": W, "y": H}},
                    {"name": "Timer", "id": 2, "visible": True, "pos": {"x": 10, "y": 10},
                     "scale": {"x": 1, "y": 1}, "align": 5},
                ]}},
            {"id": "scene", "versioned_id": "scene", "name": "Scene B", "settings": {"id_counter": 0, "items": []}},
            {"id": "scene", "versioned_id": "scene", "name": "Scene C", "settings": {"id_counter": 0, "items": []}},
            {"id": "ffmpeg_source", "versioned_id": "ffmpeg_source", "name": "Replay Video",
             "settings": {"is_local_file": True, "local_file": ""}},
            {"id": "scene", "versioned_id": "scene", "name": "Replay", "settings": {
                "id_counter": 1,
                "items": [{"name": "Replay Video", "id": 1, "visible": True, "pos": {"x": 0, "y": 0},
                           "scale": {"x": 1, "y": 1}, "align": 5, "bounds_type": 2, "bounds_align": 0,
                           "bounds": {"x": W, "y": H}}]}},
        ],
        "modules": {"scripts-tool": [
            {"path": str(p), "settings": SCRIPT_SETTINGS.get(p.name, {})}
            for p in SCRIPTS
        ]},
    }
    (cfg / "basic" / "scenes" / "Test.json").write_text(json.dumps(scene, indent=1))
    return cfg


class Obs:
    def __init__(self, url="ws://127.0.0.1:4455"):
        deadline = time.time() + 90
        while True:
            try:
                self.ws = websocket.create_connection(url, timeout=10)
                break
            except OSError:
                if time.time() > deadline:
                    raise
                time.sleep(1)
        json.loads(self.ws.recv())  # Hello
        self.ws.send(json.dumps({"op": 1, "d": {"rpcVersion": 1, "eventSubscriptions": 0}}))
        json.loads(self.ws.recv())  # Identified
        self.n = 0
        # The websocket server comes up before OBS has finished loading: wait for "ready"
        while True:
            try:
                self.version = self.req("GetVersion")["obsVersion"]
                break
            except RuntimeError as e:
                if "207" not in str(e) or time.time() > deadline:
                    raise
                time.sleep(1)

    def req(self, kind, **data):
        self.n += 1
        self.ws.send(json.dumps({"op": 6, "d": {"requestType": kind, "requestId": str(self.n), "requestData": data}}))
        while True:
            msg = json.loads(self.ws.recv())
            if msg["op"] == 7 and msg["d"]["requestId"] == str(self.n):
                st = msg["d"]["requestStatus"]
                if not st["result"]:
                    raise RuntimeError(f"{kind}: {st}")
                return msg["d"].get("responseData", {})


def main():
    face = Path(sys.argv[1]).resolve()
    out = Path(sys.argv[2]).resolve()
    out.mkdir(parents=True, exist_ok=True)

    home = Path(tempfile.mkdtemp(prefix="obs-e2e-"))
    cfg = write_config(home, face)
    env = dict(os.environ, HOME=str(home), DISPLAY=":99", LIBGL_ALWAYS_SOFTWARE="1")
    xvfb = subprocess.Popen(["Xvfb", ":99", "-screen", "0", f"{DESKTOP_W}x{H}x24"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1)
    obs = subprocess.Popen(["obs", "--disable-shutdown-check", "--disable-updater", "--multi"],
                           env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    failures = []
    try:
        o = Obs()
        print("OBS", o.version)
        time.sleep(3)  # let scripts load and timers tick

        o.req("CreateSourceFilter", sourceName="Face", filterName="Cartoon", filterKind="algen_cartoon_face",
              filterSettings={})
        o.req("SetSourceFilterEnabled", sourceName="Face", filterName="Cartoon", filterEnabled=False)
        time.sleep(0.5)
        shot = lambda name: o.req("SaveSourceScreenshot", sourceName="Face", imageFormat="png",
                                  imageFilePath=str(out / f"{name}.png"))
        shot("0-original")
        o.req("SetSourceFilterEnabled", sourceName="Face", filterName="Cartoon", filterEnabled=True)
        for i, (name, values) in enumerate(PRESETS.items(), 1):
            o.req("SetSourceFilterSettings", sourceName="Face", filterName="Cartoon",
                  filterSettings=dict(values, preset=name, use_mask=False))
            time.sleep(0.5)
            shot(f"{i}-{name}")
        o.req("SetSourceFilterSettings", sourceName="Face", filterName="Cartoon",
              filterSettings=dict(PRESETS["anime"], preset="anime", use_mask=True,
                                  mask_x=50, mask_y=38, mask_w=45, mask_h=60, mask_feather=35))
        time.sleep(0.5)
        shot("5-anime-face-only")

        o.req("SetSourceFilterSettings", sourceName="Face", filterName="Cartoon",
              filterSettings=dict(PRESETS["anime"], preset="anime", use_mask=False))

        # ---- Face Mask: the hotkey adds the mask on top of the ORIGINAL picture (Cartoon paused)
        o.req("TriggerHotkeyByName", hotkeyName="face_mask_toggle")
        time.sleep(0.5)
        flist = o.req("GetSourceFilterList", sourceName="Face")["filters"]
        order = [(f["filterName"], f["filterEnabled"]) for f in flist]
        print("Filters after mask on:", order)
        if order != [("Cartoon", False), ("Face Mask", True)]:
            failures.append(f"mask on original: expected Cartoon paused and mask last, got {order}")

        glasses = out / "glasses.png"
        pixel_glasses(glasses)
        looks = [
            ("6-mask-hacker", dict(mask="hacker")),
            ("7-mask-hacker-eyeholes", dict(mask="hacker", eye_holes=True)),
            ("8-mask-kitsune", dict(mask="kitsune")),
            ("9-mask-neko", dict(mask="neko")),
            ("10-mask-image", dict(mask="image", image_path=str(glasses), size=8.0, y=19.5)),
            ("11-mask-hacker-mix", dict(mask="hacker", blend="mix")),
        ]
        for name, extra in looks:
            settings = dict(FACE, mask="hacker", eye_holes=False, blend="over", image_path="")
            settings.update(extra)
            o.req("SetSourceFilterSettings", sourceName="Face", filterName="Face Mask",
                  filterSettings=settings, overlay=False)
            time.sleep(0.5)
            shot(name)

        o.req("TriggerHotkeyByName", hotkeyName="face_mask_toggle")
        time.sleep(0.5)
        order = [(f["filterName"], f["filterEnabled"])
                 for f in o.req("GetSourceFilterList", sourceName="Face")["filters"]]
        print("Filters after mask off:", order)
        if order != [("Cartoon", True), ("Face Mask", False)]:
            failures.append(f"mask off: expected Cartoon restored, got {order}")

        # ---- Zoom to Mouse on a real screen capture with the real X11 mouse
        def check(cond, msg):
            print(("  ok   " if cond else "  FAIL ") + msg)
            if not cond:
                failures.append(msg)

        subprocess.run(["xdotool", "mousemove", "1500", "100"], env=env, check=True)
        time.sleep(0.3)
        o.req("TriggerHotkeyByName", hotkeyName="toggle_zoom_hotkey")
        time.sleep(1.5)
        crop = next((f for f in o.req("GetSourceFilterList", sourceName="Desktop")["filters"]
                     if f["filterName"] == "obs-zoom-to-mouse-crop"), None)
        cs = crop["filterSettings"] if crop else {}
        # 2560x720 capture, zoom 2 -> 1280x360 crop centred on (1500,100), clamped to the top
        check(cs.get("cx") == 1280 and cs.get("cy") == 360, f"zoom crop size 1280x360 (got {cs.get('cx')}x{cs.get('cy')})")
        check(cs.get("left") == 860 and cs.get("top") == 0, f"zoom follows the real mouse (got {cs.get('left')},{cs.get('top')})")
        o.req("TriggerHotkeyByName", hotkeyName="toggle_zoom_hotkey")
        time.sleep(1.5)
        o.req("TriggerHotkeyByName", hotkeyName="zoom_calibrate_hotkey")
        time.sleep(0.5)

        # ---- Smooth scene switcher
        program = lambda: o.req("GetCurrentProgramScene")["currentProgramSceneName"]

        check(program() == "Main", "starts on Main")
        o.req("TriggerHotkeyByName", hotkeyName="smooth_switcher_next")
        time.sleep(0.15)
        tr = o.req("GetCurrentSceneTransition")
        check(tr["transitionName"] == "Slide", f"Slide used while switching (got {tr['transitionName']})")
        check(tr["transitionSettings"].get("direction") == "left", "next slides left")
        check(tr["transitionDuration"] == 300, f"300ms during the switch (got {tr['transitionDuration']})")
        time.sleep(1.5)
        check(program() == "Scene B", "next -> Scene B")
        tr = o.req("GetCurrentSceneTransition")
        check(tr["transitionName"] == "Fade" and tr["transitionDuration"] == 700,
              f"user's Fade/700ms restored (got {tr['transitionName']}/{tr['transitionDuration']})")

        # two quick presses: the second waits for the first, ends two scenes ahead
        o.req("TriggerHotkeyByName", hotkeyName="smooth_switcher_next")
        time.sleep(0.05)
        o.req("TriggerHotkeyByName", hotkeyName="smooth_switcher_next")
        time.sleep(2.0)
        check(program() == "Main", f"two quick presses B -> C -> Main (got {program()})")

        o.req("TriggerHotkeyByName", hotkeyName="smooth_switcher_prev")
        time.sleep(0.15)
        tr = o.req("GetCurrentSceneTransition")
        check(tr["transitionSettings"].get("direction") == "right", "prev slides right")
        time.sleep(1.5)
        check(program() == "Scene C", f"prev wraps Main -> Scene C (got {program()})")
        o.req("SetCurrentProgramScene", sceneName="Main")
        time.sleep(1.5)

        # ---- Instant replay: hotkey -> save -> plays on "Replay" -> back to Main by itself
        o.req("StartReplayBuffer")
        time.sleep(4)
        o.req("TriggerHotkeyByName", hotkeyName="instant_replay_play")
        deadline = time.time() + 8
        while time.time() < deadline and program() != "Replay":
            time.sleep(0.2)
        check(program() == "Replay", "instant replay switches to the Replay scene")
        f = o.req("GetInputSettings", inputName="Replay Video")["inputSettings"].get("local_file", "")
        check(f.endswith(".mkv") and Path(f).exists(), f"media plays the saved replay ({f})")
        time.sleep(4.5)
        check(program() == "Main", f"back to Main after max_seconds (got {program()})")
        o.req("StopReplayBuffer")

        timer = o.req("GetInputSettings", inputName="Timer")["inputSettings"].get("text")
        print("Timer text:", repr(timer))
        if timer != "":
            failures.append(f"live-timer should blank the text while offline, got {timer!r}")
    finally:
        obs.send_signal(signal.SIGTERM)
        try:
            obs.wait(15)
        except subprocess.TimeoutExpired:
            obs.kill()
        xvfb.terminate()

    logs = sorted((cfg / "logs").glob("*.txt"))
    log = logs[-1].read_text(errors="replace") if logs else ""
    shutil.copy(logs[-1], out / "obs.log") if logs else None

    # XRandR through FFI: the calibrate hotkey must have read the real monitor
    calib = "[zoom-to-mouse] Dùng màn hình tại 0,0 (2560x720, scale 1.00)"
    print(("  ok   " if calib in log else "  FAIL ") + "calibrate reads the monitor from XRandR")
    if calib not in log:
        failures.append("calibrate hotkey did not report the 2560x720 monitor from XRandR")
    if "Monitor (name+os): 0,0 2560x720" not in log:
        failures.append("zoom source monitor not matched with the OS monitor list")
    for p in SCRIPTS:
        if f"Loaded lua script: {p.name}" not in log:
            failures.append(f"{p.name} did not load")
    bad = [l for l in log.splitlines()
           if re.search(r"\[Lua|obs-scripting|scripting", l) and re.search(r"error|attempt to|nil value|stack|Không biên dịch", l, re.I)]
    bad += [l for l in log.splitlines() if re.search(r"shader|effect", l, re.I) and re.search(r"error|fail", l, re.I)]
    failures += bad

    # The filter must visibly change the picture, and the face-only mask must change less of it
    def psnr(a, b):
        r = subprocess.run(["ffmpeg", "-i", str(out / a), "-i", str(out / b), "-lavfi", "psnr", "-f", "null", "-"],
                           capture_output=True, text=True)
        m = re.search(r"average:([\d.]+|inf)", r.stderr)
        return float(m.group(1)) if m else float("inf")
    full, masked = psnr("0-original.png", "1-anime.png"), psnr("0-original.png", "5-anime-face-only.png")
    print(f"PSNR vs original: anime {full:.1f} dB, face-only {masked:.1f} dB")
    if not full < 30:
        failures.append(f"cartoon filter barely changed the image (PSNR {full:.1f} dB)")
    if not masked > full:
        failures.append("face-only mask should leave more of the image untouched than the full filter")
    for name in ("6-mask-hacker", "8-mask-kitsune", "9-mask-neko", "10-mask-image"):
        v = psnr("0-original.png", name + ".png")
        print(f"PSNR vs original: {name} {v:.1f} dB")
        if not v < 40:
            failures.append(f"{name}: mask not drawn (PSNR {v:.1f} dB)")

    for line in log.splitlines():
        if "[Lua" in line:
            print("  log:", line.strip()[:200])

    print("\n" + ("FAIL:\n  " + "\n  ".join(failures) if failures else "OK — no Lua errors in the OBS log"))
    shutil.rmtree(home, ignore_errors=True)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
