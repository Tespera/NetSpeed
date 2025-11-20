import Cocoa
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
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
    
    private var showIcons: Bool = true {
        didSet {
            UserDefaults.standard.set(showIcons, forKey: "showIcons")
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
        
        showIcons = UserDefaults.standard.bool(forKey: "showIcons")
        statusItem.length = showIcons ? 48 : 42
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
        
        let iconItem = NSMenuItem(title: "Show Icons", action: #selector(toggleIcons(_:)), keyEquivalent: "")
        iconItem.state = showIcons ? .on : .off
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

        statusView?.showIcons = showIcons
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
    
    @objc private func toggleIcons(_ sender: NSMenuItem) {
        showIcons.toggle()
        sender.state = showIcons ? .on : .off
        statusItem.length = showIcons ? 48 : 42
        updateStatusBar()
    }

    
}
