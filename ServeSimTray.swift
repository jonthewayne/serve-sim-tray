import AppKit
import ServiceManagement
import WebKit

let ctlPath = Bundle.main.path(forResource: "serve-sim-ctl", ofType: nil) ?? ""   // bundled in Contents/Resources

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var running = false
    var health = "ok"                          // ok | tailscale-down | no-serve
    var simURL = "http://localhost:3200"       // shareable URL (tailnet if present, else localhost)
    var guideWindow: NSWindow?
    var hud: NSWindow?

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
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    // MARK: - Icon
    func applyIcon() {
        guard let button = statusItem.button else { return }
        let symbol = (health != "ok") ? "exclamationmark.triangle" : (running ? "iphone" : "iphone.slash")
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "serve-sim") {
            img.isTemplate = true; button.image = img; button.title = ""
        } else {
            button.image = nil
            button.title = (health != "ok") ? "⚠️" : (running ? "📱" : "📴")
        }
    }

    var loginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    // MARK: - Menu (rebuilt just-in-time, so it always reflects current state)
    func menuNeedsUpdate(_ menu: NSMenu) { populate(menu) }

    func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        if health != "ok" {
            let warnText = (health == "tailscale-down") ? "⚠ Tailscale not connected"
                                                        : "⚠ Tailscale Serve not active — click Start"
            let warn = NSMenuItem(title: warnText, action: nil, keyEquivalent: ""); warn.isEnabled = false
            menu.addItem(warn); menu.addItem(.separator())
        }
        let header = NSMenuItem(title: running ? "🟢 serve-sim: running" : "○ serve-sim: stopped", action: nil, keyEquivalent: "")
        header.isEnabled = false; menu.addItem(header)
        menu.addItem(.separator())

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
        let cp = NSMenuItem(title: isTailnet ? "Copy Tailnet URL" : "Copy Sim URL", action: #selector(copyTailnet), keyEquivalent: "")
        cp.target = self; sub.addItem(cp)
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
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.running = isRun; self.health = hv; self.simURL = u
                self.applyIcon()
            }
        }
    }

    // MARK: - Actions
    @objc func start() {
        run(["start"]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.refresh()
                self.simApp?.hide()                                    // serve-sim opened Simulator; tuck it away
                self.showHUD("Hid Native Sim — opening Serve-Sim…")    // feedback so the screen isn't blank
                self.open(self.localURL)                               // show the stream in the browser
            }
        }
    }

    // Small floating toast (menu-bar apps can't reliably use system notifications).
    func showHUD(_ text: String) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 60),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.level = .floating; w.isOpaque = false; w.backgroundColor = .clear; w.ignoresMouseEvents = true
        let fx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 340, height: 60))
        fx.material = .hudWindow; fx.state = .active; fx.blendingMode = .behindWindow
        fx.wantsLayer = true; fx.layer?.cornerRadius = 12; fx.autoresizingMask = [.width, .height]
        let label = NSTextField(labelWithString: text)
        label.alignment = .center; label.font = .systemFont(ofSize: 13, weight: .medium)
        label.frame = NSRect(x: 12, y: 20, width: 316, height: 20); label.autoresizingMask = [.width]
        fx.addSubview(label)
        w.contentView = fx
        w.center()
        w.orderFrontRegardless()
        hud = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.4; w.animator().alphaValue = 0 },
                                                 completionHandler: { w.close() })
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

    func open(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }
    func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }

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
        win.title = "ServeSimTray — Guide"; win.center(); win.isReleasedWhenClosed = false
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
        a.messageText = "Quit ServeSimTray?"
        a.informativeText = "This will quit the tray app and stop the serve-sim process. (The simulator and Tailscale are left as-is.)"
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            run(["pause"]) { _ in DispatchQueue.main.async { NSApplication.shared.terminate(nil) } }
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
