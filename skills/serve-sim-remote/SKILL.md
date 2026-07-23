---
name: serve-sim-remote
description: Drive the iOS Simulator that lives on the main MacBook (curiouss-macbook-air) from this dev box, over Tailscale. Use when a task needs to run, see, or interact with an iOS app UI — this machine (Intel) cannot run a simulator itself.
---

# serve-sim-remote — drive the main Mac's iOS Simulator from this dev box

This Intel dev box **cannot run an iOS Simulator** (arm64 + Xcode required). The main MacBook
(`curiouss-macbook-air`, Tailscale `100.77.145.121`) runs **serve-sim** — a server that streams the
simulator to a browser **and forwards browser input back to it**. Its **ServeSim Tray** app exposes a
scoped control endpoint on the tailnet. You orchestrate everything from here; you never SSH to the Mac.

## The four steps

```bash
MAIN=100.77.145.121   # or: curiouss-macbook-air

# 1. Start serve-sim on the Mac (requires: Mac awake, logged in, tray app running)
curl -s "http://$MAIN:8765/start"

# 2. Wait until ready, then read the stream URL from the JSON
until curl -s -m 3 "http://$MAIN:8765/status" | grep -q '"running":true'; do sleep 2; done
curl -s "http://$MAIN:8765/status"   # -> {"running":true, "url":"https://curiouss-macbook-air.tail…ts.net"}

# 3. Open that url in a browser and DRIVE the sim there (see below)

# 4. Stop when done (frees the Mac; also turns off any public sharing)
curl -s "http://$MAIN:8765/stop"
```

## Driving (step 3) — the browser IS the remote control

The stream page is interactive, not just a picture: **clicks, typing, swipes (drag from the bottom =
home), and drag-dropped image/video files are forwarded to the simulator** over its WebSocket control
channel. Use browser-automation tools (e.g. Claude-in-Chrome) on the opened page:
- Take a screenshot to see the sim, click at coordinates on the device image to tap.
- Type on the page to send keys to the sim.
- Verify visually with follow-up screenshots.

### Semantic reading — the AX TREE toggle (verified 2026-07-23)

The Tools panel (right side) has an **AX TREE** toggle. Turning it ON gives you the simulator's real
accessibility tree **in the browser DOM** — sim elements appear as readable entries
(`button "Settings"`, `listitem "Maps · button · 168x191"`) via the page accessibility tree
(`read_page`), plus bounding boxes drawn on the stream. So you can *read semantically* instead of
guessing from pixels.

**CRITICAL — the overlay intercepts clicks.** With AX TREE ON, clicks on the device image hit the
overlay's inspection boxes and are **NOT forwarded to the simulator** (Event Log stays at 0). The loop is:

1. **AX TREE ON** → `read_page` / screenshot → learn element names + positions
2. **AX TREE OFF** → click those coordinates → the tap forwards (Event Log increments)
3. Repeat per screen.

### Also driveable from the page DOM (no pixels needed)

These are plain DOM buttons — click them by accessibility ref, not coordinates:
- **Hardware:** Home · Screenshot · Rotate · Volume Up/Down · Power · Action button
- **Permissions panel:** Allow / Deny / Reset per service (camera, mic, photos, contacts, calendar,
  location, notifications, Siri, …) + reset-all — **test permission flows without tapping dialogs**
- **Location panel:** simulated GPS trails (walk/run/cycle/drive, speed) — location-feature testing
- **Camera panel:** inject an image/video as the sim's camera feed
- **Appearance:** light/dark, text size, reduce-motion, VoiceOver toggles
- **Device sidebar:** boot/shut down any listed iPhone/iPad
- **WebKit DevTools panel:** inspect Safari/WKWebViews running inside the sim
- The panel header always shows the **foreground app + bundle id + PID**; the **Event Log** counts
  forwarded inputs (use it to confirm your click actually landed).

Caveats:
- When clicking the stream you are clicking **pixel coordinates on video** — re-screenshot after UI
  changes rather than assuming layout.
- The page streams at 60fps; give it a beat after actions before screenshotting.
- If you are an agent running **on the main Mac itself** (next to the simulator), you have the option
  of serve-sim's bundled CLI skill (`skills/serve-sim` in its repo) — semantic taps via
  `serve-sim tap` etc. Over the Tailscale link **you don't**: the CLI is local-only, so from this dev
  box the browser flow above is the way.

## Failure modes

| Symptom | Meaning |
|---|---|
| `/status` times out | Mac asleep/logged out/tray not running — no remote wake **by design**; ask the human |
| `running:false` right after start | Simulator still booting — keep polling (first boot can take ~30s) |
| Stream loads but frozen | Someone quit Simulator.app on the Mac (that shuts the device down); `/stop` then `/start` |

## Rules

- **Never** try to SSH to the main Mac or look for other control channels — `/start` `/status` `/stop`
  (+ the browser) is the entire, intentional surface.
- Apps under test should be served **from this dev box** (e.g. `http://100.120.153.119:3000`) and loaded
  inside the sim over Tailscale — no git push needed for live iteration.
- Always `/stop` when finished.
