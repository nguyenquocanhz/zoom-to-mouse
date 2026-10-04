#!/usr/bin/env python3
"""Quay video Zoom to Mouse trong OBS THẬT, điều khiển bằng chuột/phím THẬT (xdotool).

Màn hình ảo (Xvfb) hiện một ảnh lưới có tọa độ; OBS capture màn hình đó (Screen Capture XSHM),
script zoom-to-mouse được load với phím F9 (zoom), F10 (zoom thêm), F11 (zoom bớt) và Auto zoom
on click. xdotool bấm phím / di chuột / click như người dùng; OBS quay lại thành video.
Mỗi bước còn đọc thông số crop filter qua obs-websocket để kiểm tra bằng số.

Cần: obs-studio, Xvfb, ffmpeg (ffplay), xdotool, pip install websocket-client

    python3 tests/demo_record.py out/        # -> out/zoom-demo.mp4 + kết quả từng bước
"""
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import websocket

ROOT = Path(__file__).resolve().parent.parent
W, H = 1280, 720
DISPLAY = ":97"
MODE = os.environ.get("ZOOM_MODE", "smooth")  # smooth | crop — record both to compare


def make_background(path: Path):
    """Lưới 160px, mỗi ô ghi tọa độ — nhìn video là biết đang zoom vào đâu."""
    draw = ["drawgrid=w=160:h=120:t=2:c=0x3a4a6a"]
    for gx in range(0, W, 160):
        for gy in range(0, H, 120):
            draw.append(f"drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf:"
                        f"text='{gx},{gy}':x={gx + 10}:y={gy + 10}:fontsize=22:fontcolor=0xc8d3f5")
    draw.append("drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf:"
                "text='function zoom_to_mouse()':x=420:y=320:fontsize=40:fontcolor=0xffc777")
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", f"color=c=0x1e2030:s={W}x{H}",
                    "-vf", ",".join(draw), "-frames:v", "1", str(path)], check=True)


def write_config(home: Path, rec: Path):
    cfg = home / ".config" / "obs-studio"
    (cfg / "basic" / "profiles" / "Demo").mkdir(parents=True)
    (cfg / "basic" / "scenes").mkdir(parents=True)
    (cfg / "plugin_config" / "obs-websocket").mkdir(parents=True)
    (cfg / "global.ini").write_text(
        "[General]\nFirstRun=true\n"
        "[Basic]\nProfile=Demo\nProfileDir=Demo\nSceneCollection=Demo\nSceneCollectionFile=Demo\n"
        "[OBSWebSocket]\nFirstLoad=false\nServerEnabled=true\nServerPort=4456\nAuthRequired=false\n")
    (cfg / "plugin_config" / "obs-websocket" / "config.json").write_text(json.dumps({
        "alerts_enabled": False, "auth_required": False, "first_load": False,
        "server_enabled": True, "server_password": "", "server_port": 4456}))
    (cfg / "basic" / "profiles" / "Demo" / "basic.ini").write_text(
        f"[General]\nName=Demo\n[Video]\nBaseCX={W}\nBaseCY={H}\nOutputCX={W}\nOutputCY={H}\nFPSType=0\nFPSCommon=30\n"
        f"[Output]\nMode=Simple\n[SimpleOutput]\nFilePath={rec}\nRecFormat2=mkv\nRecQuality=Stream\n"
        "StreamEncoder=x264\nVBitrate=6000\n")
    key = lambda k: [{"key": k}]
    scene = {
        "name": "Demo", "current_scene": "Main", "current_program_scene": "Main",
        "scene_order": [{"name": "Main"}],
        "sources": [
            {"id": "xshm_input", "versioned_id": "xshm_input", "name": "Desktop",
             "settings": {"screen": 0, "show_cursor": True}},
            {"id": "text_ft2_source", "versioned_id": "text_ft2_source_v2", "name": "Caption",
             "settings": {"text": "", "outline": True, "drop_shadow": True,
                          "font": {"face": "DejaVu Sans", "size": 34, "style": "Bold", "flags": 1}}},
            {"id": "scene", "versioned_id": "scene", "name": "Main", "settings": {"id_counter": 2, "items": [
                {"name": "Desktop", "id": 1, "visible": True, "pos": {"x": 0, "y": 0}, "scale": {"x": 1, "y": 1},
                 "align": 5, "bounds_type": 2, "bounds_align": 0, "bounds": {"x": W, "y": H}},
                {"name": "Caption", "id": 2, "visible": True, "pos": {"x": 30, "y": H - 70},
                 "scale": {"x": 1, "y": 1}, "align": 5},
            ]}},
        ],
        "modules": {"scripts-tool": [{"path": str(ROOT / "obs-zoom-to-mouse.lua"), "settings": {
            "source": "Desktop", "click_zoom": True, "zoom_mode": MODE, "auto_zoom_out_delay": 2.0, "debug_logs": False,
            "obs_zoom_to_mouse.hotkey.zoom": key("OBS_KEY_F9"),
            "obs_zoom_to_mouse.hotkey.zoom_more": key("OBS_KEY_F10"),
            "obs_zoom_to_mouse.hotkey.zoom_less": key("OBS_KEY_F11"),
        }}]},
    }
    (cfg / "basic" / "scenes" / "Demo.json").write_text(json.dumps(scene))
    return cfg


