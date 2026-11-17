#!/bin/bash
# Build and install the wallpaper rotator as a menu-bar app plus a LaunchAgent.
#
#   ./install.sh            build, install, load
#   ./install.sh --dry-run  print what would happen, touch nothing
#   ./install.sh --no-load  build and install, but do not load the agent
#
# Everything is written under $HOME; nothing is installed system-wide.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LABEL="local.wallpaper-rotate"
BUNDLE_ID="local.wallpaper-rotate"
APP_NAME="WallpaperRotate.app"
APP_DIR="$HOME/Applications/$APP_NAME"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SUPPORT="$HOME/Library/Application Support/wallpaper-rotate"
LOG="$HOME/Library/Logs/wallpaper-rotate.log"

DRY=0
LOAD=1
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        --no-load) LOAD=0 ;;
        -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

say() { printf '%s\n' "$*"; }

command -v clang >/dev/null || { echo "clang not found — install the Command Line Tools: xcode-select --install" >&2; exit 1; }

if [ "$DRY" -eq 1 ]; then
    say "would build      : $ROOT/app/main.m -> $ROOT/app/wallpaper-rotate"
    say "would install app: $APP_DIR  (bundle id $BUNDLE_ID)"
    say "would write      : $PLIST"
    say "would create     : $SUPPORT"
    [ "$LOAD" -eq 1 ] && say "would load       : launchctl bootstrap gui/$(id -u) $PLIST"
    exit 0
fi

say "building…"
clang -fobjc-arc -O2 -framework Cocoa -framework CoreGraphics \
      -o "$ROOT/app/wallpaper-rotate" "$ROOT/app/main.m"

# --- app bundle (LSUIElement keeps it out of the Dock and the app switcher) ---
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$ROOT/app/wallpaper-rotate" "$APP_DIR/Contents/MacOS/wallpaper-rotate"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>wallpaper-rotate</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleName</key><string>WallpaperRotate</string>
	<key>CFBundleDisplayName</key><string>Wallpaper Rotate</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.1</string>
	<key>CFBundleVersion</key><string>2</string>
	<key>LSUIElement</key><true/>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign -s - --force "$APP_DIR" >/dev/null 2>&1 || true
say "installed app    : $APP_DIR"

mkdir -p "$SUPPORT" "$HOME/Library/Logs" "$HOME/Library/LaunchAgents"

# --- LaunchAgent ---
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array><string>$APP_DIR/Contents/MacOS/wallpaper-rotate</string></array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key>
	<dict><key>SuccessfulExit</key><false/></dict>
	<key>ProcessType</key><string>Interactive</string>
	<key>StandardErrorPath</key><string>$LOG</string>
	<key>StandardOutPath</key><string>$LOG</string>
</dict>
</plist>
PLIST
plutil -lint "$PLIST" >/dev/null
say "wrote agent      : $PLIST"

if [ "$LOAD" -eq 1 ]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    sleep 1
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    say "loaded agent     : $LABEL"
    say ""
    say "log: tail -f $LOG"
else
    say "agent not loaded (--no-load). Load it with:"
    say "  launchctl bootstrap gui/\$(id -u) $PLIST"
fi
