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
    private var preferencesWindow: NSWindow?
    private var fixedLength: CGFloat = 42
    private var statusView: NetSpeedStatusView?
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
    private var previousProcTotals: [Int: (rx: UInt64, tx: UInt64)] = [:]
    
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
            UserDefaults.standard.set(updateInterval, forKey: "updateInterval")
            restartTimer()
        }
    }
    
    private var showArrow: Bool = true {
        didSet {
            UserDefaults.standard.set(showArrow, forKey: "showArrow")
            updateStatusBar()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        statusItem = NSStatusBar.system.statusItem(withLength: fixedLength)
        let height = NSStatusBar.system.thickness
        let view = NetSpeedStatusView(frame: NSRect(x: 0, y: 0, width: fixedLength, height: height))
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
        updateInterval = 1.0
        
        showArrow = UserDefaults.standard.bool(forKey: "showArrow")
        statusItem.length = showArrow ? 48 : 42
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
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
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
        if sender.state == .on {
            removeLaunchAgent()
            sender.state = .off
        } else {
            installLaunchAgent()
            sender.state = .on
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
        if let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) {
            try? data.write(to: URL(fileURLWithPath: plistPath))
            runLaunchctl(["bootstrap", "gui/\(getuid())", plistPath])
            runLaunchctl(["enable", "gui/\(getuid())/\(agentLabel)"])
            runLaunchctl(["kickstart", "-k", "gui/\(getuid())/\(agentLabel)"])
        }
    }

    private func removeLaunchAgent() {
        let plistPath = NSString(string: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
        runLaunchctl(["disable", "gui/\(getuid())/\(agentLabel)"])
        runLaunchctl(["bootout", "gui/\(getuid())", plistPath])
        try? FileManager.default.removeItem(atPath: plistPath)
    }

    private func runLaunchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
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
    
    @objc private func changeUpdateInterval(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? TimeInterval else { return }
        updateInterval = interval
        
        if let menu = statusItem.menu {
            for item in menu.items {
                if let submenu = item.submenu {
                    for subitem in submenu.items {
                        if let itemInterval = subitem.representedObject as? TimeInterval {
                            subitem.state = (itemInterval == interval) ? .on : .off
                        }
                    }
                }
            }
        }
    }
    
    @objc private func toggleArrow(_ sender: NSMenuItem) {
        showArrow.toggle()
        sender.state = showArrow ? .on : .off
        statusItem.length = showArrow ? 48 : 42
        updateStatusBar()
    }

    
    private struct ProcUsage {
        let pid: Int
        let name: String
        let rx: UInt64
        let tx: UInt64
    }

    private func buildProcessItemView(name: String, icon: NSImage?, up: String, down: String) -> NSView {
        let container = ProcessItemView(frame: NSRect(x: 0, y: 0, width: 300, height: 34))
        
        let imageView = NSImageView(frame: NSRect(x: 10, y: 9, width: 16, height: 16))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = icon
        
        let nameField = NSTextField(labelWithString: name)
        nameField.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        nameField.frame = NSRect(x: 34, y: 9, width: 260, height: 16)
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
        procQueue.async { [weak self] in
            guard let self = self else { return }
            let list = self.fetchTopProcesses(limit: self.procLimit)
            DispatchQueue.main.async {
                self.procPlaceholderItem?.isHidden = true
                for i in 0..<self.procItems.count {
                    let mi = self.procItems[i]
                    mi.isHidden = false
                    
                    if i < list.count {
                        let item = list[i]
                        let info = self.resolveAppInfo(item.pid, fallbackName: item.name)
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
                        mi.representedObject = item.pid
                        mi.target = nil
                        mi.action = nil
                    } else {
                        if let v = mi.view {
                            self.updateProcessItemView(v, name: "", icon: nil, up: "", down: "")
                            if let pv = v as? ProcessItemView {
                                pv.onClick = nil
                            }
                        }
                        mi.isEnabled = false
                        mi.representedObject = nil
                        mi.action = nil
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

    private func resolveAppInfo(_ pid: Int, fallbackName: String) -> (String, NSImage?) {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid_t(pid) }) {
            let name = app.localizedName ?? fallbackName
            var img = app.icon
            if let i = img { i.size = NSSize(width: 16, height: 16); img = i }
            return (name, img)
        }
        
        if let path = getProcessPath(pid: pid) {
            let name = (path as NSString).lastPathComponent
            let img = NSWorkspace.shared.icon(forFile: path)
            img.size = NSSize(width: 16, height: 16)
            return (name, img)
        }

        let img = NSImage(named: NSImage.applicationIconName)
        if let i = img { i.size = NSSize(width: 16, height: 16) }
        return (fallbackName, img)
    }

    private func fetchTopProcesses(limit: Int) -> [ProcUsage] {
        var result: [Int: (name: String, rx: UInt64, tx: UInt64)] = [:]
        let p = Process()
        let candidates = ["/usr/bin/nettop", "/usr/sbin/nettop"]
        let path = candidates.first { FileManager.default.fileExists(atPath: $0) } ?? "/usr/bin/nettop"
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-P", "-x", "-l", "1"]
        let out = Pipe()
        p.standardOutput = out
        let err = Pipe()
        p.standardError = err
        do { try p.run() } catch { return [] }
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        
        let pattern = "^(\\S+)\\s+(.+)\\.(\\d+)\\s+(\\d+)\\s+(\\d+)"
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        var seenPids = Set<Int>()
        
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            if line.isEmpty { continue }
            
            guard let r = regex,
                  let m = r.firstMatch(in: line, options: [], range: NSRange(location: 0, length: line.utf16.count)),
                  m.numberOfRanges >= 6,
                  let rName = Range(m.range(at: 2), in: line),
                  let rPid = Range(m.range(at: 3), in: line),
                  let rRx = Range(m.range(at: 4), in: line),
                  let rTx = Range(m.range(at: 5), in: line) else {
                continue
            }
            
            let name = String(line[rName])
            guard let pid = Int(String(line[rPid])),
                  let rxTotal = UInt64(String(line[rRx])),
                  let txTotal = UInt64(String(line[rTx])) else { continue }
            
            seenPids.insert(pid)
            
            let prev = previousProcTotals[pid]
            var dRx: UInt64 = 0
            var dTx: UInt64 = 0
            
            if let p = prev {
                if rxTotal >= p.rx { dRx = rxTotal - p.rx }
                else { dRx = rxTotal }
                
                if txTotal >= p.tx { dTx = txTotal - p.tx }
                else { dTx = txTotal }
            } else {
                dRx = 0
                dTx = 0
            }
            previousProcTotals[pid] = (rx: rxTotal, tx: txTotal)
            
            if dRx > 0 || dTx > 0 {
                result[pid] = (name: name, rx: dRx, tx: dTx)
            }
        }
        
        // Cleanup stale PIDs
        previousProcTotals = previousProcTotals.filter { seenPids.contains($0.key) }
        
        var list: [ProcUsage] = result.map { ProcUsage(pid: $0.key, name: $0.value.name, rx: $0.value.rx, tx: $0.value.tx) }
        list.sort { ($0.rx + $0.tx) > ($1.rx + $1.tx) }
        if list.count > limit { list = Array(list.prefix(limit)) }
        return list
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu == procMenu {
            procTimer?.cancel()
            procQueue.async { [weak self] in self?.previousProcTotals.removeAll() }
            procPlaceholderItem?.view = buildProcessItemView(name: "Loading…", icon: nil, up: "", down: "")
            procPlaceholderItem?.isHidden = false
            procTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.updateProcessesMenu() }
            updateProcessesMenu()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu == procMenu {
            procTimer?.cancel()
            procTimer = nil
        }
    }

}
