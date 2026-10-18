#!/bin/sh
# Builds a release Gloam.app (universal arm64 + x86_64) into .build/Gloam.app.
# Signed ad hoc: without a paid Apple developer account it can't be notarized (README › Install).
set -eu

cd "$(dirname "$0")/.."
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
# CFBundleVersion must be dot-separated integers: v1.2.0-rc1 → 1.2.0.
VERSION="${VERSION#v}"
VERSION="$(printf '%s' "$VERSION" | sed -E 's/^([0-9]+(\.[0-9]+){0,2}).*/\1/')"
case "$VERSION" in ''|*[!0-9.]*) echo "Unusable version: $VERSION" >&2; exit 1 ;; esac
APP=.build/Gloam.app

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Gloam"

swift scripts/make-icon.swift .build/icon

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Gloam"
cp .build/icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"

codesign --force --options runtime --timestamp=none --sign - "$APP"
echo "Built $APP ($VERSION)"
