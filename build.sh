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

# optional: ./build.sh install  → copy into /Applications (no signing needed; built locally)
if [ "$1" = "install" ]; then
  echo "installing to /Applications…"
  rm -rf /Applications/ServeSimTray.app
  cp -R "$APP" /Applications/ServeSimTray.app
  echo "installed → /Applications/ServeSimTray.app"
fi
