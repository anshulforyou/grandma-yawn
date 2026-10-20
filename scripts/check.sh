#!/usr/bin/env bash
# The gate before a push (the pre-push hook runs it; `make hooks` installs the hook) and before an
# install. Runs the unit tests and lint, then the tests that need this Mac: the mic vanishing under
# recorders, grandma's animations keeping their speed, and recording beside a call app. Plays no
# sound and takes no input; about four minutes.
#
# The mic tests switch the mic around, so they never run while another app is using it: the gate
# fails then and says so. Run it again after the call. A skipped test is never a pass.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPPORT="${DEEPGRAM_DICTATION_SUPPORT_DIR:-$HOME/Library/Application Support/deepgram-dictation}"
INSTALLED="$SUPPORT/DeepgramRecorder.app"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$REPO"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mCHECK FAILED: %s\033[0m\n' "$*"; exit 1; }

# Apps other than ours using the mic, by name ("" when none).
mic_users() {
  local bin="$WORK/DeepgramRecorder.app/Contents/MacOS/DeepgramRecorder"
  "$bin" --mic-users | python3 -c '
import json, subprocess, sys
names = []
for user in json.load(sys.stdin):
    name = subprocess.run(["ps", "-o", "comm=", "-p", str(user["pid"])], capture_output=True, text=True).stdout.strip()
    if "DeepgramRecorder" in name or "Hammerspoon" in name:
        continue
    names.append(user.get("bundleID") or name.rsplit("/", 1)[-1] or str(user["pid"]))
print(", ".join(sorted(set(names))))'
}

not_in_call() {
  local users
  users=$(mic_users)
  [[ -z "$users" ]] || fail "the mic is in use by $users. The mic tests would disturb it: run make check after the call."
}

step "Unit tests"
make --no-print-directory test || fail "unit tests"

step "Lint"
make --no-print-directory lint || fail "lint"

pgrep -xq Hammerspoon || fail "Hammerspoon isn't running, and the tests on this Mac need it"

step "Building the recorder from this checkout"
recorder/build.sh "$WORK" >/dev/null || fail "the recorder doesn't build"
BUILT="$WORK/DeepgramRecorder.app"

not_in_call
step "The mic vanishing under recorders (test-mic)"
RECORDER_APP="$BUILT" tests/integration/mic_recovery.sh || fail "test-mic"

step "Grandma's animations keep their speed (test-gif)"
tests/integration/gif_speed.sh || fail "test-gif"

not_in_call
step "Recording in person beside a call app"
SYSTEM_AUDIO=0 PLAY_AUDIO=0 VIA_HAMMERSPOON=1 RECORDER_APP="$BUILT" tests/integration/mic_coexistence.sh \
  || fail "the call test, in person"

# Online recording also captures the computer's audio, which needs the installed recorder's own
# permission. A recorder changed since the last install can't be tested that way without macOS
# asking again, so it is tested on the installed copy only when the two are the same code.
stamp() { cat "$1/Contents/Resources/source.sha256" 2>/dev/null || true; }
if [[ -n "$(stamp "$INSTALLED")" && "$(stamp "$INSTALLED")" == "$(stamp "$BUILT")" ]]; then
  not_in_call
  step "Recording an online meeting beside a call app"
  PLAY_AUDIO=0 tests/integration/mic_coexistence.sh || fail "the call test, online"
else
  echo
  echo "Not run: the online call test. The recorder changed since it was installed; run make install,"
  echo "allow the mic and computer audio when macOS asks, then make test-integration."
fi

printf '\n\033[1;32mCHECK PASSED\033[0m\n'
