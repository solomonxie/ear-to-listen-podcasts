import Foundation

/// Whether the library on screen is the sample one (`DemoData/`). While it is, backups, the change log and the first-run restore stand down, so
/// nothing of it reaches the listener's own copies.
enum AppMode {
    static let demoKey = "demo.isOn"

    static var isDemo: Bool { UserDefaults.standard.bool(forKey: demoKey) }
}
