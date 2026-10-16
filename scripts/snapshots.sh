#!/bin/sh
# Renders the popover at several times of day, and the welcome window, into docs/screenshots/.
# Debug-only showcase mode: no permissions needed and the real screen is never tinted.
# Each render quits itself; a watchdog kills any that hangs, so no instance is left behind.
set -eu
cd "$(dirname "$0")/.."
OUT="${1:-docs/screenshots}"
mkdir -p "$OUT"
swift build
BIN="$(swift build --show-bin-path)/Gloam"

render() {
  "$BIN" "$@" &
  pid=$!
  ( sleep 30; kill "$pid" 2>/dev/null ) &
  watchdog=$!
  wait "$pid" || true
  kill "$watchdog" 2>/dev/null || true
}

rm -f "$OUT"/popover-*.png
for at in 13:00 19:30 21:15 23:30; do
  render --showcase --onboarded --at "$at" --snapshot "$OUT/popover-$(echo "$at" | tr -d :).png"
done
render --showcase welcome --at 16:00 --snapshot "$OUT/welcome.png"

if pgrep -f "$BIN" >/dev/null; then echo "warning: Gloam still running" >&2; pkill -f "$BIN"; fi
# Debug runs keep their settings in the "Gloam" domain; leave nothing behind.
defaults delete Gloam >/dev/null 2>&1 || true; rm -f "$HOME/Library/Preferences/Gloam.plist"
echo "Wrote $OUT"
