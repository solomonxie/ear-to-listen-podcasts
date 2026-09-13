import Foundation
import Network

/// Shared reachability signal so provider/sync/playback code can tell a real failure
/// (bad credentials, expired URL) apart from "the device is offline" and message accordingly.
final class NetworkMonitor: @unchecked Sendable {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var _isConnected = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.withLock { self._isConnected = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "NetworkMonitor"))
    }

    var isConnected: Bool { lock.withLock { _isConnected } }
}
