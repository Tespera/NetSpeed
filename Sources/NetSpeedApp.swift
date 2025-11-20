import Cocoa

@main
class NetSpeedApplication: NSObject, NSApplicationDelegate {
    private let appDelegate = AppDelegate()
    
    static func main() {
        let app = NSApplication.shared
        let delegate = NetSpeedApplication()
        app.delegate = delegate.appDelegate
        app.run()
    }
}
