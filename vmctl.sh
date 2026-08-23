#!/bin/bash
# vmctl — drive the guest through the VM window, for when there is no other way in.
#
# A fresh guest has no SSH and no guest additions, so the only channel into it is
# the keyboard. macOS will deliver synthetic key events to the VM window, which
# is enough to walk a text installer. Once the guest has sshd, stop using this
# and use ssh: it is faster, scriptable, and does not depend on screen-recording
# permission or on the window being where you left it.
#
# Screenshots need a helper that can capture one window by id. Point APPSHOT at
# yours; it must support `list --app`, `shot --window` and print JSON.
set -uo pipefail

APPSHOT=${APPSHOT:-"node $HOME/.claude/skills/appshot/scripts/appshot.mjs"}
APP=${VMCTL_APP:-omarchy-vm}
SHOTDIR=${VMCTL_SHOTDIR:-${TMPDIR:-/tmp}/vmctl}

mkdir -p "$SHOTDIR"

win_field() { $APPSHOT list --app "$APP" 2>/dev/null | grep -m1 "\"$1\"" | tr -dc '0-9'; }

focus() {
  local pid; pid=$(win_field pid)
  [ -z "$pid" ] && { echo "vmctl: no window for $APP" >&2; exit 1; }
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" >/dev/null 2>&1
  # Focus is asynchronous; without this the next key lands in the previous app.
  sleep 0.4
}

keycode() {
  case "$1" in
    return|enter) echo 36 ;;  tab)   echo 48 ;;  space) echo 49 ;;
    esc|escape)   echo 53 ;;  up)    echo 126 ;; down)  echo 125 ;;
    left)         echo 123 ;; right) echo 124 ;;
    del|delete|backspace) echo 51 ;;
    *) echo "vmctl: unknown key '$1'" >&2; exit 2 ;;
  esac
}

case "${1:-}" in
  key)   # vmctl key down [times]
    focus; k=$(keycode "$2"); n=${3:-1}
    for _ in $(seq "$n"); do osascript -e "tell application \"System Events\" to key code $k"; sleep 0.25; done ;;
  type)  # vmctl type "text" — one character at a time; bursts get dropped
    focus
    printf '%s' "$2" | while IFS= read -r -n1 c; do
      [ -z "$c" ] && continue
      esc=${c//\\/\\\\}; esc=${esc//\"/\\\"}
      osascript -e "tell application \"System Events\" to keystroke \"$esc\""
      sleep 0.15
    done ;;
  shot)  # vmctl shot [name] -> prints the PNG path
    name=${2:-state}; id=$(win_field id)
    [ -z "$id" ] && { echo "vmctl: no window for $APP" >&2; exit 1; }
    $APPSHOT shot --window "$id" -o "$SHOTDIR/$name.png" >/dev/null 2>&1
    echo "$SHOTDIR/$name.png" ;;
  console)  # vmctl console [lines] — the guest's serial log
    tail -n "${2:-40}" "$(dirname "$0")/vm/console.log" | tr -d '\000' ;;
  *)
    echo "usage: vmctl {key <name> [times] | type <text> | shot [name] | console [lines]}" >&2
    exit 2 ;;
esac
