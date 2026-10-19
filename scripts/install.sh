#!/bin/bash
# Install UsageBar.app into /Applications, register the LaunchAgent, and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="UsageBar"
BUNDLE_ID="com.usagebar.app"
SRC="build/$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"
AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

[ -d "$SRC" ] || { echo "missing $SRC — run scripts/build.sh first" >&2; exit 1; }

echo "==> stopping running copy"
osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5

echo "==> copying to $DEST"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

echo "==> writing LaunchAgent"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$BUNDLE_ID</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-a</string>
    <string>$DEST</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST

echo "==> launchctl bootstrap"
launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"

echo "==> launching"
open -a "$DEST"
sleep 1
pgrep -x "$APP_NAME" >/dev/null && echo "running (pid $(pgrep -x "$APP_NAME" | head -1))" || echo "not running — check Console.app"

echo
echo "Installed. Menu bar icon should appear. First run: click it, then set the API key:"
echo "  $DEST/Contents/MacOS/$APP_NAME --set-key <kn-...>"