class Obs:
    def __init__(self):
        deadline = time.time() + 90
        while True:
            try:
                self.ws = websocket.create_connection("ws://127.0.0.1:4456", timeout=10)
                break
            except OSError:
                if time.time() > deadline:
                    raise
                time.sleep(1)
        json.loads(self.ws.recv())
        self.ws.send(json.dumps({"op": 1, "d": {"rpcVersion": 1, "eventSubscriptions": 0}}))
        json.loads(self.ws.recv())
        self.n = 0
        while True:
            try:
                self.req("GetVersion")
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
                if not msg["d"]["requestStatus"]["result"]:
                    raise RuntimeError(f"{kind}: {msg['d']['requestStatus']}")
                return msg["d"].get("responseData", {})


def main():
    out = Path(sys.argv[1]).resolve()
    out.mkdir(parents=True, exist_ok=True)
    home = Path(tempfile.mkdtemp(prefix="obs-demo-"))
    rec = home / "rec"
    rec.mkdir()
    cfg = write_config(home, rec)
    bg = home / "bg.png"
    make_background(bg)

    env = dict(os.environ, HOME=str(home), DISPLAY=DISPLAY, LIBGL_ALWAYS_SOFTWARE="1")
    procs = [subprocess.Popen(["Xvfb", DISPLAY, "-screen", "0", f"{W}x{H}x24"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)]
    time.sleep(1)
    procs.append(subprocess.Popen(["obs", "--disable-shutdown-check", "--disable-updater", "--multi"],
                                  env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    results = []
    try:
        o = Obs()
        # The background goes on top of the OBS window (no window manager: last mapped is on top)
        procs.append(subprocess.Popen(["ffplay", "-loglevel", "quiet", "-noborder", "-left", "0", "-top", "0",
                                       "-x", str(W), "-y", str(H), "-loop", "0", str(bg)],
                                      env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        time.sleep(3)

        xdo = lambda *a: subprocess.run(["xdotool", *map(str, a)], env=env, check=True)
        # Human-like presses: when OBS isn't the focused window it polls the keyboard/mouse state on X11,
        # and xdotool's default 0 ms press/release falls between two polls. Fingers hold ~60-150 ms.
        def press(key):
            xdo("keydown", key)
            time.sleep(0.12)
            xdo("keyup", key)

        def click():
            xdo("mousedown", 1)
            time.sleep(0.12)
            xdo("mouseup", 1)

        caption = lambda t: o.req("SetInputSettings", inputName="Caption", inputSettings={"text": t})
        pos = [0, 0]

        def view_x():
            for f in o.req("GetSourceFilterList", sourceName="Desktop")["filters"]:
                st = f["filterSettings"]
                if f["filterName"] == "obs-zoom-to-mouse-view":
                    return st.get("x", 0)
                if f["filterName"] == "obs-zoom-to-mouse-crop":
                    return st.get("left", 0)
            return 0

        def glide(x, y, seconds, samples=None):
            steps = max(1, int(seconds * 30))
            x0, y0 = pos
            for i in range(1, steps + 1):
                xdo("mousemove", int(x0 + (x - x0) * i / steps), int(y0 + (y - y0) * i / steps))
                time.sleep(seconds / steps)
                if samples is not None:
                    samples.append(view_x())
            pos[:] = [x, y]

        def crop():
            """View rectangle (x, y, w, h) of the zoom filter, rounded to whole pixels."""
            for f in o.req("GetSourceFilterList", sourceName="Desktop")["filters"]:
                s = f["filterSettings"]
                if f["filterName"] == "obs-zoom-to-mouse-view":
                    return tuple(int(round(s.get(k, 0))) for k in ("x", "y", "w", "h"))
                if f["filterName"] == "obs-zoom-to-mouse-crop":
                    return s.get("left"), s.get("top"), s.get("cx"), s.get("cy")
            return None

        def check(name, cond, detail):
            results.append((name, cond, detail))
            print(("  ok   " if cond else "  FAIL ") + f"{name}: {detail}")

        xdo("mousemove", 200, 150)
        pos[:] = [200, 150]
        caption(f"Zoom to Mouse v1.3.0 — chế độ {MODE.upper()} — chuột & phím THẬT")
        # Keep the background above any OBS window (e.g. the Script Log) for the whole recording
        subprocess.run(["xdotool", "search", "--class", "ffplay", "windowraise"], env=env)
        o.req("StartRecord")
        time.sleep(2.5)

        caption("Bấm F9 → zoom vào chỗ con trỏ (200,150)")
        press("F9")
        time.sleep(1.8)
        c = crop()
        check("F9 zoom in", c is not None and c[2] == 640 and c[0] == 0 and c[1] == 0,
              f"crop {c} (640x360, kẹp ở góc trên trái vì chuột ở 200,150)")

        caption("Di chuột → khung bám theo")
        glide(1000, 220, 2.0)
        glide(1000, 560, 1.5)
        time.sleep(1.2)
        c = crop()
        # Follow has a "safe zone": the view only moves when the mouse nears its edge (Follow Border),
        # so the exact position depends on the path. What must hold: the mouse stays in view.
        inside = lambda c, x, y: c is not None and c[0] <= x <= c[0] + c[2] and c[1] <= y <= c[1] + c[3]
        check("follow", inside(c, 1000, 560) and c[2] == 640, f"crop {c} chứa chuột (1000,560)")
        glide(420, 420, 2.0)
        time.sleep(1.5)
        c = crop()
        check("follow back", inside(c, 420, 420), f"crop {c} chứa chuột (420,420)")

        caption("Kéo chuột thật chậm sang phải → khung trượt theo")
        samples = []
        glide(900, 420, 5.0, samples)
        time.sleep(1.0)
        c = crop()
        check("slow pan", inside(c, 900, 420), f"crop {c} chứa chuột (900,420)")
        # Smoothness while the view is moving: frozen samples vs. samples that moved
        moving = [b - a for a, b in zip(samples, samples[1:])]
        first = next((i for i, d in enumerate(moving) if abs(d) > 0.01), len(moving))
        moving = moving[first:]
        frozen = sum(1 for d in moving if abs(d) < 0.01)
        print(f"  pan  {MODE}: {len(moving)} mẫu khi khung đang trượt, đứng yên {frozen}, "
              f"bước lớn nhất {max(moving, default=0):.2f}px, nhỏ nhất {min(moving, default=0):.2f}px")
        (out / f"pan-{MODE}.json").write_text(json.dumps(samples))

        caption("F10 → zoom thêm (2.5x)")
        press("F10")
        time.sleep(1.8)
        c = crop()
        check("F10 zoom more", c is not None and c[2] == 512, f"crop {c} (1280/2.5 = 512)")

        caption("F11 → zoom bớt (2x)")
        press("F11")
        time.sleep(1.8)
        c = crop()
        check("F11 zoom less", c is not None and c[2] == 640, f"crop {c} (về 640)")

        caption("Bấm F9 lần nữa → zoom ra")
        press("F9")
        time.sleep(1.8)
        c = crop()
        check("F9 zoom out", c is not None and c[2] == 1280, f"crop {c} (về toàn màn hình)")

        caption("Auto zoom on click → click chuột trái ở (950,450)")
        glide(950, 450, 1.0)
        time.sleep(0.5)
        click()
        time.sleep(1.5)
        c = crop()
        check("click zoom", c is not None and c[2] == 640 and c[0] == 630 and c[1] == 270,
              f"crop {c} (click 950,450 → 630,270)")

        caption("Để yên chuột 2 giây → tự zoom ra")
        time.sleep(3.5)
        c = crop()
        check("auto zoom out", c is not None and c[2] == 1280, f"crop {c} (về toàn màn hình)")

        caption("Xong ✔")
        time.sleep(1.5)
        path = o.req("StopRecord")["outputPath"]
        time.sleep(2)
        name = f"zoom-demo-{MODE}.mp4"
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", path, "-c", "copy", "-movflags", "+faststart",
                        str(out / name)], check=True)
        print("video:", out / name)

        # The picture itself must not be black (a 0x0 filter blanks the whole capture while every
        # number above still looks right). Average brightness at 3 s (normal) and 6 s (zoomed).
        for t in (3, 6):
            r = subprocess.run(["ffmpeg", "-ss", str(t), "-i", str(out / name), "-frames:v", "1", "-vf",
                                "signalstats,metadata=print:key=lavfi.signalstats.YAVG", "-f", "null", "-"],
                               capture_output=True, text=True)
            yavg = float(r.stderr.split("YAVG=")[-1].split()[0]) if "YAVG=" in r.stderr else 0
            check(f"video not black @{t}s", yavg > 25, f"độ sáng trung bình {yavg:.1f} (đen ≈ 16)")
    finally:
        for p in reversed(procs):
            p.send_signal(signal.SIGTERM)
            try:
                p.wait(15)
            except subprocess.TimeoutExpired:
                p.kill()
        logs = sorted((cfg / "logs").glob("*.txt"))
        if logs:
            shutil.copy(logs[-1], out / "obs.log")
        shutil.rmtree(home, ignore_errors=True)

    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)}/{len(results)} bước đúng")
    sys.exit(1 if failed or not results else 0)


if __name__ == "__main__":
    main()
