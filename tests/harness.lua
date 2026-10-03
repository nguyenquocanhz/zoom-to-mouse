-- Shared helpers for the script tests. Each test file runs in its own LuaJIT process
-- (run.sh) because OBS gives every script its own Lua state, and ffi.cdef can't be repeated.

local dir = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
package.path = dir .. "/?.lua;" .. package.path

local H = { passed = 0, failed = 0 }

-- Real libobs/frontend API names the scripts may probe for with `obs.X or fallback`.
-- Seeing them in the unknown list is expected, not a typo.
H.known_optional = {
    obs_sceneitem_get_info = true, obs_sceneitem_set_info = true,
}

function H.load(script)
    local M = require("mock_obs")
    M.install()
    local env = setmetatable({}, { __index = _G })
    -- obs-zoom-to-mouse.lua lives at the repo root, every other script in plugins/
    local path = dir .. "/../plugins/" .. script
    if script == "obs-zoom-to-mouse.lua" then
        path = dir .. "/../" .. script
    end
    local chunk = assert(loadfile(path))
    setfenv(chunk, env)
    chunk()
    return env, M
end

function H.check(cond, msg)
    if cond then
        H.passed = H.passed + 1
    else
        H.failed = H.failed + 1
        print("  FAIL: " .. msg)
        print(debug.traceback("", 2))
    end
end

function H.eq(a, b, msg)
    H.check(a == b, msg .. " (expected " .. tostring(b) .. ", got " .. tostring(a) .. ")")
end

-- defaults -> overrides -> load -> update -> properties (and poke every modified callback)
function H.start(env, M, overrides)
    local settings = M.settings()
    if env.script_defaults then env.script_defaults(settings) end
    for k, v in pairs(overrides or {}) do settings.vals[k] = v end
    H.check(type(env.script_description()) == "string", "script_description returns a string")
    if env.script_load then env.script_load(settings) end
    if env.script_update then env.script_update(settings) end
    local props = env.script_properties()
    for _, p in pairs(props.props) do
        if p.modified then p.modified(props, p, settings) end
    end
    if env.script_save then env.script_save(settings) end
    return settings, props
end

function H.update(env, settings, changes)
    for k, v in pairs(changes) do settings.vals[k] = v end
    env.script_update(settings)
end

function H.finish(name, M)
    local unknown = {}
    for k in pairs(M.unknown) do
        if not H.known_optional[k] then table.insert(unknown, k) end
    end
    table.sort(unknown)
    if #unknown > 0 then
        H.failed = H.failed + 1
        print("  FAIL: API names not modelled by mock (check they exist in OBS): " .. table.concat(unknown, ", "))
    end
    print(string.format("%-28s %d passed, %d failed", name, H.passed, H.failed))
    os.exit(H.failed == 0 and 0 or 1)
end

return H
