#!/usr/bin/env bash
# Chạy test của zoom-to-mouse. Cần LuaJIT (cùng engine Lua mà OBS dùng).
#   Ubuntu/Debian: sudo apt install luajit    macOS: brew install luajit
set -u
cd "$(dirname "$0")"
luajit -bl ../obs-zoom-to-mouse.lua > /dev/null || { echo "SYNTAX ERROR"; exit 1; }
luajit test_zoom.lua
