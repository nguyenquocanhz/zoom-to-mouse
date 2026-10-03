local H = dofile((debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or ".") .. "/harness.lua")
local env, M = H.load("chapter-markers.lua")
local obs = obslua

local tmp = os.tmpname()
os.remove(tmp)
os.execute("mkdir -p '" .. tmp .. "'")
local label = M.add_source("Chapter Title", "text_gdiplus_v3")

local settings = M.settings()
env.script_defaults(settings)
settings.vals.output_dir = tmp
settings.vals.text_source = "Chapter Title"
settings.arrays.titles = { __array = true, items = {
    { vals = { value = "Cài đặt OBS" }, defaults = {} },
    { vals = { value = "Demo" }, defaults = {} },
} }
env.script_load(settings)
env.script_update(settings)
env.script_properties()

H.eq(env.format_ts(5), "00:05", "mm:ss")
H.eq(env.format_ts(3725), "1:02:05", "h:mm:ss")

-- Not recording -> nothing happens
M.hotkeys.chapter_markers_add(true)

M.recording = true
M.fire(obs.OBS_FRONTEND_EVENT_RECORDING_STARTED)
M.advance(192000, 1000)
M.hotkeys.chapter_markers_add(true)
H.eq(label.settings.vals.text, "Cài đặt OBS", "text source shows current chapter")
M.fire(obs.OBS_FRONTEND_EVENT_RECORDING_PAUSED)
M.advance(60000, 1000) -- paused minute must not count
M.fire(obs.OBS_FRONTEND_EVENT_RECORDING_UNPAUSED)
M.advance(513000, 1000)
M.hotkeys.chapter_markers_add(true)
M.advance(30000, 1000)
M.hotkeys.chapter_markers_add(true)
M.hotkeys.chapter_markers_undo(true)
M.hotkeys.chapter_markers_add(true)
M.fire(obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED)

local files = io.popen("ls '" .. tmp .. "'"):read("*a")
local name = files:match("(chapters_[%d%-_]+%.txt)")
H.check(name ~= nil, "chapters file written")
local content = name and io.open(tmp .. "/" .. name):read("*a") or ""
H.eq(content, "00:00 Intro\n03:12 Cài đặt OBS\n11:45 Demo\n12:15 Chapter 4\n", "YouTube chapter file")
H.eq(#M.chapters, 4, "native chapters sent to Hybrid MP4 (undo can't remove those)")

os.execute("rm -rf '" .. tmp .. "'")
env.script_unload()
H.finish("chapter-markers.lua", M)
