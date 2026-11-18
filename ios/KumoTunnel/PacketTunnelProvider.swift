import Foundation
import Libbox
import NetworkExtension

/// The VPN of Kumo on iOS: the tunnel extension. The system starts it when the app asks (see KumoVpn.swift in Runner) and
/// it runs sing-box (`Libbox`) inside itself with the configuration the app hands over, as the service does on Android.
///
/// Written against the framework built from sing-box 1.13.21 (see .github/workflows/ios-test.yml). An extension that uses more
/// than about 50 MB is ended by the system, so the configuration it gets must stay small.
class PacketTunnelProvider: NEPacketTunnelProvider {
    private(set) var commandServer: LibboxCommandServer?
    private lazy var platform = KumoPlatformInterface(self)

    /// The folder the app and the extension share (an App Group): the configuration and what the core writes.
    static func sharedDirectory() -> URL {
        let id = (Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String) ?? "group.app.kumo.vpn"
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
            return url
        }
        // Without the group (an unsigned build) the extension still has a folder of its own.
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    override func startTunnel(options: [String: NSObject]?) async throws {
        let base = Self.sharedDirectory()
        let working = base.appendingPathComponent("Working", isDirectory: true)
        let temp = base.appendingPathComponent("Temp", isDirectory: true)
        for dir in [working, temp] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // The app gives the configuration with the start request; started by the system alone (on demand), the one saved
        // by the last connection is used.
        let saved = base.appendingPathComponent("active_config.json")
        let config: String
        if let given = options?["configContent"] as? String, !given.isEmpty {
            config = given
            try? given.write(to: saved, atomically: true, encoding: .utf8)
        } else if let text = try? String(contentsOf: saved, encoding: .utf8), !text.isEmpty {
            config = text
        } else {
            throw KumoTunnelError("there is no configuration to start")
        }

        let setup = LibboxSetupOptions()
        setup.basePath = base.path
        setup.workingPath = working.path
        setup.tempPath = temp.path
        setup.logMaxLines = 2000
        setup.debug = false
        var setupError: NSError?
        LibboxSetup(setup, &setupError)
        if let setupError {
            throw KumoTunnelError("setup of the core: \(setupError.localizedDescription)")
        }

        var serverError: NSError?
        guard let server = LibboxNewCommandServer(platform, platform, &serverError) else {
            throw KumoTunnelError("the core's server: \(serverError?.localizedDescription ?? "not made")")
        }
        commandServer = server
        do {
            try server.start()
            try server.startOrReloadService(config, options: LibboxOverrideOptions())
        } catch {
            stopCore()
            throw KumoTunnelError("start of the core: \(error.localizedDescription)")
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        stopCore()
    }

    /// Ends the service and the server of the core, once.
    func stopCore() {
        guard let server = commandServer else { return }
        commandServer = nil
        try? server.closeService()
        platform.reset()
        server.close()
    }

    func writeMessage(_ message: String) {
        // 2 is an error in the levels of sing-box.
        commandServer?.writeMessage(2, message: message)
    }

    // The phone sleeps and wakes: the core is told, to save the battery and to find the network again.
    override func sleep() async {
        commandServer?.pause()
    }

    override func wake() {
        commandServer?.wake()
    }
}

struct KumoTunnelError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}
