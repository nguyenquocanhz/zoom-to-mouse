local H = dofile((debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or ".") .. "/harness.lua")
local env, M = H.load("text-ticker.lua")

local text = M.add_source("Ticker", "text_gdiplus_v3")
local function t() return text.settings.vals.text end

local file = os.tmpname()
local f = io.open(file, "w")
f:write("\239\187\191Từ file 1\n\n  Từ file 2  \n")
f:close()

local settings = M.settings()
env.script_defaults(settings)
settings.vals.text_source = "Ticker"
settings.vals.interval = 5
settings.vals.file_path = file
settings.vals.template = "📢 {msg}"
settings.arrays.messages = { __array = true, items = {
    { vals = { value = "Follow kênh nhé" }, defaults = {} },
    { vals = { value = "Giảm 100% hôm nay" }, defaults = {} },
} }
env.script_load(settings)
env.script_update(settings)
env.script_properties()

H.eq(t(), "📢 Follow kênh nhé", "first message")
M.advance(5000, 100)
H.eq(t(), "📢 Giảm 100% hôm nay", "rotates (and % is safe)")
M.advance(5000, 100)
H.eq(t(), "📢 Từ file 1", "reads file, strips BOM")
M.advance(5000, 100)
H.eq(t(), "📢 Từ file 2", "trims and skips blank lines")
M.advance(5000, 100)
H.eq(t(), "📢 Follow kênh nhé", "wraps around")
M.hotkeys.text_ticker_next(true)
H.eq(t(), "📢 Giảm 100% hôm nay", "next hotkey")

settings.vals.shuffle = true
env.script_update(settings)
local seen, prev, repeats = {}, nil, 0
for _ = 1, 40 do
    M.advance(5000, 100)
    seen[t()] = true
    if t() == prev then repeats = repeats + 1 end
    prev = t()
end
local n = 0
for _ in pairs(seen) do n = n + 1 end
H.eq(n, 4, "shuffle shows every message")
H.eq(repeats, 0, "shuffle never repeats back to back")

settings.vals.shuffle = false
settings.vals.mode = "join"
env.script_update(settings)
H.eq(t(), "📢 Follow kênh nhé   •   Giảm 100% hôm nay   •   Từ file 1   •   Từ file 2", "join mode")

os.remove(file)
env.script_unload()
H.finish("text-ticker.lua", M)
