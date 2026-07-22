import AppKit
import ServiceManagement
import WebKit
import Network

let ctlPath = Bundle.main.path(forResource: "serve-sim-ctl", ofType: nil) ?? ""   // bundled in Contents/Resources

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var running = false
    var health = "ok"                          // ok | tailscale-down | no-serve
    var simURL = "http://localhost:3200"       // shareable URL (tailnet if present, else localhost)
    var shareState = "private"                 // private (Serve / tailnet-only) | public (Funnel)
    var guideWindow: NSWindow?
    var controlListener: NWListener?           // tailnet-only remote-control endpoint
    var controlBase = ""                       // http://<tailscale-ip>:8765
    let controlPort: UInt16 = 8765

    let localURL = "http://localhost:3200"
    var isTailnet: Bool { simURL.hasPrefix("https") }

    // Live handle to the running iOS Simulator app (nil if not running)
    var simApp: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.iphonesimulator" }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu(); menu.delegate = self          // repopulated on each open
        statusItem.menu = menu
        applyIcon()
        refresh()
        startControlServer()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func applicationWillTerminate(_ note: Notification) {
        controlListener?.cancel(); controlListener = nil     // tear down the endpoint on quit
    }

    // MARK: - Remote-control endpoint (tailnet-only: bound to the Tailscale IP)
    func startControlServer() {
        guard controlListener == nil else { return }
        run(["ctl-ip"]) { [weak self] out in
            let ip = out.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ip.isEmpty else { return }                 // no Tailscale IP yet → try again next refresh
            DispatchQueue.main.async { self?.bindControl(ip: ip) }
        }
    }

    func bindControl(ip: String) {
        guard controlListener == nil, let port = NWEndpoint.Port(rawValue: controlPort) else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(ip), port: port)   // Tailscale IP only
        guard let listener = try? NWListener(using: params) else { return }
        listener.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:              self?.controlBase = "http://\(ip):8765"
                case .failed, .cancelled: self?.controlListener = nil; self?.controlBase = ""
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.handleControl(conn) }
        listener.start(queue: .main)
        controlListener = listener
    }

    func handleControl(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            let req = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let firstLine = req.components(separatedBy: "\r\n").first ?? ""
            let rawPath = firstLine.components(separatedBy: " ").dropFirst().first ?? "/"
            let path = rawPath.components(separatedBy: "?").first ?? rawPath
            self?.controlRespond(conn, path: path)
        }
    }

    func controlRespond(_ conn: NWConnection, path: String) {
        func send(_ status: String, _ json: String) {
            let resp = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n\(json)"
            conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
        }
        switch path {
        case "/start":
            run(["start"]) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.simApp?.hide() }   // tidy; no browser
                }
            }
            send("200 OK", "{\"ok\":true,\"action\":\"start\"}")
        case "/stop":
            run(["stop"]) { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
            send("200 OK", "{\"ok\":true,\"action\":\"stop\"}")
        case "/status", "/":
            run(["state"]) { out in
                let l = out.components(separatedBy: "\n")
                let running = (l.first ?? "") == "running"
                let url = l.count > 2 ? l[2] : ""
                send("200 OK", "{\"running\":\(running),\"url\":\"\(url)\"}")
            }
        default:
            send("404 Not Found", "{\"ok\":false,\"error\":\"unknown path\"}")
        }
    }

    // MARK: - Icon
    func applyIcon() {
        guard let button = statusItem.button else { return }
        let unhealthy = running && health != "ok"                     // only warn when actively serving
        let symbol = unhealthy ? "exclamationmark.triangle" : (running ? "iphone" : "iphone.slash")
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "serve-sim") {
            img.isTemplate = true; button.image = img; button.title = ""
        } else {
            button.image = nil
            button.title = unhealthy ? "⚠️" : (running ? "📱" : "📴")
        }
    }

    var loginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    // MARK: - Menu (rebuilt just-in-time, so it always reflects current state)
    func menuNeedsUpdate(_ menu: NSMenu) { populate(menu) }

    func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        if running && health != "ok" {                                 // only warn when actively serving
            let warnText = (health == "tailscale-down") ? "⚠ Tailscale not connected"
                                                        : "⚠ Tailscale Serve not active"
            let warn = NSMenuItem(title: warnText, action: nil, keyEquivalent: ""); warn.isEnabled = false
            menu.addItem(warn); menu.addItem(.separator())
        }
        let header = NSMenuItem(title: running ? "🟢 serve-sim: running" : "○ serve-sim: stopped", action: nil, keyEquivalent: "")
        header.isEnabled = false; menu.addItem(header)
        menu.addItem(.separator())

        if running && shareState == "public" {
            let pub = NSMenuItem(title: "🌐 Public (Funnel) — click to view",
                                 action: #selector(viewTailnet), keyEquivalent: "")
            pub.target = self
            menu.addItem(pub); menu.addItem(.separator())
        }

        if running {
            add(menu, "View Serve-Sim — This Mac", #selector(viewLocal), "")
            if isTailnet {
                add(menu, "View Serve-Sim — Tailnet", #selector(viewTailnet), "")
            }
            // Native Simulator — Open / Hide / Show, aware of its live state
            if let s = simApp {
                if s.isHidden { add(menu, "Show Native Sim", #selector(showSim), "") }
                else          { add(menu, "Hide Native Sim", #selector(hideSim), "") }
            } else {
                add(menu, "Open Native Sim", #selector(openNativeSim), "")
            }
            menu.addItem(.separator())
            add(menu, "Pause Sim", #selector(pauseSim), "")
            add(menu, "Stop Sim", #selector(stopSim), "")
        } else {
            add(menu, "Start", #selector(start), "")
        }
        menu.addItem(.separator())

        // Settings flyout
        let settings = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self; login.state = loginEnabled ? .on : .off; sub.addItem(login)
        let chk = NSMenuItem(title: "Check Setup…", action: #selector(checkSetup), keyEquivalent: ""); chk.target = self; sub.addItem(chk)
        let gd = NSMenuItem(title: "Guide", action: #selector(openGuide), keyEquivalent: ""); gd.target = self; sub.addItem(gd)
        sub.addItem(.separator())
        let fn = NSMenuItem(title: "Share Publicly (Funnel)", action: #selector(toggleFunnel), keyEquivalent: "")
        fn.target = self; fn.state = (shareState == "public") ? .on : .off; sub.addItem(fn)
        sub.addItem(.separator())
        let cpTitle = (shareState == "public") ? "Copy Public URL" : (isTailnet ? "Copy Tailnet URL" : "Copy Sim URL")
        let cp = NSMenuItem(title: cpTitle, action: #selector(copyTailnet), keyEquivalent: "")
        cp.target = self; sub.addItem(cp)
        if !controlBase.isEmpty {
            let rc = NSMenuItem(title: "Copy Remote-Control URL", action: #selector(copyControlURL), keyEquivalent: "")
            rc.target = self; sub.addItem(rc)
        }
        settings.submenu = sub
        menu.addItem(settings)

        menu.addItem(.separator())
        add(menu, "Quit", #selector(quitApp), "")
    }

    @discardableResult
    func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item); return item
    }

    // MARK: - State
    func refresh() {
        run(["state"]) { [weak self] out in
            let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            let isRun = lines.count > 0 && lines[0] == "running"
            let hv    = (lines.count > 1 && !lines[1].isEmpty) ? lines[1] : "ok"
            let u     = (lines.count > 2 && !lines[2].isEmpty) ? lines[2] : "http://localhost:3200"
            let sh    = (lines.count > 3 && !lines[3].isEmpty) ? lines[3] : "private"
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.running = isRun; self.health = hv; self.simURL = u; self.shareState = sh
                self.applyIcon()
                if self.controlListener == nil { self.startControlServer() }   // recover if Tailscale came up later
            }
        }
    }

    // MARK: - Actions
    @objc func start() {
        let wasRunning = running
        run(["start"]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.refresh()
                if !wasRunning {                                                   // cold start
                    self.open(self.localURL)                                        // open the stream tab (interface first)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.simApp?.hide() }  // then tuck the Simulator away
                }
            }
        }
    }
    @objc func pauseSim() { run(["pause"]) { [weak self] _ in DispatchQueue.main.async { self?.refresh() } } }
    @objc func stopSim()  { run(["stop"])  { [weak self] _ in DispatchQueue.main.async { self?.refresh() } } }

    @objc func openNativeSim() { run(["open-sim"]) { _ in } }
    @objc func hideSim()       { simApp?.hide() }
    @objc func showSim()       { simApp?.unhide(); simApp?.activate(options: []) }

    @objc func viewLocal()   { open(localURL) }
    @objc func viewTailnet() { open(simURL) }
    @objc func copyLocal()   { copy(localURL) }
    @objc func copyTailnet() { copy(simURL) }
    @objc func copyControlURL() { copy(controlBase) }

    func open(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }
    func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }

    @objc func toggleFunnel() {
        if shareState == "public" {
            run(["funnel-off"]) { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
            return
        }
        let a = NSAlert()
        a.messageText = "Make the simulator public?"
        a.informativeText = "Tailscale Funnel will expose the stream to the whole internet. Anyone with the link can VIEW and CONTROL your simulator (serve-sim has no password). Only share the URL with people you trust."
        a.addButton(withTitle: "Make Public"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        run(["funnel-on"]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refresh()
                self?.run(["share-state"]) { s in                          // confirm it actually went public
                    if s.trimmingCharacters(in: .whitespacesAndNewlines) != "public" {
                        DispatchQueue.main.async {
                            let b = NSAlert()
                            b.messageText = "Couldn't enable public sharing"
                            b.informativeText = "Tailscale Funnel likely needs to be enabled once for your tailnet at login.tailscale.com (Access controls → Funnel), then try again."
                            b.addButton(withTitle: "OK"); NSApp.activate(ignoringOtherApps: true); b.runModal()
                        }
                    }
                }
            }
        }
    }

    @objc func toggleLogin() {
        do { if loginEnabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() } }
        catch { NSSound.beep() }
    }

    @objc func checkSetup() {
        run(["check"]) { out in
            DispatchQueue.main.async {
                let a = NSAlert(); a.messageText = "Setup Check"
                a.informativeText = out.isEmpty ? "Could not run the check." : out
                a.addButton(withTitle: "OK"); NSApp.activate(ignoringOtherApps: true); a.runModal()
            }
        }
    }

    // In-app Guide viewer (WKWebView window you can close), instead of a browser.
    @objc func openGuide() {
        if let w = guideWindow { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        guard let p = Bundle.main.path(forResource: "GUIDE", ofType: "html") else { return }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 640),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "ServeSim Tray — Guide"; win.center(); win.isReleasedWhenClosed = false
        let web = WKWebView(frame: win.contentView!.bounds)
        web.autoresizingMask = [.width, .height]
        let fileURL = URL(fileURLWithPath: p)
        web.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
        win.contentView!.addSubview(web)
        win.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        guideWindow = win
    }

    @objc func quitApp() {
        let a = NSAlert()
        a.messageText = "Quit ServeSim Tray?"
        a.informativeText = "This shuts down the simulator, stops serve-sim, closes public sharing, and quits the app."
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            run(["stop"]) { _ in DispatchQueue.main.async { NSApplication.shared.terminate(nil) } }
        }
    }

    func run(_ args: [String], done: @escaping (String) -> Void) {
        DispatchQueue.global().async {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = [ctlPath] + args
            let outPipe = Pipe(); p.standardOutput = outPipe; p.standardError = Pipe()
            do { try p.run() } catch { done(""); return }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            done(String(data: data, encoding: .utf8) ?? "")
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
