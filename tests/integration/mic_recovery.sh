#!/usr/bin/env bash
# Manual integration test (needs a Mac with Hammerspoon running and microphone permission; not
# run in CI). Checks the recorder survives the mic changing under it. When AirPods switch into
# call mode (a meeting app takes the mic) their input disappears for a moment and comes back, and
# AVAudioEngine raised an exception while the recorder put its tap back, which aborted it: the
# dictation in progress was lost, and the waiting standby recorder died (2026-10-20, 21 crash
# reports since 2026-10-12). Engines made afterwards in the same process were attached to no
# device and never recorded again, so the recorder now drives the HAL unit itself.
#
#   1. The real thing: a waiting standby, a dictation and a meeting recording all run while the
#      default input's channels vanish and come back eight times (a temporary aggregate device of
#      this Mac's own mic, swapped to the speakers and back; tests/integration/micswitch.swift).
#      All three must stay alive, the standby must still record when started, and both recordings
#      must hold live audio to the end, the meeting's file finalised.
#   2. One switch, shaped like AirPods': the input gone for 0.6 s. A dictation must lose little more.
#   3. Failed starts: DEEPGRAM_RECORDER_FAIL_STARTS makes the mic fail to start a few times, as a
#      mic in the middle of a change does: when a standby is started, and after a change during a
#      dictation and a meeting. Each must keep retrying and recover, and the meeting's file must
#      still be finalised.
#   4. No recorder process died of a signal.
#
# Records from the mic but plays nothing, and puts the default input back afterwards. About a
# minute. RECORDER_APP=<path to DeepgramRecorder.app> tests another build (the installed one shows
# the crash); VERBOSE=1 prints what the recorders said; KEEP=1 keeps the work folder.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HS=/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs
WORK="$(mktemp -d)"

# Runs Lua inside Hammerspoon from a timer. The CLI often never returns, so it gets 3 s, and it
# sometimes delivers a command twice, so each command runs once only (by its number).
RUNS=0
hs_run() {
  RUNS=$((RUNS + 1))
  printf '%s\n' "$1" > "$WORK/cmd$RUNS.lua"
  ( perl -e 'alarm 3; exec @ARGV' "$HS" -q -t 2 -c "hs.timer.doAfter(0.05, function()
      _G.__micRecoveryRan = _G.__micRecoveryRan or {}
      if _G.__micRecoveryRan['$WORK$RUNS'] then return end
      _G.__micRecoveryRan['$WORK$RUNS'] = true
      dofile('$WORK/cmd$RUNS.lua') end)" >/dev/null 2>&1 || true ) 2>/dev/null
}

