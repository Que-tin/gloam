#!/bin/sh
# Builds a release Gloam.app (universal arm64 + x86_64) into .build/, and Gloam.dmg to ship it in.
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
# Sparkle (updates) ships as a framework the app carries; the binary looks for it there.
mkdir -p "$APP/Contents/Frameworks"
ditto "$(dirname "$BIN")/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Gloam"
# Without debug symbols: their map names every object file by absolute path, the builder's home
# folder included, in an app anyone can download. (Before signing, which strip would break.)
strip -S -x "$APP/Contents/MacOS/Gloam"
cp .build/icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
# The disk image's window background (below) rides inside the app: a .background folder beside it
# showed to anyone whose Finder shows hidden files, and Finder takes the picture from any file
# on the image. Added before signing, so the signature covers it.
swift scripts/make-dmg-background.swift .build/dmg-background
tiffutil -cathidpicheck .build/dmg-background/background.png .build/dmg-background/background@2x.png \
    -out "$APP/Contents/Resources/DMGBackground.tiff" 2>/dev/null

# Inside out, Sparkle's parts first, as Sparkle documents for apps that sign it themselves.
SIGN="codesign --force --timestamp=none --sign -"  # no hardened runtime: it only serves notarization, and it would refuse Sparkle (no team ID)
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
$SIGN "$SPARKLE/XPCServices/Installer.xpc"
$SIGN --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
$SIGN "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework"
$SIGN "$APP"

# The download: a disk image that opens on Gloam beside an Applications shortcut to drag it onto,
# over Gloam's own background (in the app, above; the icon positions match the drawing).
# The window's layout is the image's .DS_Store, kept as Resources/dmg-layout, so the image is made
# straight from a folder: never mounted, nothing for macOS to add (it put .fseventsd in a mounted
# one). Only without that file does Finder lay out a scratch copy, once, and the result is kept;
# that needs a Mac that lets this shell control Finder (Privacy & Security › Automation).
LAYOUT_FILE=Resources/dmg-layout
STAGE=.build/dmg
SCRATCH=/private/tmp/Gloam-layout.dmg
rm -rf "$STAGE" .build/Gloam.dmg "$SCRATCH"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Gloam.app"
ln -s /Applications "$STAGE/Applications"
if [ ! -f "$LAYOUT_FILE" ]; then
    hdiutil create -volname Gloam -srcfolder "$STAGE" -fs HFS+ -format UDRW -quiet "$SCRATCH"
    MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$SCRATCH" | awk -F '\t' '/Apple_HFS/ {print $NF}')"
    # Another "Gloam" mounted makes this "Gloam 1", and the layout would point there for good.
    if [ "$(basename "$MOUNT")" != Gloam ]; then
        [ -n "$MOUNT" ] && hdiutil detach -quiet -force "$MOUNT"
        echo "Eject the mounted \"Gloam\" disk image and build again, to lay out the disk image." >&2
        exit 1
    fi
    osascript - "$(basename "$MOUNT")" >/dev/null 2>&1 <<'LAYOUT' && cp "$MOUNT/.DS_Store" "$LAYOUT_FILE"
on run argv
    tell application "Finder" to tell disk (item 1 of argv)
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        try
            set pathbar visible of container window to false
        end try
        -- 560 × 360 below the title bar, centred on a 1512 × 982 screen (the 14-inch default): Finder
        -- keeps a fixed position, it has no "centred"
        set bounds of container window to {476, 297, 1036, 685}
        set options to icon view options of container window
        set arrangement of options to not arranged
        set icon size of options to 128
        set text size of options to 13
        set background picture of options to file "Gloam.app:Contents:Resources:DMGBackground.tiff"
        set position of item "Gloam.app" of container window to {150, 140}
        set position of item "Applications" of container window to {410, 140}
        update without registering applications
        delay 1
        close
    end tell
end run
LAYOUT
    hdiutil detach -quiet -force "$MOUNT"
    rm -f "$SCRATCH"
    # Finder records where the scratch copy and its disk were (hence /private/tmp, not this
    # checkout, whose path holds the user's name) and the disks' IDs, which differ in every image
    # anyway: blanked, so the file shipped in every image says nothing about the Mac it was made on.
    [ -f "$LAYOUT_FILE" ] && perl -0777 -pi -e 's/[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}/00000000-0000-0000-0000-000000000000/g' "$LAYOUT_FILE"
fi
if [ -f "$LAYOUT_FILE" ]; then
    cp "$LAYOUT_FILE" "$STAGE/.DS_Store"
    STYLE=styled
else
    STYLE="plain (no $LAYOUT_FILE, and Finder automation not allowed)"
fi
hdiutil create -volname Gloam -srcfolder "$STAGE" -fs HFS+ -format UDZO -quiet .build/Gloam.dmg
rm -rf "$STAGE"
echo "Disk image: $STYLE"
echo "Built $APP and .build/Gloam.dmg ($VERSION)"
