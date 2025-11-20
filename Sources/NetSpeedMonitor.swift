import Foundation
import SystemConfiguration

class NetSpeedMonitor {
    private let queue = DispatchQueue(label: "com.netspeed.monitor", attributes: .concurrent)
    private var _previousByInterface: [String: (up: UInt64, down: UInt64)] = [:]
    private var _lastTime = Date()
    private var _currentUp: Double = 0
    private var _currentDown: Double = 0
    private var _isInitialized = false
    private var _upHistory: [Double] = []
    private var _downHistory: [Double] = []
    private let maxWindow = 5
    enum Scope { case primary, all }
    var scope: Scope = .primary
    
    private var previousByInterface: [String: (up: UInt64, down: UInt64)] {
        get { queue.sync { _previousByInterface } }
        set { queue.async(flags: .barrier) { self._previousByInterface = newValue } }
    }
    
    private var lastTime: Date {
        get { queue.sync { _lastTime } }
        set { queue.async(flags: .barrier) { self._lastTime = newValue } }
    }
    
    private var currentUp: Double {
        get { queue.sync { _currentUp } }
        set { queue.async(flags: .barrier) { self._currentUp = newValue } }
    }
    
    private var currentDown: Double {
        get { queue.sync { _currentDown } }
        set { queue.async(flags: .barrier) { self._currentDown = newValue } }
    }
    
    private var isInitialized: Bool {
        get { queue.sync { _isInitialized } }
        set { queue.async(flags: .barrier) { self._isInitialized = newValue } }
    }

    init() {
        initializeData()
    }
    
    private func initializeData() {
        queue.async(flags: .barrier) {
            self._previousByInterface = NetSpeedMonitor.fetchNetworkBytesByInterface()
            self._lastTime = Date()
            self._isInitialized = true
        }
    }
    
    func getUploadSpeed() -> Double { currentUp }
    func getDownloadSpeed() -> Double { currentDown }

    func refresh(completion: (() -> Void)? = nil) {
        queue.async(flags: .barrier) {
            if !self._isInitialized {
                self._previousByInterface = NetSpeedMonitor.fetchNetworkBytesByInterface()
                self._lastTime = Date()
                self._isInitialized = true
            }
            let now = Date()
            let diff = now.timeIntervalSince(self._lastTime)
            if diff <= 0 { return }

            let ifaceMap = NetSpeedMonitor.fetchNetworkBytesByInterface()
            let primary = NetSpeedMonitor.primaryInterfaceName()

            var upDeltaTotal: UInt64 = 0
            var downDeltaTotal: UInt64 = 0
            var consideredCount = 0

            for (name, bytes) in ifaceMap {
                switch self.scope {
                case .primary:
                    if let p = primary {
                        if name != p { continue }
                    } else {
                        if !(name.hasPrefix("en") || name.hasPrefix("pdp")) { continue }
                    }
                case .all:
                    if name == "lo0" { continue }
                }
                let prev = self._previousByInterface[name] ?? (0, 0)
                upDeltaTotal &+= NetSpeedMonitor.deltaBytes(prev: prev.up, curr: bytes.up)
                downDeltaTotal &+= NetSpeedMonitor.deltaBytes(prev: prev.down, curr: bytes.down)
                consideredCount += 1
            }

            if consideredCount == 0 {
                self._upHistory.removeAll()
                self._downHistory.removeAll()
                self._currentUp = 0
                self._currentDown = 0
                self._previousByInterface = ifaceMap
                self._lastTime = now
                if let completion = completion { DispatchQueue.main.async { completion() } }
                return
            }

            let newUp = max(0, Double(upDeltaTotal) / diff)
            let newDown = max(0, Double(downDeltaTotal) / diff)

            self._upHistory.append(newUp)
            if self._upHistory.count > self.maxWindow { self._upHistory.removeFirst() }
            self._downHistory.append(newDown)
            if self._downHistory.count > self.maxWindow { self._downHistory.removeFirst() }

            let upWindow = newUp >= 1_048_576 ? 1 : 3
            let downWindow = newDown >= 1_048_576 ? 1 : 3
            let upSliceCount = min(upWindow, self._upHistory.count)
            let downSliceCount = min(downWindow, self._downHistory.count)
            let upAvg = self._upHistory.suffix(upSliceCount).reduce(0, +) / Double(upSliceCount)
            let downAvg = self._downHistory.suffix(downSliceCount).reduce(0, +) / Double(downSliceCount)

            self._currentUp = upAvg
            self._currentDown = downAvg
            self._previousByInterface = ifaceMap
            self._lastTime = now
            if let completion = completion {
                DispatchQueue.main.async { completion() }
            }
        }
    }
    
    private func updateIfNeeded() {}
    
    static func fetchNetworkBytesByInterface() -> [String: (up: UInt64, down: UInt64)] {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>? = nil
        var result: [String: (UInt64, UInt64)] = [:]
        
        defer {
            if ifaddrPtr != nil {
                freeifaddrs(ifaddrPtr)
            }
        }
        
        guard getifaddrs(&ifaddrPtr) == 0 else {
            print("Error getting network interfaces: \(errno)")
            return [:]
        }
        
        guard let firstAddr = ifaddrPtr else {
            return [:]
        }
        
        var ptr = firstAddr
        while true {
            guard let ifaAddr = ptr.pointee.ifa_addr else {
                if ptr.pointee.ifa_next == nil { break }
                ptr = ptr.pointee.ifa_next!
                continue
            }
            let family = ifaAddr.pointee.sa_family

            if family == UInt8(AF_LINK), let data = ptr.pointee.ifa_data {
                let name = String(cString: ptr.pointee.ifa_name)
                let flags = UInt32(ptr.pointee.ifa_flags)
                let isUp = (flags & UInt32(IFF_UP)) != 0
                let isRunning = (flags & UInt32(IFF_RUNNING)) != 0
                if name != "lo0" && isUp && isRunning {
                    let networkData = data.bindMemory(to: if_data.self, capacity: 1).pointee
                    let up = UInt64(networkData.ifi_obytes)
                    let down = UInt64(networkData.ifi_ibytes)
                    result[name] = (up, down)
                }
            }
            
            if ptr.pointee.ifa_next == nil { break }
            ptr = ptr.pointee.ifa_next!
        }
        
        return result
    }

    private static func shouldIncludeInterface(named name: String, flags: UInt32) -> Bool { true }

    private static func deltaBytes(prev: UInt64, curr: UInt64) -> UInt64 {
        if curr >= prev { return curr - prev }
        return 0
    }

    static func primaryInterfaceName() -> String? {
        let store = SCDynamicStoreCreate(nil, "NetSpeed" as CFString, nil, nil)
        if let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
           let name = dict["PrimaryInterface"] as? String {
            return name
        }
        if let dict6 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv6" as CFString) as? [String: Any],
           let name = dict6["PrimaryInterface"] as? String {
            return name
        }
        return nil
    }
}
