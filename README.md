# ServeSimTray

A tiny macOS **menu-bar app** that runs an iOS Simulator as a live, controllable stream — in one
click. It wraps [serve-sim](https://github.com/EvanBacon/serve-sim) (boots a simulator and streams it
as a web page with touch/type control). serve-sim launches Apple's Simulator app to capture frames; the
tray auto-hides that window on Start (it still shows in ⌘Tab while streaming — a macOS limitation). Use
it **locally** on your own machine, or
**share it over Tailscale** so other devices — or an AI agent on another machine — can drive it.

## Two ways to use it

| Mode | What you do | Who can reach it |
|---|---|---|
| **Local** (default, no Tailscale) | Hit **Start**, open `http://localhost:3200` | you + agents on this Mac |
| **Over Tailscale** (optional) | Same, plus Tailscale up + Serve enabled | any device on your tailnet + remote agents |

The Tailscale layer is purely additive — without it, you get a great local serve-sim launcher.

## 👋 First time? Hand it to your coding agent

Paste this to Claude Code / Codex and it'll set your Mac up end to end:

```
Set up this Mac to run ServeSimTray (an iOS-simulator streaming menu-bar app). Do each step and
pause to ask me when you need input (App Store sign-in, Tailscale login, enabling Serve):

1. Ensure Xcode is installed (Mac App Store) and an iOS runtime is present:
   sudo xcode-select -s /Applications/Xcode.app && xcodebuild -downloadPlatform iOS
2. Ensure Node 20+ is installed (e.g. via nvm).
3. (Optional, for remote access) Ensure Tailscale is installed and signed in, and enable
   Tailscale Serve for my tailnet at login.tailscale.com. Skip for local-only use.
4. In the serve-sim-tray folder run ./build.sh install (compiles locally and copies the app to
   /Applications — no code signing or Apple Developer account needed), then launch it from
   /Applications and turn on "Start at Login" from its menu.
Then open the app's "Check Setup…" to confirm everything is green.
```

The app's **Check Setup…** menu item also verifies prerequisites and tells you what's missing.

## What you get

- Menu-bar icon: `iphone` running · `iphone.slash` stopped · **⚠️** if Tailscale is down (Tailscale mode).
- **View Serve-Sim — This Mac / — Tailnet** (the stream at localhost or your tailnet URL) · **Open / Hide / Show Native Sim** (optional Apple window; menu tracks its state — never Quit it).
- **Start / Pause Sim / Stop Sim**, **Start at Login**, **Check Setup…**, in-app **Guide**.
- Auto-detects the URL (localhost, or your tailnet name) + a bootable iPhone. Self-healing if the sim is shut down.

## Prerequisites

| Need | Why |
|---|---|
| **Apple Silicon Mac** | serve-sim is arm64-only |
| **Xcode** + an iOS runtime | provides the Simulator and `simctl` |
| **Node 20+** | runs serve-sim via `npx` |
| **Tailscale** *(optional)* | only for remote access — **enable Serve once** at login.tailscale.com |

```bash
# Xcode from the Mac App Store, then a simulator runtime:
sudo xcode-select -s /Applications/Xcode.app
xcodebuild -downloadPlatform iOS
# Node 20+ (e.g. nvm). Tailscale only if you want remote access (tailscale.com).
```

## Build

```bash
git clone <this-repo> && cd serve-sim-tray
./build.sh            # compiles ServeSimTray.swift + assembles ServeSimTray.app
open ServeSimTray.app # menu-bar only, no Dock icon
```

Move `ServeSimTray.app` to `/Applications` and use **Start at Login** to auto-run.

<details>
<summary>How it's built / how it works</summary>

- `ServeSimTray.swift` — single-file AppKit menu-bar app (no Xcode project); `swiftc` compiles it.
- `serve-sim-ctl` — zsh control script (`start`/`pause`/`stop`/`open-sim`/`status`/`url`/`health`/`check`),
  bundled into `Contents/Resources`. Auto-detects URL + device; skips Tailscale if it isn't installed;
  self-heals a stale serve-sim (e.g. if the sim gets shut down).
- `Info.plist` (`LSUIElement`), `build.sh` (assembles the bundle), `GUIDE.html` (in-app quick guide).
- **Tailscale (optional):** must be running + signed in, Serve enabled once per tailnet. The URL mapping
  the app sets is persistent (survives reboots). The app shows a ⚠️ if the network layer is down.
</details>

## Notes / limits

- **No code signing needed** when each user *builds it themselves* from source (as above): a locally
  compiled app isn't quarantined, so it runs with no Gatekeeper warning and needs no Apple Developer
  account. Signing/notarizing is only required if you distribute a *prebuilt binary*.
- Keep the Mac **awake + logged in** while in use (the simulator needs the GUI session).
- Default port `3200` lives in `serve-sim-ctl` — easy to tweak.