# shellcheck disable=SC2329 # called by the trap
cleanup() {
  hs_run "for _, t in pairs(_G.__micRecovery or {}) do if t:isRunning() then t:terminate() end end _G.__micRecovery = nil"
  if [[ -x "$WORK/micswitch" ]]; then "$WORK/micswitch" restore >/dev/null 2>&1 || true; fi
  if [[ -n "${KEEP:-}" ]]; then echo "kept $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

if [[ -n "${RECORDER_APP:-}" ]]; then
  BIN="$RECORDER_APP/Contents/MacOS/DeepgramRecorder"
else
  "$REPO/recorder/build.sh" "$WORK" >/dev/null
  BIN="$WORK/DeepgramRecorder.app/Contents/MacOS/DeepgramRecorder"
fi
xcrun swiftc -O -o "$WORK/micswitch" "$REPO/tests/integration/micswitch.swift"

# start NAME BAD_TAPS ARGS...: runs the recorder from Hammerspoon (for its mic permission). Writes
# NAME.out and NAME.err as they arrive, and NAME.exit (exit code or signal) when it ends.
start() {
  local name=$1 bad=$2; shift 2
  local args="" a
  for a in "$@"; do args+="'$a', "; done
  hs_run "
    _G.__micRecovery = _G.__micRecovery or {}
    local function append(file, text) local f = io.open('$WORK/' .. file, 'a') f:write(text or '') f:close() end
    local t = hs.task.new('$BIN', function(code)
        append('$name.t1', string.format('%.3f', hs.timer.secondsSinceEpoch())) append('$name.exit', tostring(code)) end,
      function(_, out, err) append('$name.out', out) append('$name.err', err) return true end, { $args })
    t:setEnvironment({ DEEPGRAM_API_KEY = 'test', DEEPGRAM_RECORDER_FAIL_STARTS = '$bad', HOME = os.getenv('HOME') })
    t:start()
    append('$name.t0', string.format('%.3f', hs.timer.secondsSinceEpoch()))
    _G.__micRecovery['$name'] = t
    append('$name.pid', tostring(t:pid()))"
  for _ in $(seq 1 20); do [[ -s "$WORK/$name.pid" ]] && return; sleep 0.25; done
  echo "FAIL: could not start $name through Hammerspoon"; exit 1
}
signal() { # signal NAME INT|TERM, sent directly (a CLI command can get lost)
  local pid; pid=$(cat "$WORK/$1.pid")
  [[ -f "$WORK/$1.exit" ]] || kill "-$2" "$pid" 2>/dev/null || true
}
send() { hs_run "_G.__micRecovery['$1']:setInput('$2\n')"; }
# shellcheck disable=SC2329 # called through check
alive() { [[ ! -f "$WORK/$1.exit" ]]; }
wait_exit() { for _ in $(seq 1 60); do [[ -f "$WORK/$1.exit" ]] && return 0; sleep 0.25; done; return 1; }
wait_for() { for _ in $(seq 1 12); do grep -q "$2" "$WORK/$1.out" 2>/dev/null && return 0; sleep 0.25; done; return 1; }
wait_recording() { for _ in $(seq 1 40); do grep -q '"recording"' "$1/status.json" 2>/dev/null && return 0; sleep 0.25; done; return 1; }

# "<seconds> <share of exact zeros in the last second>" of a recording (a live mic is never all
# zeros). A meeting's .m4a that wasn't finalised can't be read at all: "0 1".
audio_check() {
  local wav=$1
  if [[ $wav == *.m4a ]]; then
    wav="${1%.m4a}.wav"
    ffmpeg -v quiet -y -i "$1" -ac 1 -ar 16000 "$wav" || { echo "0 1"; return; }
  fi
  python3 - "$wav" <<'PY'
import sys, wave, struct
try:
    w = wave.open(sys.argv[1])
except Exception:
    print("0 1"); sys.exit()
n = w.getnframes(); rate = w.getframerate()
s = struct.unpack("<%dh" % n, w.readframes(n))
tail = s[-rate:] or [0]
print("%.1f %.2f" % (n / rate, sum(1 for x in tail if x == 0) / len(tail)))
PY
}
# Seconds of audio a recorder lost: how long it ran, less what it saved, less its start-up (the
# mic takes up to half a second to deliver) and the stop.
lost() {
  python3 -c "print(round(max(0, $(cat "$WORK/$1.t1") - $(cat "$WORK/$1.t0") - $2 - 0.8), 1))"
}
# shellcheck disable=SC2329 # called through check
at_most() { python3 -c "import sys; sys.exit(not ($1 <= $2))"; }
# shellcheck disable=SC2329 # called through check
at_least() { python3 -c "import sys; sys.exit(not ($1 >= $2 and $3 < 0.95))"; }

fail=0
check() { # check DESCRIPTION COMMAND...
  local what=$1; shift
  if "$@"; then echo "ok    $what"; else echo "FAIL  $what"; fail=1; fi
}
NOWHERE="ws://127.0.0.1:9/v1/listen" # nothing listens there: the saved audio is what gets checked

echo "1. the input vanishes and comes back while recorders wait and record"
start standby "" --stream --standby --save "$WORK/standby.wav"
start dictation "" --stream --url "$NOWHERE" --save "$WORK/dictation.wav"
start meeting "" --out "$WORK/meeting"
# A dictation with the AirPods bridge: a second unit pinned to the built-in mic covers the start.
start bridged "" --stream --url "$NOWHERE" --save "$WORK/bridged.wav" --bridge-uid BuiltInMicrophoneDevice
wait_for standby '"ready"' || true
wait_recording "$WORK/meeting" || true
sleep 1
"$WORK/micswitch" 8 0.4 vanish > "$WORK/switch.json"
check "the input really vanished and came back 8 times" grep -q '"reached": 8' "$WORK/switch.json"
window=$(python3 -c "import json; print(json.load(open('$WORK/switch.json'))['seconds'])")
sleep 3
check "waiting standby survived" alive standby
check "dictation survived" alive dictation
check "meeting recording survived" alive meeting
check "bridged dictation survived" alive bridged
# A standby says {"event":"listening"} once its mic delivers sound; the CLI can drop a command,
# so the start is sent again until it does (a started recorder ignores repeats).
for _ in 1 2 3; do
  send standby "start $NOWHERE"
  wait_for standby '"listening"' && break
done
sleep 2
for name in standby dictation meeting bridged; do signal "$name" INT; done
for name in standby dictation meeting bridged; do wait_exit "$name" || true; done
read -r secs zeros < <(audio_check "$WORK/standby.wav")
check "standby started after the change recorded ${secs}s, live to the end" at_least "$secs" 2 "$zeros"
read -r secs zeros < <(audio_check "$WORK/dictation.wav")
gone=$(lost dictation "$secs")
check "dictation recorded ${secs}s, live to the end, lost ${gone}s in ${window}s of switching" \
  at_least "$secs" 4 "$zeros"
check "  no more lost than the switching took, plus 1.5 s" at_most "$gone" "$(python3 -c "print($window + 1.5)")"
read -r secs zeros < <(audio_check "$WORK/meeting/mic.m4a")
check "meeting's file is finalised, ${secs}s, live to the end" at_least "$secs" 8 "$zeros"
check "bridged dictation handed over from the bridge" grep -q '"handover"' "$WORK/bridged.out"
read -r secs zeros < <(audio_check "$WORK/bridged.wav")
gone=$(lost bridged "$secs")
check "bridged dictation recorded ${secs}s, live to the end, lost ${gone}s" at_least "$secs" 4 "$zeros"
check "  no more lost than the switching took, plus 1.5 s" at_most "$gone" "$(python3 -c "print($window + 1.5)")"

echo "2. one switch, as AirPods make when a call takes the mic"
start single "" --stream --url "$NOWHERE" --save "$WORK/single.wav"
sleep 2
"$WORK/micswitch" 2 0.6 vanish > "$WORK/single.json"
sleep 3
signal single INT
wait_exit single || true
read -r secs zeros < <(audio_check "$WORK/single.wav")
gone=$(lost single "$secs")
check "dictation through one switch recorded ${secs}s, live to the end, lost ${gone}s" at_least "$secs" 3 "$zeros"
check "  lost at most the 0.6 s the input was gone, plus 1.2 s" at_most "$gone" 1.8

echo "3. the mic fails to start a few times"
start standby2 0:3 --stream --standby --save "$WORK/standby2.wav"
wait_for standby2 '"ready"' || true
for _ in 1 2 3; do
  send standby2 "start $NOWHERE"
  wait_for standby2 '"listening"' && break
done
start dictation2 1:3 --stream --url "$NOWHERE" --save "$WORK/dictation2.wav"
start meeting2 1:3 --out "$WORK/meeting2"
wait_recording "$WORK/meeting2" || true
sleep 1.5
"$WORK/micswitch" 2 0.5 > /dev/null
sleep 4
check "standby started although the mic failed to start 3 times" alive standby2
check "dictation survived 3 failed restarts" alive dictation2
check "meeting survived 3 failed restarts" alive meeting2
for name in standby2 dictation2 meeting2; do signal "$name" INT; done
for name in standby2 dictation2 meeting2; do wait_exit "$name" || true; done
check "the starts really failed (standby, dictation, meeting)" \
  test "$(cat "$WORK"/standby2.err "$WORK"/dictation2.err "$WORK"/meeting2.err 2>/dev/null | grep -c 'simulated')" -ge 9
check "each said it restarted the mic" \
  test "$(cat "$WORK"/standby2.err "$WORK"/dictation2.err "$WORK"/meeting2.err 2>/dev/null | grep -c 'mic restarted')" -ge 3
read -r secs zeros < <(audio_check "$WORK/standby2.wav")
check "standby recorded ${secs}s, live to the end" at_least "$secs" 5 "$zeros"
read -r secs zeros < <(audio_check "$WORK/dictation2.wav")
gone=$(lost dictation2 "$secs")
check "dictation kept recording, ${secs}s, live to the end, lost ${gone}s" at_least "$secs" 3 "$zeros"
check "  three failed restarts lost at most 2.5 s" at_most "$gone" 2.5
read -r secs zeros < <(audio_check "$WORK/meeting2/mic.m4a")
check "meeting's file is finalised after failed restarts, ${secs}s, live to the end" at_least "$secs" 5 "$zeros"

echo "4. how every recorder ended"
hung=""
for f in "$WORK"/*.pid; do
  name=$(basename "$f" .pid)
  [[ -f "$WORK/$name.exit" ]] || hung+="$name "
done
check "every recorder stopped when told to ${hung:+(still running: $hung)}" test -z "$hung"
died=""
for f in "$WORK"/*.exit; do
  code=$(cat "$f")
  # 0: finished, 15: stopped by the test (SIGTERM). Anything else (6 is SIGABRT) is a crash.
  [[ $code == 0 || $code == 15 ]] || died+="$(basename "$f" .exit)=$code "
done
check "no recorder died ${died:+(died: $died)}" test -z "$died"

if [[ $fail != 0 || -n "${VERBOSE:-}" ]]; then
  for f in "$WORK"/*.err; do [[ -s "$f" ]] && { echo "--- $(basename "$f")"; grep -v '^$' "$f" | tail -6; }; done
fi
[[ $fail == 0 ]] && echo "PASS"
exit $fail
