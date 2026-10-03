local H = dofile((debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or ".") .. "/harness.lua")
local env, M = H.load("afk-scene-switcher.lua")

local game = M.add_source("Game", "scene", { scene = true })
local brb = M.add_source("BRB", "scene", { scene = true })
local chat = M.add_source("Just Chatting", "scene", { scene = true })
M.current_scene = game

local idle = 0
env.get_idle_seconds = function() return idle end

local settings = H.start(env, M, { brb_scene = "BRB", idle_minutes = 1 })
H.check(M.timers[env.on_poll] ~= nil, "poll timer running")

idle = 30; M.advance(1000)
H.check(M.current_scene == game, "not idle long enough")
idle = 61; M.advance(1000)
H.check(M.current_scene == brb, "switched to BRB when idle")
idle = 0.5; M.advance(1000)
H.check(M.current_scene == game, "back to previous scene on activity")

-- Manual scene change while on BRB is respected
idle = 120; M.advance(1000)
H.check(M.current_scene == brb, "BRB again")
M.api.obs_frontend_set_current_scene(chat)
idle = 0.1; M.advance(1000)
H.check(M.current_scene == chat, "manual switch is not overridden")

-- Only when live
H.update(env, settings, { only_when_live = true })
idle = 120; M.advance(1000)
H.check(M.current_scene == chat, "offline -> no switch")
M.streaming = true; M.advance(1000)
H.check(M.current_scene == brb, "live -> switch")

-- Hotkey disables
idle = 0; M.advance(1000)
M.hotkeys.afk_switcher_toggle(true)
idle = 999; M.advance(1000)
H.check(M.current_scene == chat, "disabled by hotkey")

env.script_unload()
H.finish("afk-scene-switcher.lua", M)
