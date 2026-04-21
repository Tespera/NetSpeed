import Cocoa
import Combine
import Darwin

class ProcessItemView: NSView {
    var onClick: (() -> Void)?
    
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        onClick?()
    }
        
    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        return view != nil ? self : nil
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = NetSpeedMonitor()
    private var timer: AnyCancellable?
    private var statusView: NetSpeedStatusView?
    private var procFetchToken: Int = 0
    private var launchAgentItem: NSMenuItem?
    private let launchctlQueue = DispatchQueue(label: "com.netspeed.launchctl")
    private static let lengthWithArrow: CGFloat = 48
    private static let lengthWithoutArrow: CGFloat = 42
    private static let nettopLineRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "^(\\S+)\\s+(.+)\\.(\\d+)\\s+(\\d+)\\s+(\\d+)", options: [])
    }()
    private var isFastInterval = false
    private let fastThreshold: Double = 1.1 * 1024 * 1024
    private let slowThreshold: Double = 0.9 * 1024 * 1024
    private let agentLabel = "com.netspeed.NetSpeed"
    private var procMenuItem: NSMenuItem?
    private var procMenu: NSMenu?
    private var procTimer: AnyCancellable?
    private var procItems: [NSMenuItem] = []
    private let procLimit = 5
    private let procQueue = DispatchQueue(label: "com.netspeed.proc", qos: .utility)
    private var procFetching = false
    private var procPlaceholderItem: NSMenuItem?
    private var processInfoCache: [Int: (name: String, icon: NSImage?)] = [:]
    
    private enum DisplayMode: String, CaseIterable {
        case both = "Both"
        case uploadOnly = "Upload Only"
        case downloadOnly = "Download Only"
        case total = "Total Speed"
    }
    
    private var displayMode: DisplayMode = .both {
        didSet {
            UserDefaults.standard.set(displayMode.rawValue, forKey: "displayMode")
            updateStatusBar()
        }
    }
    
    private var updateInterval: TimeInterval = 1.0 {
        didSet {
            guard updateInterval != oldValue else { return }
            restartTimer()
        }
    }
    
    private var showArrow: Bool = true {
        didSet {
            guard showArrow != oldValue else { return }
            UserDefaults.standard.set(showArrow, forKey: "showArrow")
            statusItem?.length = showArrow ? AppDelegate.lengthWithArrow : AppDelegate.lengthWithoutArrow
            updateStatusBar()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bool .bool(forKey:) returns false for missing keys, so without this the
        // arrows silently default OFF on a clean install, contradicting the design.
        UserDefaults.standard.register(defaults: ["showArrow": true])
        setupStatusBar()
        loadPreferences()
        setupMenu()
        startMonitoring()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        timer?.cancel()
        procTimer?.cancel()
    }

    private func setupStatusBar() {
        let initialLength = showArrow ? AppDelegate.lengthWithArrow : AppDelegate.lengthWithoutArrow
        statusItem = NSStatusBar.system.statusItem(withLength: initialLength)
        let height = NSStatusBar.system.thickness
        let view = NetSpeedStatusView(frame: NSRect(x: 0, y: 0, width: initialLength, height: height))
        view.statusItem = statusItem
        view.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        view.alignment = .right
        if let button = statusItem.button {
            button.title = ""
            button.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                view.topAnchor.constraint(equalTo: button.topAnchor),
                view.bottomAnchor.constraint(equalTo: button.bottomAnchor)
            ])

        }
        statusView = view
    }
    
    private func loadPreferences() {
        if let savedMode = UserDefaults.standard.string(forKey: "displayMode"),
           let mode = DisplayMode(rawValue: savedMode) {
            displayMode = mode
        }
        showArrow = UserDefaults.standard.bool(forKey: "showArrow")
    }
    
    private func setupMenu() {
        let menu = NSMenu()
        let modeMenu = NSMenuItem(title: "Display Mode", action: nil, keyEquivalent: "")
        let modeSubmenu = NSMenu()
        for mode in DisplayMode.allCases {
            let item = NSMenuItem(title: mode.rawValue, action: #selector(changeDisplayMode(_:)), keyEquivalent: "")
            item.representedObject = mode
            item.state = (mode == displayMode) ? .on : .off
            modeSubmenu.addItem(item)
        }
        modeMenu.submenu = modeSubmenu
        menu.addItem(modeMenu)

        let processesItem = NSMenuItem(title: "Processes", action: nil, keyEquivalent: "")
        let processesSubmenu = NSMenu()
        processesSubmenu.delegate = self
        procMenuItem = processesItem
        procMenu = processesSubmenu
        // Header row
        let header = NSMenuItem()
        header.isEnabled = false
        header.view = buildProcessHeaderView()
        processesSubmenu.addItem(header)
        // Data rows
        for _ in 0..<procLimit {
            let mi = NSMenuItem()
            mi.isEnabled = false
            mi.view = buildProcessItemView(name: "", icon: nil, up: "", down: "")
            processesSubmenu.addItem(mi)
            procItems.append(mi)
            mi.isHidden = true
        }
        // Placeholder row
        let placeholder = NSMenuItem()
        placeholder.isEnabled = false
        placeholder.view = buildProcessItemView(name: "Loading…", icon: nil, up: "", down: "")
        processesSubmenu.addItem(placeholder)
        procPlaceholderItem = placeholder
        processesItem.submenu = processesSubmenu
        menu.addItem(processesItem)

        let iconItem = NSMenuItem(title: "Show Arrows", action: #selector(toggleArrow(_:)), keyEquivalent: "")
        iconItem.state = showArrow ? .on : .off
        menu.addItem(iconItem)

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchItem.state = isLaunchAgentInstalled() ? .on : .off
        menu.addItem(launchItem)
        launchAgentItem = launchItem
        menu.addItem(NSMenuItem.separator())
        // macOS 26 auto-decorates NSMenuItems whose action is a well-known system
        // selector (terminate:, cut:, undo:, …) with an SF Symbol on the leading
        // edge. Route through our own selector so the system doesn't recognise it.
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApp.terminate(sender)
    }
    
    private func startMonitoring() {
        restartTimer()
    }
    
    private func restartTimer() {
        timer?.cancel()
        timer = Timer.publish(every: updateInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.monitor.refresh { [weak self] in
                    guard let strongSelf = self else { return }
                    strongSelf.updateStatusBar()
                    let maxSpeed = max(strongSelf.monitor.getUploadSpeed(), strongSelf.monitor.getDownloadSpeed())
                    if strongSelf.isFastInterval {
                        if maxSpeed <= strongSelf.slowThreshold && strongSelf.updateInterval != 1.0 {
                            strongSelf.isFastInterval = false
                            strongSelf.updateInterval = 1.0
                        }
                    } else {
                        if maxSpeed >= strongSelf.fastThreshold && strongSelf.updateInterval != 0.5 {
                            strongSelf.isFastInterval = true
                            strongSelf.updateInterval = 0.5
                        }
                    }
                }
            }
    }

    private func updateStatusBar() {
        let up = monitor.getUploadSpeed()
        let down = monitor.getDownloadSpeed()

        let upString = formatSpeed(up)
        let downString = formatSpeed(down)

        var displayUp = ""
        var displayDown = ""

        switch displayMode {
        case .both:
            displayUp = upString
            displayDown = downString
        case .uploadOnly:
            displayUp = upString
            displayDown = ""
        case .downloadOnly:
            displayUp = ""
            displayDown = downString
        case .total:
            let total = up + down
            displayUp = formatSpeed(total)
            displayDown = ""
        }

        statusView?.showArrow = showArrow
        statusView?.upIcon = (displayMode == .total) ? "↓" : "↑"
        statusView?.downIcon = "↓"
        statusView?.setText(up: displayUp, down: displayDown)

    }
    
    private func isLaunchAgentInstalled() -> Bool {
        let path = NSString(string: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
        return FileManager.default.fileExists(atPath: path)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let wantsOn = sender.state != .on
        // Optimistic UI so the menu feels instant; launchctl spawns 3 subprocesses
        // and would stall the status-bar menu for hundreds of ms on the main thread.
        sender.state = wantsOn ? .on : .off
        launchctlQueue.async { [weak self] in
            guard let self = self else { return }
            if wantsOn {
                self.installLaunchAgent()
            } else {
                self.removeLaunchAgent()
            }
            let actual = self.isLaunchAgentInstalled()
            DispatchQueue.main.async {
                sender.state = actual ? .on : .off
            }
        }
    }

    private func installLaunchAgent() {
        let fm = FileManager.default
        let agentsDir = NSString(string: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents")
        try? fm.createDirectory(atPath: agentsDir, withIntermediateDirectories: true)
        let plistPath = (agentsDir as NSString).appendingPathComponent("\(agentLabel).plist")
        let execPath = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments.first ?? ""
        let dict: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [execPath],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background"
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) else {
            return
        }
        try? data.write(to: URL(fileURLWithPath: plistPath))

        // bootout first so an older registration (e.g. from a previous .app install
        // or a prior toggle) can't conflict with the fresh bootstrap below —
        // without this, macOS 26 launchctl returns EIO ("Bootstrap failed: 5").
        // Exit code is intentionally ignored: "service not loaded" is a normal case.
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(agentLabel)"])
        // bootstrap + RunAtLoad=true already starts the agent. No kickstart needed —
        // the extra kickstart/enable calls were the source of spurious error output.
        _ = runLaunchctl(["bootstrap", "gui/\(getuid())", plistPath])
    }

    private func removeLaunchAgent() {
        let plistPath = NSString(string: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(agentLabel)"])
        try? FileManager.default.removeItem(atPath: plistPath)
    }

    @discardableResult
    private func runLaunchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        // Route launchctl's own chatter away from the inherited terminal — under
        // `swift run` it otherwise dumps advisory errors to the dev's console even
        // on the normal paths (e.g. boot-out-when-not-loaded is a hard error for it).
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
    
    private func formatSpeed(_ bytesPerSec: Double) -> String {
        guard bytesPerSec > 0 else { return "0 B/s" }

        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var speed = bytesPerSec
        var index = 0

        while speed >= 1024 && index < units.count - 1 {
            speed /= 1024
            index += 1
        }

        if index <= 1 {
            return String(format: "%.0f%@", speed, units[index])
        } else {
            return String(format: "%.2f%@", speed, units[index])
        }
    }
    
    @objc private func changeDisplayMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? DisplayMode else { return }
        displayMode = mode
        
        if let menu = statusItem.menu {
            for item in menu.items {
                if let submenu = item.submenu {
                    for subitem in submenu.items {
                        if let itemMode = subitem.representedObject as? DisplayMode {
                            subitem.state = (itemMode == mode) ? .on : .off
                        }
                    }
                }
            }
        }
    }
    
    @objc private func toggleArrow(_ sender: NSMenuItem) {
        showArrow.toggle()
        sender.state = showArrow ? .on : .off
    }

    
    private struct ProcUsage {
        let pid: Int
        let name: String
        let rx: UInt64
        let tx: UInt64
    }

    private struct ProcFetchResult {
        let items: [ProcUsage]
        let parsedLineCount: Int   // How many nettop lines matched our regex.
    }

    private func buildProcessItemView(name: String, icon: NSImage?, up: String, down: String) -> NSView {
        let container = ProcessItemView(frame: NSRect(x: 0, y: 0, width: 300, height: 34))
        
        let imageView = NSImageView(frame: NSRect(x: 10, y: 9, width: 16, height: 16))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = icon
        
        let nameField = NSTextField(labelWithString: name)
        nameField.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        // Ends at x=224, leaving a 6px gap before the up/down speed columns that
        // start at x=230. Wider values let long names draw over the speed labels.
        nameField.frame = NSRect(x: 34, y: 9, width: 190, height: 16)
        nameField.lineBreakMode = .byTruncatingTail
        
        let upField = NSTextField(labelWithString: up.isEmpty ? "" : "↑ " + up)
        upField.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        upField.textColor = NSColor.secondaryLabelColor
        upField.alignment = .right
        upField.frame = NSRect(x: 230, y: 18, width: 60, height: 12)
        
        let downField = NSTextField(labelWithString: down.isEmpty ? "" : "↓ " + down)
        downField.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        downField.textColor = NSColor.secondaryLabelColor
        downField.alignment = .right
        downField.frame = NSRect(x: 230, y: 4, width: 60, height: 12)
        
        let separator = NSBox(frame: NSRect(x: 10, y: 0, width: 290, height: 1))
        separator.boxType = .separator
        
        container.addSubview(imageView)
        container.addSubview(nameField)
        container.addSubview(upField)
        container.addSubview(downField)
        container.addSubview(separator)
        
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: 300).isActive = true
        container.heightAnchor.constraint(equalToConstant: 34).isActive = true
        
        return container
    }

    private func buildProcessHeaderView() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        
        let nameHeader = NSTextField(labelWithString: "Processes")
        nameHeader.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        nameHeader.textColor = NSColor.tertiaryLabelColor
        nameHeader.frame = NSRect(x: 10, y: 4, width: 100, height: 16)
        
        let speedHeader = NSTextField(labelWithString: "NetSpeed (↑/↓)")
        speedHeader.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        speedHeader.textColor = NSColor.tertiaryLabelColor
        speedHeader.alignment = .right
        speedHeader.frame = NSRect(x: 200, y: 4, width: 90, height: 16)
        
        let separator = NSBox(frame: NSRect(x: 10, y: 0, width: 300, height: 0.5))
        separator.boxType = .separator
        
        container.addSubview(nameHeader)
        container.addSubview(speedHeader)
        container.addSubview(separator)
        
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: 300).isActive = true
        container.heightAnchor.constraint(equalToConstant: 24).isActive = true
        
        return container
    }

    private func updateProcessItemView(_ view: NSView, name: String, icon: NSImage?, up: String, down: String) {
        if let iv = view.subviews.compactMap({ $0 as? NSImageView }).first { iv.image = icon }
        let labels = view.subviews.compactMap { $0 as? NSTextField }
        if labels.count >= 3 {
            labels[0].stringValue = name
            labels[1].stringValue = up.isEmpty ? "" : "↑ " + up
            labels[2].stringValue = down.isEmpty ? "" : "↓ " + down
        }
    }

    private func updateProcessesMenu() {
        if procFetching { return }
        procFetching = true
        procFetchToken &+= 1
        let token = procFetchToken

        // Defensive watchdog: if for ANY reason the fetch's main-thread completion
        // doesn't land within 5 s, unstick the UI and show a friendly error so the
        // user doesn't sit on "Loading…" forever. The token guard makes this a no-op
        // when the fetch did land in time.
        // nettop needs ~5 s plus startup overhead; 12 s is well above that and
        // below anything that feels "permanently frozen" to the user.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) { [weak self] in
            guard let self = self, self.procFetchToken == token, self.procFetching else { return }
            self.procFetching = false
            if let pv = self.procPlaceholderItem?.view {
                self.updateProcessItemView(pv, name: "Unavailable on this system", icon: nil, up: "", down: "")
            }
            self.procPlaceholderItem?.isHidden = false
            for mi in self.procItems { mi.isHidden = true }
        }

        procQueue.async { [weak self] in
            guard let self = self else { return }
            let fetched = self.fetchTopProcesses(limit: self.procLimit)
            DispatchQueue.main.async {
                // If a watchdog already resolved this fetch, ignore the late arrival.
                guard self.procFetchToken == token else { return }

                if fetched.items.isEmpty {
                    // Two empty-list causes: either nettop gave us nothing parseable
                    // (system-level problem), or it worked but no process actually
                    // used the network between the two samples.
                    if let pv = self.procPlaceholderItem?.view {
                        let msg = fetched.parsedLineCount == 0 ? "Unavailable on this system" : "No active traffic"
                        self.updateProcessItemView(pv, name: msg, icon: nil, up: "", down: "")
                    }
                    self.procPlaceholderItem?.isHidden = false
                    for mi in self.procItems { mi.isHidden = true }
                    self.procFetching = false
                    return
                }

                self.procPlaceholderItem?.isHidden = true
                // Snapshot runningApplications once per tick — cheaper than an O(n) scan per row.
                let runningApps = Dictionary(
                    uniqueKeysWithValues: NSWorkspace.shared.runningApplications.compactMap { app -> (pid_t, NSRunningApplication)? in
                        (app.processIdentifier, app)
                    }
                )
                let list = fetched.items
                for i in 0..<self.procItems.count {
                    let mi = self.procItems[i]

                    if i < list.count {
                        mi.isHidden = false
                        let item = list[i]
                        let info = self.resolveAppInfo(item.pid, fallbackName: item.name, runningApp: runningApps[pid_t(item.pid)])
                        let down = self.formatSpeed(Double(item.rx))
                        let up = self.formatSpeed(Double(item.tx))

                        let view: ProcessItemView
                        if let v = mi.view as? ProcessItemView {
                            view = v
                            self.updateProcessItemView(v, name: info.0, icon: info.1, up: up, down: down)
                        } else {
                            view = self.buildProcessItemView(name: info.0, icon: info.1, up: up, down: down) as! ProcessItemView
                            mi.view = view
                        }

                        view.onClick = { [weak self] in
                            self?.openProcessLocation(pid: item.pid)
                        }
                        mi.isEnabled = true
                    } else {
                        // No data for this slot — hide the row entirely so the menu
                        // doesn't grow with blank separators.
                        mi.isHidden = true
                        if let pv = mi.view as? ProcessItemView { pv.onClick = nil }
                    }
                }
                self.procFetching = false
            }
        }
    }
    
    private func openProcessLocation(pid: Int) {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid_t(pid) }),
           let url = app.bundleURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            procMenu?.cancelTracking()
        }
    }

    private func getProcessPath(pid: Int) -> String? {
        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        let ret = proc_pidpath(Int32(pid), buffer, 4096)
        if ret > 0 {
            return String(cString: buffer)
        }
        return nil
    }

    private func resolveAppInfo(_ pid: Int, fallbackName: String, runningApp: NSRunningApplication? = nil) -> (String, NSImage?) {
        // Return the image unmodified — the NSImageView holding it already sets
        // imageScaling = .scaleProportionallyUpOrDown, which fits it to the 16×16
        // frame. Mutating `.size` on the returned instance would mutate the shared
        // icon used elsewhere in the system (Dock, other apps), which is nasty.

        if let app = runningApp {
            return (app.localizedName ?? fallbackName, app.icon)
        }

        // Daemons/tools fall back to proc_pidpath + icon(forFile:) which hits disk.
        // Cache per-pid so the 1 Hz submenu refresh doesn't re-resolve every tick.
        if let cached = processInfoCache[pid] {
            return cached
        }

        if let path = getProcessPath(pid: pid) {
            let name = (path as NSString).lastPathComponent
            let resolved: (String, NSImage?) = (name, NSWorkspace.shared.icon(forFile: path))
            processInfoCache[pid] = resolved
            return resolved
        }

        let resolved: (String, NSImage?) = (fallbackName, NSImage(named: NSImage.applicationIconName))
        processInfoCache[pid] = resolved
        return resolved
    }

    private func fetchTopProcesses(limit: Int) -> ProcFetchResult {
        let candidates = ["/usr/bin/nettop", "/usr/sbin/nettop"]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            FileHandle.standardError.write(Data("[NetSpeed] nettop not found in /usr/bin or /usr/sbin\n".utf8))
            return ProcFetchResult(items: [], parsedLineCount: 0)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        // -l 2 -s 1: take two snapshots 1 s apart in a single invocation.
        // macOS 26 nettop has a ~5 s warmup per call regardless of -l/-s, so
        // folding both samples into one call is far better than two sequential
        // calls (5 s vs. 10 s to first real data). We parse both snapshots below
        // and compute delta in-process, so no cross-call baseline state is needed.
        p.arguments = ["-P", "-x", "-l", "2", "-s", "1"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice

        do { try p.run() } catch {
            FileHandle.standardError.write(Data("[NetSpeed] failed to launch nettop: \(error)\n".utf8))
            return ProcFetchResult(items: [], parsedLineCount: 0)
        }

        // nettop needs ~5 s on macOS 26; timeouts sit well above that, with SIGKILL
        // as a hard belt if it actually stalls.
        let softTerm = DispatchWorkItem { [weak p] in
            guard let p = p, p.isRunning else { return }
            p.terminate()
        }
        let hardKill = DispatchWorkItem { [weak p] in
            guard let p = p, p.isRunning else { return }
            kill(p.processIdentifier, SIGKILL)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8.0, execute: softTerm)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10.0, execute: hardKill)

        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        softTerm.cancel()
        hardKill.cancel()

        guard let text = String(data: data, encoding: .utf8) else {
            return ProcFetchResult(items: [], parsedLineCount: 0)
        }
        guard let regex = AppDelegate.nettopLineRegex else {
            return ProcFetchResult(items: [], parsedLineCount: 0)
        }

        // Walk the output once, splitting samples at the repeated "time …" header.
        // Sample 1 populates `first`, sample 2 populates `second`. Pids that only
        // appear in one sample (dead or just-spawned) are dropped at the join step.
        var first: [Int: (name: String, rx: UInt64, tx: UInt64)] = [:]
        var second: [Int: (rx: UInt64, tx: UInt64)] = [:]
        var inSecondSample = false
        var parsedLines = 0

        for raw in text.split(separator: "\n") {
            let line = String(raw)
            if line.isEmpty { continue }
            if line.hasPrefix("time") {
                inSecondSample = !first.isEmpty
                continue
            }

            guard let m = regex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: line.utf16.count)),
                  m.numberOfRanges >= 6,
                  let rName = Range(m.range(at: 2), in: line),
                  let rPid = Range(m.range(at: 3), in: line),
                  let rRx = Range(m.range(at: 4), in: line),
                  let rTx = Range(m.range(at: 5), in: line) else {
                continue
            }
            parsedLines += 1

            let name = String(line[rName])
            guard let pid = Int(String(line[rPid])),
                  let rx = UInt64(String(line[rRx])),
                  let tx = UInt64(String(line[rTx])) else { continue }

            if inSecondSample {
                second[pid] = (rx: rx, tx: tx)
            } else {
                first[pid] = (name: name, rx: rx, tx: tx)
            }
        }

        var list: [ProcUsage] = []
        for (pid, f) in first {
            guard let s = second[pid] else { continue }
            let dRx = s.rx >= f.rx ? s.rx - f.rx : 0
            let dTx = s.tx >= f.tx ? s.tx - f.tx : 0
            if dRx > 0 || dTx > 0 {
                list.append(ProcUsage(pid: pid, name: f.name, rx: dRx, tx: dTx))
            }
        }
        list.sort { ($0.rx + $0.tx) > ($1.rx + $1.tx) }
        if list.count > limit { list = Array(list.prefix(limit)) }

        return ProcFetchResult(items: list, parsedLineCount: parsedLines)
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu == procMenu {
            procTimer?.cancel()
            if let pv = procPlaceholderItem?.view {
                updateProcessItemView(pv, name: "Loading…", icon: nil, up: "", down: "")
            }
            procPlaceholderItem?.isHidden = false
            // nettop itself takes ~5 s per call; polling at 1 Hz just stacks up
            // work. 5 s matches the natural sample cadence.
            procTimer = Timer.publish(every: 5.0, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.updateProcessesMenu() }
            updateProcessesMenu()
        } else if menu == statusItem.menu {
            // Re-read Launch at Login state each time the main menu opens —
            // the plist can be removed externally or the kickstart may have failed.
            launchAgentItem?.state = isLaunchAgentInstalled() ? .on : .off
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu == procMenu {
            procTimer?.cancel()
            procTimer = nil
            processInfoCache.removeAll()
        }
    }

}
