#!/bin/zsh
# build.sh — compile ServeSim Tray and assemble a self-contained .app bundle.
set -e
cd "$(dirname "$0")"

APP="ServeSim Tray.app"                       # spaced filename → Spotlight shows "ServeSim Tray"
INSTALLED="/Applications/ServeSim Tray.app"

echo "compiling…"
swiftc ServeSimTray.swift -framework ServiceManagement -framework WebKit -o ServeSimTray

echo "assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ServeSimTray  "$APP/Contents/MacOS/ServeSimTray"       # executable stays space-free
cp Info.plist    "$APP/Contents/Info.plist"
cp serve-sim-ctl "$APP/Contents/Resources/serve-sim-ctl"
cp AppIcon.icns  "$APP/Contents/Resources/AppIcon.icns"
cp GUIDE.html    "$APP/Contents/Resources/GUIDE.html"
chmod +x "$APP/Contents/Resources/serve-sim-ctl"
echo "done → $APP"

# optional: ./build.sh install  → quit running instance, copy into /Applications, relaunch.
if [ "$1" = "install" ]; then
  echo "quitting any running instance…"
  pkill -f "Contents/MacOS/ServeSimTray" 2>/dev/null && sleep 1 || true
  echo "installing to /Applications…"
  rm -rf "/Applications/ServeSimTray.app" "$INSTALLED"    # remove old space-less name + prior install
  cp -R "$APP" "$INSTALLED"
  # refresh Spotlight/Finder metadata so the new name shows immediately
  mdimport "$INSTALLED" >/dev/null 2>&1 || true
  echo "launching…"
  open "$INSTALLED"
  echo "installed + running → $INSTALLED"
fi
