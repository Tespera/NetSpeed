import Foundation
import SystemConfiguration

class NetSpeedMonitor {
    // Serial queue. All mutable state below is only touched inside queue blocks.
    private let queue = DispatchQueue(label: "com.netspeed.monitor")
    private var previousByInterface: [String: (up: UInt64, down: UInt64)] = [:]
    private var lastTime = Date()
    private var currentUp: Double = 0
    private var currentDown: Double = 0
    private var isInitialized = false
    private var upHistory: [Double] = []
    private var downHistory: [Double] = []
    private let maxWindow = 5

    enum Scope { case primary, all }
    var scope: Scope = .primary

    init() {
        queue.async {
            self.previousByInterface = NetSpeedMonitor.fetchNetworkBytesByInterface()
            self.lastTime = Date()
            self.isInitialized = true
        }
    }

    func getUploadSpeed() -> Double { queue.sync { currentUp } }
    func getDownloadSpeed() -> Double { queue.sync { currentDown } }

    func refresh(completion: (() -> Void)? = nil) {
        queue.async {
            if !self.isInitialized {
                self.previousByInterface = NetSpeedMonitor.fetchNetworkBytesByInterface()
                self.lastTime = Date()
                self.isInitialized = true
            }
            let now = Date()
            let diff = now.timeIntervalSince(self.lastTime)
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
                let prev = self.previousByInterface[name] ?? (0, 0)
                upDeltaTotal &+= NetSpeedMonitor.deltaBytes(prev: prev.up, curr: bytes.up)
                downDeltaTotal &+= NetSpeedMonitor.deltaBytes(prev: prev.down, curr: bytes.down)
                consideredCount += 1
            }

            if consideredCount == 0 {
                self.upHistory.removeAll()
                self.downHistory.removeAll()
                self.currentUp = 0
                self.currentDown = 0
                self.previousByInterface = ifaceMap
                self.lastTime = now
                if let completion = completion { DispatchQueue.main.async { completion() } }
                return
            }

            let newUp = max(0, Double(upDeltaTotal) / diff)
            let newDown = max(0, Double(downDeltaTotal) / diff)

            self.upHistory.append(newUp)
            if self.upHistory.count > self.maxWindow { self.upHistory.removeFirst() }
            self.downHistory.append(newDown)
            if self.downHistory.count > self.maxWindow { self.downHistory.removeFirst() }

            // Responsive when fast (>= 1 MiB/s), smoothed with 3-sample moving average
            // when slow — the threshold is binary (1024*1024), not SI, to match formatSpeed.
            let upWindow = newUp >= 1_048_576 ? 1 : 3
            let downWindow = newDown >= 1_048_576 ? 1 : 3
            let upSliceCount = min(upWindow, self.upHistory.count)
            let downSliceCount = min(downWindow, self.downHistory.count)
            let upAvg = self.upHistory.suffix(upSliceCount).reduce(0, +) / Double(upSliceCount)
            let downAvg = self.downHistory.suffix(downSliceCount).reduce(0, +) / Double(downSliceCount)

            self.currentUp = upAvg
            self.currentDown = downAvg
            self.previousByInterface = ifaceMap
            self.lastTime = now
            if let completion = completion {
                DispatchQueue.main.async { completion() }
            }
        }
    }

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

    private static func deltaBytes(prev: UInt64, curr: UInt64) -> UInt64 {
        curr >= prev ? curr - prev : 0
    }

    private static let dynamicStore: SCDynamicStore? =
        SCDynamicStoreCreate(nil, "NetSpeed" as CFString, nil, nil)

    static func primaryInterfaceName() -> String? {
        guard let store = dynamicStore else { return nil }
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
