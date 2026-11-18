import Flutter
import Foundation
import NetworkExtension
import UIKit

/// The native side of `VpnChannel` (lib/core/vpn_channel.dart) on iOS: the same channels the Android activity answers
/// (`kumo/control`, `kumo/status`, `kumo/traffic`), with what an iPhone can do. The connection itself is the tunnel
/// extension (KumoTunnel); this class keeps its `NETunnelProviderManager`, starts and stops it, and tells the app how it is.
///
/// What only Android has (the widgets, the tile, per-app routing, the real delay test of a temporary core, the updates of
/// subscriptions in the background) is answered with nothing, so the app goes on without it.
final class KumoVpn: NSObject, FlutterStreamHandler {
    static let shared = KumoVpn()

    /// The bundle id of the tunnel extension (its target in the project).
    static let tunnelBundleId = "app.kumo.vpn.tunnel"

    private var manager: NETunnelProviderManager?
    private var sink: FlutterEventSink?
    private var observer: NSObjectProtocol?
    private var wasStarting = false

    func register(with messenger: FlutterBinaryMessenger) {
        let control = FlutterMethodChannel(name: "kumo/control", binaryMessenger: messenger)
        control.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
        FlutterEventChannel(name: "kumo/status", binaryMessenger: messenger).setStreamHandler(self)
        FlutterEventChannel(name: "kumo/traffic", binaryMessenger: messenger).setStreamHandler(IdleStream())
    }

    // MARK: the channel

    private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "prepare":
            // Saving the VPN configuration is what makes iOS ask the user for the permission.
            loadManager(create: true) { manager, error in
                result(manager != nil && error == nil)
            }
        case "start":
            guard let config = args["config"] as? String, !config.isEmpty else {
                result(FlutterError(code: "bad_args", message: "config is empty", details: nil))
                return
            }
            loadManager(create: true) { manager, error in
                guard let manager else {
                    result(FlutterError(code: "start_failed", message: error?.localizedDescription ?? "no VPN configuration", details: nil))
                    return
                }
                do {
                    self.wasStarting = true
                    try manager.connection.startVPNTunnel(options: ["configContent": config as NSString])
                    result(nil)
                } catch {
                    result(FlutterError(code: "start_failed", message: error.localizedDescription, details: nil))
                }
            }
        case "stop":
            manager?.connection.stopVPNTunnel()
            result(nil)
        case "status":
            result(stateMap(for: manager?.connection.status ?? .invalid, error: nil))
        case "filesDir":
            result(filesDirectory().path)
        case "readFile":
            result(try? String(contentsOf: file(args["name"] as? String), encoding: .utf8))
        case "writeFile":
            try? (args["content"] as? String ?? "").write(to: file(args["name"] as? String), atomically: true, encoding: .utf8)
            result(nil)
        case "deleteFile":
            try? FileManager.default.removeItem(at: file(args["name"] as? String))
            result(nil)
        case "moveAside":
            let from = file(args["name"] as? String)
            let to = from.appendingPathExtension("broken")
            try? FileManager.default.removeItem(at: to)
            try? FileManager.default.moveItem(at: from, to: to)
            result(nil)
        case "isTv", "canInstall", "allowInstall", "batteryUnrestricted":
            result(false)
        case "vpnSettings":
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
            result(nil)
        case "openUrl":
            if let text = args["url"] as? String, let url = URL(string: text) {
                UIApplication.shared.open(url)
                result(true)
            } else {
                result(false)
            }
        default:
            // The rest is Android's (the widgets, the tile, the temporary test cores ...).
            result(nil)
        }
    }

    // MARK: files (the small store of the app)

    private func filesDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kumo", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// The file of a name, always inside the folder of the app (a name never leaves it).
    private func file(_ name: String?) -> URL {
        let safe = (name ?? "").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
        return filesDirectory().appendingPathComponent(safe.isEmpty ? "unnamed" : safe)
    }

    // MARK: the VPN configuration of the system

    /// The manager of the tunnel: the one the system has, or (with [create]) a new one saved now.
    private func loadManager(create: Bool, _ done: @escaping (NETunnelProviderManager?, Error?) -> Void) {
        if let manager {
            done(manager, nil)
            return
        }
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self else { return }
            if let found = managers?.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.tunnelBundleId
            }) {
                self.adopt(found)
                done(found, nil)
                return
            }
            guard create else {
                done(nil, error)
                return
            }
            let manager = NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Self.tunnelBundleId
            proto.serverAddress = "Kumo"
            manager.protocolConfiguration = proto
            manager.localizedDescription = "Kumo"
            manager.isEnabled = true
            manager.saveToPreferences { error in
                if let error {
                    done(nil, error)
                    return
                }
                // A saved configuration is loaded again before it is used (the system's own requirement).
                manager.loadFromPreferences { error in
                    if let error {
                        done(nil, error)
                        return
                    }
                    self.adopt(manager)
                    done(manager, nil)
                }
            }
        }
    }

    private func adopt(_ manager: NETunnelProviderManager) {
        self.manager = manager
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: .NEVPNStatusDidChange, object: nil, queue: .main
            ) { [weak self] note in
                guard let self, let connection = note.object as? NEVPNConnection else { return }
                self.statusChanged(connection)
            }
        }
    }

    // MARK: the state of the app

    private func stateMap(for status: NEVPNStatus, error: String?) -> [String: Any?] {
        let name: String
        switch status {
        case .connecting, .reasserting: name = "starting"
        case .connected: name = "started"
        case .disconnecting: name = "stopping"
        default: name = error == nil ? "stopped" : "error"
        }
        return ["status": name, "error": error, "standby": false]
    }

    private func statusChanged(_ connection: NEVPNConnection) {
        let status = connection.status
        if status == .disconnected, wasStarting {
            wasStarting = false
            // Why it ended (a start that failed, a core that stopped): told to the app as the error.
            connection.fetchLastDisconnectError { [weak self] error in
                self?.sink?(self?.stateMap(for: status, error: error?.localizedDescription))
            }
            return
        }
        if status == .connected { wasStarting = false }
        sink?(stateMap(for: status, error: nil))
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        // What the system knows now, for an app that starts while the tunnel runs.
        loadManager(create: false) { [weak self] manager, _ in
            guard let self, let manager else {
                events(self?.stateMap(for: .disconnected, error: nil))
                return
            }
            events(self.stateMap(for: manager.connection.status, error: nil))
        }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }
}

/// A stream that never gives anything (the speeds of the tunnel are not sent to the app yet).
private final class IdleStream: NSObject, FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { nil }
    func onCancel(withArguments arguments: Any?) -> FlutterError? { nil }
}
