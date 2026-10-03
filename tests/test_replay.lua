local H = dofile((debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or ".") .. "/harness.lua")
local env, M = H.load("instant-replay.lua")
local obs = obslua

local media = M.add_source("Replay Video", "ffmpeg_source")
local game = M.add_source("Game", "scene", { scene = true })
local replay = M.add_source("Replay", "scene", { scene = true })
M.current_scene = game

H.start(env, M, { media_source = "Replay Video", replay_scene = "Replay", speed_percent = 50, max_seconds = 10 })

-- Buffer off -> auto start, no save yet
M.hotkeys.instant_replay_play(true)
H.eq(M.calls.obs_frontend_replay_buffer_start, 1, "replay buffer auto started")
H.eq(M.calls.obs_frontend_replay_buffer_save, nil, "no save while buffer was off")

M.hotkeys.instant_replay_play(true)
H.eq(M.calls.obs_frontend_replay_buffer_save, 1, "save requested")
M.advance(1000, 50)
H.check(M.current_scene == game, "nothing until OBS has written the file")
M.last_replay = "/videos/Replay 2026-10-03.mkv"
M.advance(250, 50)
H.check(M.current_scene == replay, "switched to replay scene")
H.eq(media.settings.vals.local_file, M.last_replay, "media points at the saved file")
H.eq(media.settings.vals.speed_percent, 50, "slow motion")
H.eq(media.media_state, 1, "media restarted")

M.advance(3000, 50)
H.check(M.current_scene == replay, "still playing")
media.media_state = obs.OBS_MEDIA_STATE_ENDED
M.advance(500, 50)
H.check(M.current_scene == game, "back to game when the clip ends")

-- Cap by max_seconds. The previous replay is still OBS's "last replay" until the new one is
-- written: it must not be played again in the meantime.
M.hotkeys.instant_replay_play(true)
M.advance(1000, 50)
H.check(M.current_scene == game, "old replay not replayed while the new one is being saved")
M.last_replay = "/videos/Replay 2.mkv"
M.advance(250, 50)
M.advance(10500, 50)
H.check(M.current_scene == game, "back after max_seconds")

-- The user moved on during the replay: don't yank them back at the end
local other = M.add_source("Chat", "scene", { scene = true })
M.hotkeys.instant_replay_play(true)
M.last_replay = "/videos/Replay 3.mkv"
M.advance(250, 50)
M.advance(2000, 50)
M.api.obs_frontend_set_current_scene(other)
M.advance(10000, 50)
H.check(M.current_scene == other, "stays on the scene the user picked")
M.api.obs_frontend_set_current_scene(game)

-- Right after restart a media source can still report the previous clip as ended
media.restart_state = obs.OBS_MEDIA_STATE_ENDED
M.hotkeys.instant_replay_play(true)
M.last_replay = "/videos/Replay 4.mkv"
M.advance(250, 50)
M.advance(800, 50)
media.media_state = obs.OBS_MEDIA_STATE_PLAYING
M.advance(1200, 50)
H.check(M.current_scene == replay, "stale 'ended' state at start doesn't cut the replay")
media.media_state = obs.OBS_MEDIA_STATE_ENDED
M.advance(500, 50)
H.check(M.current_scene == game, "real end returns")

-- A replay saved by someone else (OBS button) is ignored
M.last_replay = "/videos/Saved by hand.mkv"
M.advance(2000, 50)
H.check(M.current_scene == game, "ignores saves it didn't request")

-- OBS never writes the file -> give up quietly instead of polling forever
M.hotkeys.instant_replay_play(true)
M.advance(16000, 100)
H.check(M.timers[env.on_save_poll] == nil, "save poll stops after the timeout")
H.check(M.current_scene == game, "no switch without a file")

env.script_unload()
H.finish("instant-replay.lua", M)
