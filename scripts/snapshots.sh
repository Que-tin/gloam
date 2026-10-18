#!/bin/sh
# Renders the popover at several times of day, the welcome window and Settings into docs/screenshots/.
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
# Settings is native AppKit forms, which the snapshot renderer can't draw: photograph the real
# window instead (needs the Screen Recording permission for the terminal running this).
CAP="$(mktemp -d)"
render --capture "$CAP" --at 21:15
if [ -f "$CAP/window-settings.png" ]; then mv "$CAP/window-settings.png" "$OUT/settings.png"
else echo "warning: no settings capture (Screen Recording permission?)" >&2; fi
rm -rf "${CAP:?}"

if pgrep -f "$BIN" >/dev/null; then echo "warning: Gloam still running" >&2; pkill -f "$BIN"; fi
# Debug runs keep their settings in the "Gloam" domain; leave nothing behind.
defaults delete Gloam >/dev/null 2>&1 || true; rm -f "$HOME/Library/Preferences/Gloam.plist"
# These are published: none may carry a colour profile (a screen's names the panel and its
# serial number) or text metadata. Captures are saved in plain sRGB; this is the safety net.
if LEAKS="$(grep -a -l -E 'iCCP|tEXt|iTXt|zTXt' "$OUT"/*.png)"; then
  echo "error: metadata in $LEAKS — don't publish these" >&2
  exit 1
fi
echo "Wrote $OUT"
