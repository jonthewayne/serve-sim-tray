#!/bin/zsh
# build.sh — compile ServeSimTray and assemble a self-contained .app bundle.
set -e
cd "$(dirname "$0")"

APP="ServeSimTray.app"

echo "compiling…"
swiftc ServeSimTray.swift -framework ServiceManagement -framework WebKit -o ServeSimTray

echo "assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ServeSimTray        "$APP/Contents/MacOS/ServeSimTray"
cp Info.plist          "$APP/Contents/Info.plist"
cp serve-sim-ctl       "$APP/Contents/Resources/serve-sim-ctl"
cp GUIDE.html          "$APP/Contents/Resources/GUIDE.html"
chmod +x "$APP/Contents/Resources/serve-sim-ctl"

echo "done → $APP"

# optional: ./build.sh install  → quit any running instance, copy into /Applications, relaunch.
# (No signing needed — it's compiled locally.)
if [ "$1" = "install" ]; then
  echo "quitting any running ServeSimTray…"
  pkill -f "ServeSimTray.app/Contents/MacOS/ServeSimTray" 2>/dev/null && sleep 1 || true
  echo "installing to /Applications…"
  rm -rf /Applications/ServeSimTray.app
  cp -R "$APP" /Applications/ServeSimTray.app
  echo "launching from /Applications…"
  open /Applications/ServeSimTray.app
  echo "installed + running → /Applications/ServeSimTray.app"
fi
