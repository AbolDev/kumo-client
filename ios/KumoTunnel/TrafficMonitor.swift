import Foundation
import Libbox

/// The speeds and the totals of the tunnel, as the core counts them. The extension asks its own core (a client of the command server
/// that runs inside it) for the status every second and keeps the last one; the app asks the extension for it (see
/// `handleAppMessage` of PacketTunnelProvider and KumoVpn.swift), so the app does not have to link the framework of sing-box.
final class TrafficMonitor: NSObject, LibboxCommandClientHandlerProtocol {
    private var client: LibboxCommandClient?
    private let lock = NSLock()
    private var last = Status()

    struct Status {
        var up: Int64 = 0
        var down: Int64 = 0
        var upTotal: Int64 = 0
        var downTotal: Int64 = 0
        /// What the extension holds in memory, in bytes (an extension is ended by the system above about 50 MB).
        var memory: Int64 = 0
    }

    func start() {
        let options = LibboxCommandClientOptions()
        options.addCommand(LibboxCommandStatus)
        // One second, in nanoseconds.
        options.statusInterval = 1_000_000_000
        guard let client = LibboxNewCommandClient(self, options) else { return }
        self.client = client
        // The server is started before this, but it may not accept at once: a few tries.
        DispatchQueue.global().async {
            for _ in 0..<10 {
                if (try? client.connect()) != nil { return }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }

    func stop() {
        try? client?.disconnect()
        client = nil
        lock.lock()
        last = Status()
        lock.unlock()
    }

    /// The last status as the text the app reads.
    func json() -> Data {
        lock.lock()
        let s = last
        lock.unlock()
        let text = "{\"up\":\(s.up),\"down\":\(s.down),\"upTotal\":\(s.upTotal),\"downTotal\":\(s.downTotal),\"memory\":\(s.memory)}"
        return Data(text.utf8)
    }

    // MARK: what the core sends

    func writeStatus(_ message: LibboxStatusMessage?) {
        guard let message else { return }
        lock.lock()
        last = Status(
            up: message.uplink, down: message.downlink, upTotal: message.uplinkTotal, downTotal: message.downlinkTotal,
            memory: message.memory)
        lock.unlock()
    }

    // The rest of what a client can be sent is not asked for.
    func clearLogs() {}
    func connected() {}
    func disconnected(_ message: String?) {}
    func initializeClashMode(_ modeList: LibboxStringIteratorProtocol?, currentMode: String?) {}
    func setDefaultLogLevel(_ level: Int32) {}
    func updateClashMode(_ newMode: String?) {}
    func write(_ events: LibboxConnectionEvents?) {}
    func writeGroups(_ message: LibboxOutboundGroupIteratorProtocol?) {}
    func writeLogs(_ messageList: LibboxLogIteratorProtocol?) {}
}
