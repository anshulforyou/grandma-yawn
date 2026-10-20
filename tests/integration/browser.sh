# Sourced by the screen tests. Drives the browser through AppleScript, not `open`: `open` can put
# the new window in another Space, where grandma never sees it and works on whatever page is in
# front instead. Pages are found by their title prefix ("FILL ", "WORK ").
# shellcheck shell=bash

APP="${BROWSER_APP:-Brave Browser}"

# Opens file `$1` in a new front window and waits until a page titled `$2`... is in front.
page_open() {
  osascript -e "tell application \"$APP\"
    make new window
    set URL of active tab of front window to \"file://$1\"
    activate
  end tell" >/dev/null
  local front=""
  for _ in $(seq 1 20); do
    sleep 0.5
    front=$(page_front_title)
    [[ "$front" == "$2"* ]] && return 0
  done
  echo "FAIL: the test page never came to the front (front is: ${front:-nothing})"
  return 1
}

page_front_title() {
  osascript -e "tell application \"$APP\" to get title of active tab of front window" 2>/dev/null || true
}

# Closes every window whose page title starts with `$1`.
page_close() {
  osascript -e "tell application \"$APP\"
    repeat with w in (every window whose title of active tab starts with \"$1\")
      close w
    end repeat
  end tell" >/dev/null 2>&1 || true
}

# The title of the first page whose title starts with `$1` (the test pages report their state in it).
page_title() {
  osascript -e "tell application \"$APP\" to get title of active tab of (first window whose title of active tab starts with \"$1\")" 2>/dev/null || true
}
