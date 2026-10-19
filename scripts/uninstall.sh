#!/bin/bash
# Remove UsageBar.app, its LaunchAgent, its cache, and the stored API key.
set -euo pipefail

APP_NAME="UsageBar"
BUNDLE_ID="com.usagebar.app"
DEST="/Applications/$APP_NAME.app"
AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
CACHE="$HOME/Library/Caches/$BUNDLE_ID"

echo "==> quitting"
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5

echo "==> removing LaunchAgent"
launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
rm -f "$AGENT"

echo "==> removing app"
rm -rf "$DEST"

echo "==> removing cache"
rm -rf "$CACHE"

echo "==> removing keychain item"
security delete-generic-password -s "$BUNDLE_ID" -a "kenari-api-key" >/dev/null 2>&1 || true

echo "==> removing preferences"
defaults delete "$BUNDLE_ID" 2>/dev/null || true

echo "Done."
