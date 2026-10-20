#!/usr/bin/env bash
# Manual integration test (needs Hammerspoon running; not run in CI). Checks the daily health check
# end to end inside Hammerspoon: problems recorded with health.record, a slow dictation record and
# a crash report of ours come back as one card, with crashes first; problems already reported, or
# too few to matter, show nothing; and a day must pass before it looks again.
#
# Loads the repo's modules fresh (the running copy is left alone) and points them at a throwaway
# folder, so your real problems, dictations and check schedule aren't touched. Shows a card for a
# few seconds; takes no input.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HS=/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SRC="$REPO/src"
mkdir -p "$WORK/support/dictations" "$WORK/crashes"

# A slow mic start a few minutes ago, a crash report of ours and one of another app's.
cat > "$WORK/support/dictations/$(date -v-2M +%Y-%m-%d_%H-%M-%S)-000.json" <<'EOF'
{ "micMs": 2557, "device": "AirPods", "cleanup": { "status": "ok" } }
EOF
# Named for a minute ago, as macOS names them (the check dates crashes by the name).
STAMP=$(date -v-1M +%Y-%m-%d-%H%M%S)
WHEN=$(date -v-1M "+on %b %-d at %H:%M")
echo '{"exception" : {"type":"EXC_CRASH","signal":"SIGABRT"}}' > "$WORK/crashes/DeepgramRecorder-$STAMP.ips"
echo '{}' > "$WORK/crashes/Brave Browser-$STAMP.ips"
# A report macOS writes only after a check has run, for a crash from before that check.
LATE=$(date -v-5M +%Y-%m-%d-%H%M%S)

cat > "$WORK/test.lua" <<EOF
local out = {}
local function check(ok, what) table.insert(out, (ok and "ok    " or "FAIL  ") .. what) end
local function finish()
  local f = io.open("$WORK/result.txt", "w") f:write(table.concat(out, "\n") .. "\n") f:close()
end

local saved, savedPath = {}, package.path
for name, mod in pairs(package.loaded) do
  if name:match("^deepgram_dictation") then saved[name] = mod package.loaded[name] = nil end
end
package.path = "$SRC/?.lua;$SRC/?/init.lua;" .. package.path
local ok, err = pcall(function()
  _G.__healthTest = {
    health = require("deepgram_dictation.health"),
    overlay = require("deepgram_dictation.screen_overlay"),
  }
end)
for name in pairs(package.loaded) do if name:match("^deepgram_dictation") then package.loaded[name] = nil end end
for name, mod in pairs(saved) do package.loaded[name] = mod end
package.path = savedPath
if not ok then table.insert(out, "ERROR loading modules: " .. tostring(err)) return finish() end

local t = _G.__healthTest
local health, overlay = t.health, t.overlay
health.dir = "$WORK/support"
overlay.setup()
local shown = {}
local showCard = overlay.showCard
overlay.showCard = function(item) table.insert(shown, item) return showCard(item) end

-- A slow mic start alone is not worth a card: nothing but the crash report should say anything.
health.record("empty-recording", "AirPods")
health.record("slow-mic", "one more")
local r = health.check(true, "$WORK/crashes")
check(r ~= nil and #shown == 1, "a card was shown")
check(overlay.cardOpen(), "the card is on screen")
local item = shown[1] or { text = {} }
check(item.text.gist == "The recorder crashed once, and 1 other problem since I last looked.",
  "gist: " .. tostring(item.text.gist))
check(tostring(item.text.body):find("- The recorder crashed, once. Last: SIGABRT $WHEN", 1, true) == 1,
  "crash first in the body")
check(tostring(item.text.body):find("The mic recorded nothing, once", 1, true) ~= nil, "the empty recording is listed")
check(not tostring(item.text.body):find("slow", 1, true), "two slow mic starts are not listed")
check(not tostring(item.text.body):find("Brave", 1, true), "another app's crash is not listed")
check(hs.fs.attributes("$WORK/support/problems") ~= nil, "problems are written to the given folder")

-- Not due again for a day, and nothing new means nothing to say.
check(health.check(false, "$WORK/crashes") == nil and #shown == 1, "not due again until a day has passed")
hs.timer.usleep(1100000)
check(health.check(true, "$WORK/crashes") == nil and #shown == 1, "what was reported isn't reported again")

-- A report written late still gets told, once.
local late = io.open("$WORK/crashes/DeepgramRecorder-$LATE.ips", "w")
late:write('{"exception" : {"signal":"SIGSEGV"}}') late:close()
hs.timer.usleep(1100000)
local r2 = health.check(true, "$WORK/crashes")
check(r2 ~= nil and #shown == 2 and tostring(r2.body):find("SIGSEGV", 1, true) ~= nil,
  "a crash report written after the check is still told")
check(r2 ~= nil and not tostring(r2.body):find("SIGABRT", 1, true), "the earlier crash isn't told again")
hs.timer.usleep(1100000)
check(health.check(true, "$WORK/crashes") == nil and #shown == 2, "the late one isn't told twice")

t.timer = hs.timer.doAfter(3, function()
  overlay.teardown()
  _G.__healthTest = nil
  finish()
end)
EOF

( perl -e 'alarm 3; exec @ARGV' "$HS" -q -t 2 -c "hs.timer.doAfter(0.05, function()
    if _G.__healthTestRan == '$WORK' then return end
    _G.__healthTestRan = '$WORK'
    dofile('$WORK/test.lua') end)" >/dev/null 2>&1 || true ) 2>/dev/null
for _ in $(seq 1 40); do [[ -f "$WORK/result.txt" ]] && break; sleep 0.5; done
[[ -f "$WORK/result.txt" ]] || { echo "FAIL: no result from Hammerspoon"; exit 1; }
cat "$WORK/result.txt"
if grep -q -e '^FAIL' -e '^ERROR' "$WORK/result.txt"; then exit 1; fi
echo "PASS"
