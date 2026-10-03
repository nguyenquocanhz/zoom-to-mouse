local H = dofile((debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or ".") .. "/harness.lua")
local env, M = H.load("smooth-scene-switcher.lua")
local obs = obslua

local A = M.add_source("A Intro", "scene", { scene = true })
local B = M.add_source("B Cam", "scene", { scene = true })
local C = M.add_source("C Game", "scene", { scene = true })
local fade = M.add_transition("Fade", "fade_transition")
local slide = M.add_transition("Slide", "slide_transition")
M.current_transition = fade
M.transition_duration = 300
M.current_scene = A
local function stop() M.advance(800, 50) end -- 600ms transition + margin

local settings = H.start(env, M, { next_transition = "Slide", prev_transition = "Slide", duration = 600 })

-- Next: Slide to the left at 600ms, then the user's Fade/300ms comes back
M.hotkeys.smooth_switcher_next(true)
H.check(M.current_scene == B, "next -> B")
H.check(M.current_transition == slide, "slide used during the switch")
H.eq(slide.settings.vals.direction, "left", "next slides left")
H.eq(M.transition_duration, 600, "custom duration")
stop()
H.check(M.current_transition == fade, "fade restored")
H.eq(M.transition_duration, 300, "duration restored")

-- Prev slides right
M.hotkeys.smooth_switcher_prev(true)
H.check(M.current_scene == A, "prev -> A")
H.eq(slide.settings.vals.direction, "right", "prev slides right")
stop()

-- Pressing twice during a transition: queued, lands two scenes ahead, never cuts mid-way
M.hotkeys.smooth_switcher_next(true)
M.hotkeys.smooth_switcher_next(true)
H.check(M.current_scene == B, "second press waits for the first transition")
H.check(M.current_transition == slide, "still sliding")
stop()
H.check(M.current_scene == C, "queued switch runs when the first ends")
H.check(M.current_transition == slide, "user transition not restored while the queue runs")
stop()
H.check(M.current_transition == fade, "restored after the queue")

-- Three quick presses = three scenes ahead (B -> C -> A), counted from the queued target
local D = M.add_source("D Outro", "scene", { scene = true })
M.current_scene = A
M.hotkeys.smooth_switcher_next(true)
M.hotkeys.smooth_switcher_next(true)
M.hotkeys.smooth_switcher_next(true)
stop(); stop()
H.check(M.current_scene == D, "3 presses from A land on D")
M.current_scene = C

-- Wrap around, and no wrap
M.hotkeys.smooth_switcher_next(true)
H.check(M.current_scene == D, "C -> D")
stop()
M.hotkeys.smooth_switcher_next(true)
H.check(M.current_scene == A, "wraps D -> A")
stop()
H.update(env, settings, { wrap = false })
M.hotkeys.smooth_switcher_prev(true)
H.check(M.current_scene == A, "no wrap at the start")
H.update(env, settings, { wrap = true })

-- The queue waits for the transition's real length: not released before 600ms
M.hotkeys.smooth_switcher_next(true)
M.hotkeys.smooth_switcher_next(true)
M.advance(500, 50)
H.check(M.current_scene == B, "queued switch waits while the 600ms transition runs")
M.advance(300, 50)
H.check(M.current_scene == C, "then runs")
M.advance(800, 50)
H.check(M.current_transition == fade, "and the user's transition comes back")

-- Custom order (with a scene that no longer exists)
local function set_order(names)
    local items = {}
    for _, n in ipairs(names) do table.insert(items, { vals = { value = n }, defaults = {} }) end
    settings.arrays.order = { __array = true, items = items }
end
set_order({ "C Game", "Deleted scene", "A Intro" })
env.script_update(settings)
M.current_scene = C
M.hotkeys.smooth_switcher_next(true)
H.check(M.current_scene == A, "custom order C -> A, missing scene skipped")
stop()
M.current_scene = B -- a scene outside the list
M.hotkeys.smooth_switcher_next(true)
H.check(M.current_scene == C, "outside the list -> first entry")
stop()
set_order({})
env.script_update(settings)

-- Keep current transition + duration 0: nothing touched
H.update(env, settings, { next_transition = "<current>", duration = 0 })
M.current_scene = A
M.hotkeys.smooth_switcher_next(true)
H.check(M.current_transition == fade and M.transition_duration == 300, "current transition kept")
stop()

-- Studio mode: goes through preview + transition
H.update(env, settings, { next_transition = "Slide", duration = 600 })
M.studio_mode = true
M.current_scene = A
M.hotkeys.smooth_switcher_next(true)
H.check(M.preview_scene == B and M.current_scene == B, "studio mode uses preview -> program")
stop()
M.studio_mode = false

-- Playlist
M.current_scene = A
M.hotkeys.smooth_switcher_playlist(true)
H.update(env, settings, { playlist_seconds = 5 })
M.advance(5000, 100); stop()
H.check(M.current_scene == B, "playlist step 1")
M.advance(5000, 100); stop()
H.check(M.current_scene == C, "playlist step 2")
M.hotkeys.smooth_switcher_playlist(true)
M.advance(10000, 100)
H.check(M.current_scene == C, "playlist off")

-- Window rules
H.eq(env.parse_rule("Visual Studio Code => B Cam").pattern, "visual studio code", "rule pattern lowercased")
H.eq(env.parse_rule("  Chrome -> A Intro ").scene, "A Intro", "-> also accepted")
H.check(env.parse_rule("no arrow here") == nil, "bad rule rejected")
local title = "main.lua - Visual Studio Code"
env.get_window_title = function() return title end
settings.arrays.window_rules = { __array = true, items = {
    { vals = { value = "Visual Studio Code => A Intro" }, defaults = {} },
    { vals = { value = "bad line" }, defaults = {} },
    { vals = { value = "Game.exe => C Game" }, defaults = {} },
} }
H.update(env, settings, { window_enabled = true })
-- the mock has no real window backend, so drive the poll directly
env.on_window_poll(); stop()
H.check(M.current_scene == A, "window rule switches")
M.current_scene = B -- user switches manually while still in VS Code
env.on_window_poll()
H.check(M.current_scene == B, "same window -> manual switch respected")
title = "GAME.EXE"
env.on_window_poll(); stop()
H.check(M.current_scene == C, "case-insensitive match")
title = "Discord"
env.on_window_poll()
H.check(M.current_scene == C, "no rule -> stay")

-- restore off: the chosen transition stays selected afterwards
H.update(env, settings, { restore = false, next_transition = "Slide" })
M.current_scene = A
M.hotkeys.smooth_switcher_next(true)
stop()
H.check(M.current_transition == slide and M.transition_duration == 600, "restore off keeps Slide/600ms")
M.current_transition, M.transition_duration = fade, 300
H.update(env, settings, { restore = true })

-- Unloading mid-transition restores the user's transition
M.current_scene = A
M.hotkeys.smooth_switcher_next(true)
env.script_unload()
H.check(M.current_transition == fade, "unload restores transition")

H.finish("smooth-scene-switcher.lua", M)
