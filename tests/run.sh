#!/usr/bin/env bash
# Chạy toàn bộ test của obs-lua. Cần LuaJIT (cùng engine Lua mà OBS dùng).
#   Ubuntu/Debian: sudo apt install luajit    macOS: brew install luajit
set -u
cd "$(dirname "$0")"
status=0
for f in ../obs-zoom-to-mouse.lua ../plugins/*.lua; do
    luajit -bl "$f" > /dev/null || { echo "SYNTAX ERROR: $f"; status=1; }
done
for t in test_*.lua; do
    luajit "$t" || status=1
done
exit $status
