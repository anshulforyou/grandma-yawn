#!/usr/bin/env bash
# Manual integration test (needs Hammerspoon running; not run in CI). Checks grandma's animations
# play at their own speed after a day's worth of appearing and disappearing. hs.canvas steps a
# GIF's shared frame counter once per canvas that ever showed it, so the badge and the corner
# bubble, which make a fresh canvas each time they appear, used to speed up the more they were
# used (2026-10-20: the listening yarn and grandma ran several times too fast; see gif.lua).
#
# Loads the repo's modules fresh inside Hammerspoon (the running copy is left alone), makes the
# badge and the bubble appear many times, then counts the frames actually shown for 2 s and
# compares with the GIF's own frame time. Shows the badge and the bubble on screen for about
# 30 s; takes no input. INSTALLED=1 tests the installed modules instead (to see the old bug).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HS=/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SRC="$REPO/src"
[[ -n "${INSTALLED:-}" ]] && SRC="$HOME/.hammerspoon"

cat > "$WORK/test.lua" <<EOF
local out = {}
local function finish()
  local f = io.open("$WORK/result.txt", "w") f:write(table.concat(out, "\n") .. "\n") f:close()
end

-- Fresh copies of the modules from $SRC, without disturbing the running ones.
local saved, savedPath = {}, package.path
for name, mod in pairs(package.loaded) do
  if name:match("^deepgram_dictation") then saved[name] = mod package.loaded[name] = nil end
end
package.path = "$SRC/?.lua;$SRC/?/init.lua;" .. package.path
local ok, err = pcall(function()
  _G.__gifTest = {
    core = require("deepgram_dictation.core"),
    badge = require("deepgram_dictation.badge"),
    overlay = require("deepgram_dictation.screen_overlay"),
  }
end)
for name in pairs(package.loaded) do if name:match("^deepgram_dictation") then package.loaded[name] = nil end end
for name, mod in pairs(saved) do package.loaded[name] = mod end
package.path = savedPath
if not ok then table.insert(out, "ERROR loading modules: " .. tostring(err)) return finish() end
local t = _G.__gifTest

-- Frame time of a GIF in seconds (its first frame's delay).
local function frameTime(name)
  local f = io.open(hs.configdir .. "/deepgram_dictation/badges/" .. name .. ".gif", "rb")
  local data = f:read("a") f:close()
  local at = data:find("\33\249\4", 1, true)
  return string.unpack("<I2", data, at + 4) / 100, select(2, data:gsub("\33\249\4", ""))
end

-- Frames per second actually shown by the image element of canvas c, over 2 s.
local function measure(c, frames, done)
  local index
  for i = 1, #c do
    local id = c[i].id
    if c[i].type == "image" and (c[i].imageAnimates or (type(id) == "string" and id:sub(1, 4) == "gif:")) then index = i end
  end
  if not index then return done(nil) end
  local last, moved = c[index].imageAnimationFrame, 0
  t.poll = hs.timer.doEvery(0.005, function()
    local now = c[index].imageAnimationFrame
    if now ~= last then moved = moved + ((now - last) % frames) last = now end
  end)
  t.wait = hs.timer.doAfter(2, function() t.poll:stop() done(moved / 2) end)
end

local function report(what, name, fps)
  local seconds, frames = frameTime(name)
  local expected = 1 / seconds
  local good = fps and math.abs(fps - expected) <= expected * 0.25
  table.insert(out, string.format("%s %s: %.1f frames/s, its own speed is %.1f",
    good and "ok   " or "FAIL ", what, fps or -1, expected))
  return frames
end

-- Run steps one after another, each calling next when done.
local steps, i = {}, 0
local function nextStep() i = i + 1 if steps[i] then steps[i]() else finish() end end
local function after(s, fn) t.timer = hs.timer.doAfter(s, fn) end

-- 1. The listening yarn after 15 dictations' worth of showing and hiding.
local n = 0
steps[#steps + 1] = function()
  local function cycle()
    n = n + 1
    if n > 15 then return nextStep() end
    t.badge.show("listening")
    after(0.25, function() t.badge.hide(true) after(0.05, cycle) end)
  end
  cycle()
end
steps[#steps + 1] = function()
  t.badge.show("listening")
  after(0.6, function()
    local _, frames = frameTime("listening")
    measure(t.badge.canvasForTest(), frames, function(fps)
      report("listening yarn after 15 appearances", "listening", fps)
      t.badge.hide(true)
      nextStep()
    end)
  end)
end

-- 2. Grandma thinking, after 10 dictations that morphed listening into thinking.
local m = 0
steps[#steps + 1] = function()
  local function cycle()
    m = m + 1
    if m > 10 then return nextStep() end
    t.badge.show("listening")
    after(0.2, function()
      t.badge.show("thinking")
      after(0.5, function() t.badge.hide(true) after(0.05, cycle) end)
    end)
  end
  cycle()
end
steps[#steps + 1] = function()
  t.badge.show("listening")
  after(0.2, function()
    t.badge.show("thinking")
    after(0.8, function()
      local _, frames = frameTime("grandma")
      measure(t.badge.canvasForTest(), frames, function(fps)
        report("grandma thinking after 10 dictations", "grandma", fps)
        t.badge.hide(true)
        nextStep()
      end)
    end)
  end)
end

-- 3. Her corner bubble, after six cards shrank into it (each makes a new bubble).
t.core.CARD_SECONDS = 1 -- this fresh copy only: cards shrink after a second
local k = 0
steps[#steps + 1] = function()
  local function cycle()
    k = k + 1
    if k > 6 then return nextStep() end
    t.overlay.showCard({ text = "Test card " .. k, note = "Test" })
    after(2.2, cycle)
  end
  cycle()
end
steps[#steps + 1] = function()
  local _, frames = frameTime("grandma")
  local bubble = t.overlay.bubbleForTest()
  if not bubble then
    table.insert(out, "FAIL  the corner bubble never appeared")
    return nextStep()
  end
  measure(bubble, frames, function(fps)
    report("grandma in the corner bubble after 6 cards", "grandma", fps)
    nextStep()
  end)
end
steps[#steps + 1] = function()
  t.badge.teardown()
  t.overlay.teardown()
  _G.__gifTest = nil
  nextStep()
end
nextStep()
EOF

( perl -e 'alarm 3; exec @ARGV' "$HS" -q -t 2 -c "hs.timer.doAfter(0.05, function()
    if _G.__gifTestRan == '$WORK' then return end
    _G.__gifTestRan = '$WORK'
    dofile('$WORK/test.lua') end)" >/dev/null 2>&1 || true ) 2>/dev/null
for _ in $(seq 1 90); do [[ -f "$WORK/result.txt" ]] && break; sleep 0.5; done
[[ -f "$WORK/result.txt" ]] || { echo "FAIL: no result from Hammerspoon"; exit 1; }
cat "$WORK/result.txt"
if grep -q -e '^FAIL' -e '^ERROR' "$WORK/result.txt"; then exit 1; fi
echo "PASS"
