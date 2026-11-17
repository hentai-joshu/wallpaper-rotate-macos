#!/bin/bash
# Remove the LaunchAgent and the app bundle. Your pictures and settings are left alone.
#
#   ./uninstall.sh            unload and remove
#   ./uninstall.sh --dry-run  print what would happen, touch nothing
#   ./uninstall.sh --purge    also delete saved settings and the support folder
set -euo pipefail

LABEL="local.wallpaper-rotate"
APP_DIR="$HOME/Applications/WallpaperRotate.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SUPPORT="$HOME/Library/Application Support/wallpaper-rotate"
LOG="$HOME/Library/Logs/wallpaper-rotate.log"

DRY=0
PURGE=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        --purge) PURGE=1 ;;
        -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

say() { printf '%s\n' "$*"; }

if [ "$DRY" -eq 1 ]; then
    say "would unload : $LABEL"
    say "would remove : $PLIST"
    say "would remove : $APP_DIR"
    [ "$PURGE" -eq 1 ] && say "would remove : $SUPPORT, settings, $LOG"
    exit 0
fi

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
say "unloaded : $LABEL"

rm -f "$PLIST"
say "removed  : $PLIST"

rm -rf "$APP_DIR"
say "removed  : $APP_DIR"

if [ "$PURGE" -eq 1 ]; then
    defaults delete "$LABEL" 2>/dev/null || true
    rm -rf "$SUPPORT" "$LOG"
    say "purged   : settings, $SUPPORT, $LOG"
else
    say "kept     : settings, $SUPPORT (use --purge to remove)"
fi
