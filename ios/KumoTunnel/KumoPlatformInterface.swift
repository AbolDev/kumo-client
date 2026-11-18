import Foundation
import Libbox
import Network
import NetworkExtension
import os

/// What the core asks of the system, on iOS: the tunnel (settings and the file descriptor of the packets), the network that is
/// in use, and the answers to the questions it has no answer to here. Adapted from `ExtensionPlatformInterface.swift` of
/// sing-box-for-apple (GPL-3.0, SagerNet), cut to what 1.13.21 asks and to what an iPhone has.
final class KumoPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {
    private static let log = Logger(subsystem: "app.kumo.vpn.tunnel", category: "platform")

    private weak var tunnel: PacketTunnelProvider?
    private var networkSettings: NEPacketTunnelNetworkSettings?
    private var monitor: NWPathMonitor?

    init(_ tunnel: PacketTunnelProvider) {
        self.tunnel = tunnel
    }

    // MARK: the tunnel

    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let options, let ret0_, let tunnel else {
            throw KumoTunnelError("openTun: no options")
        }
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        if options.getAutoRoute() {
            settings.mtu = NSNumber(value: options.getMTU())

            let dns = try options.getDNSServerAddress().value
            if !dns.isEmpty {
                settings.dnsSettings = NEDNSSettings(servers: [dns])
            }

            var v4Addresses: [String] = []
            var v4Masks: [String] = []
            if let it = options.getInet4Address() {
                while it.hasNext() {
                    guard let p = it.next() else { break }
                    v4Addresses.append(p.address())
                    v4Masks.append(p.mask())
                }
            }
            let v4 = NEIPv4Settings(addresses: v4Addresses, subnetMasks: v4Masks)
            var v4Routes: [NEIPv4Route] = []
            if let it = options.getInet4RouteAddress() {
                while it.hasNext() {
                    guard let p = it.next() else { break }
                    v4Routes.append(NEIPv4Route(destinationAddress: p.address(), subnetMask: p.mask()))
                }
            }
            v4.includedRoutes = v4Routes.isEmpty ? [NEIPv4Route.default()] : v4Routes
            var v4Excluded: [NEIPv4Route] = []
            if let it = options.getInet4RouteExcludeAddress() {
                while it.hasNext() {
                    guard let p = it.next() else { break }
                    v4Excluded.append(NEIPv4Route(destinationAddress: p.address(), subnetMask: p.mask()))
                }
            }
            v4.excludedRoutes = v4Excluded
            settings.ipv4Settings = v4

            var v6Addresses: [String] = []
            var v6Prefixes: [NSNumber] = []
            if let it = options.getInet6Address() {
                while it.hasNext() {
                    guard let p = it.next() else { break }
                    v6Addresses.append(p.address())
                    v6Prefixes.append(NSNumber(value: p.prefix()))
                }
            }
            let v6 = NEIPv6Settings(addresses: v6Addresses, networkPrefixLengths: v6Prefixes)
            var v6Routes: [NEIPv6Route] = []
            if let it = options.getInet6RouteAddress() {
                while it.hasNext() {
                    guard let p = it.next() else { break }
                    v6Routes.append(NEIPv6Route(destinationAddress: p.address(), networkPrefixLength: NSNumber(value: p.prefix())))
                }
            }
            v6.includedRoutes = v6Routes.isEmpty ? [NEIPv6Route.default()] : v6Routes
            var v6Excluded: [NEIPv6Route] = []
            if let it = options.getInet6RouteExcludeAddress() {
                while it.hasNext() {
                    guard let p = it.next() else { break }
                    v6Excluded.append(NEIPv6Route(destinationAddress: p.address(), networkPrefixLength: NSNumber(value: p.prefix())))
                }
            }
            v6.excludedRoutes = v6Excluded
            settings.ipv6Settings = v6
        }

        if options.isHTTPProxyEnabled() {
            let proxy = NEProxySettings()
            let server = NEProxyServer(address: options.getHTTPProxyServer(), port: Int(options.getHTTPProxyServerPort()))
            proxy.httpServer = server
            proxy.httpsServer = server
            proxy.httpEnabled = true
            proxy.httpsEnabled = true
            var bypass: [String] = []
            if let it = options.getHTTPProxyBypassDomain() {
                while it.hasNext() { bypass.append(it.next()) }
            }
            if !bypass.isEmpty { proxy.exceptionList = bypass }
            var match: [String] = []
            if let it = options.getHTTPProxyMatchDomain() {
                while it.hasNext() { match.append(it.next()) }
            }
            if !match.isEmpty { proxy.matchDomains = match }
            settings.proxySettings = proxy
        }

        networkSettings = settings
        // The core asks from its own thread and waits for the answer.
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        tunnel.setTunnelNetworkSettings(settings) { error in
            failure = error
            done.signal()
        }
        done.wait()
        if let failure { throw failure }

        if let fd = tunnel.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            ret0_.pointee = fd
            return
        }
        let fd = LibboxGetTunnelFileDescriptor()
        if fd != -1 {
            ret0_.pointee = fd
            return
        }
        throw KumoTunnelError("the tunnel has no file descriptor")
    }

    // MARK: the network in use

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        guard let listener else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        let first = DispatchSemaphore(value: 0)
        var firstDone = false
        monitor.pathUpdateHandler = { path in
            Self.report(path, to: listener)
            if !firstDone {
                firstDone = true
                first.signal()
            }
        }
        monitor.start(queue: DispatchQueue.global())
        // The core wants the first answer before it goes on.
        _ = first.wait(timeout: .now() + 5)
    }

    private static func report(_ path: NWPath, to listener: LibboxInterfaceUpdateListenerProtocol) {
        guard path.status != .unsatisfied, let interface = path.availableInterfaces.first else {
            listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
            return
        }
        listener.updateDefaultInterface(
            interface.name, interfaceIndex: Int32(interface.index), isExpensive: path.isExpensive, isConstrained: path.isConstrained)
    }

    func closeDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        monitor?.cancel()
        monitor = nil
    }

    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        guard let monitor else {
            throw KumoTunnelError("the network monitor is not started")
        }
        let path = monitor.currentPath
        var list: [LibboxNetworkInterface] = []
        if path.status != .unsatisfied {
            for item in path.availableInterfaces {
                let interface = LibboxNetworkInterface()
                interface.name = item.name
                interface.index = Int32(item.index)
                switch item.type {
                case .wifi: interface.type = LibboxInterfaceTypeWIFI
                case .cellular: interface.type = LibboxInterfaceTypeCellular
                case .wiredEthernet: interface.type = LibboxInterfaceTypeEthernet
                default: interface.type = LibboxInterfaceTypeOther
                }
                list.append(interface)
            }
        }
        return InterfaceList(list)
    }

    private final class InterfaceList: NSObject, LibboxNetworkInterfaceIteratorProtocol {
        private var iterator: IndexingIterator<[LibboxNetworkInterface]>
        private var current: LibboxNetworkInterface?

        init(_ list: [LibboxNetworkInterface]) {
            iterator = list.makeIterator()
        }

        func hasNext() -> Bool {
            current = iterator.next()
            return current != nil
        }

        func next() -> LibboxNetworkInterface? { current }
    }

    // MARK: answers that are fixed on iOS

    func usePlatformAutoDetectInterfaceControl() -> Bool { false }
    func autoDetectInterfaceControl(_ fd: Int32) throws {}
    func useProcFS() -> Bool { false }
    func underNetworkExtension() -> Bool { true }
    func includeAllNetworks() -> Bool { false }
    func localDNSTransport() -> LibboxLocalDNSTransportProtocol? { nil }
    func systemCertificates() -> LibboxStringIteratorProtocol? { nil }
    func readWIFIState() -> LibboxWIFIState? { nil }

    func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32, destinationAddress: String?, destinationPort: Int32) throws -> LibboxConnectionOwner {
        // iOS does not say which app a connection belongs to.
        throw KumoTunnelError("not available on iOS")
    }

    func sendNotification(_ notification: LibboxNotification?) throws {}

    /// The core asks to forget what it knows of names: the settings are put again, so the system forgets its own.
    func clearDNSCache() {
        guard let tunnel, let settings = networkSettings else { return }
        let done = DispatchSemaphore(value: 0)
        tunnel.reasserting = true
        tunnel.setTunnelNetworkSettings(nil) { _ in
            tunnel.setTunnelNetworkSettings(settings) { _ in
                tunnel.reasserting = false
                done.signal()
            }
        }
        _ = done.wait(timeout: .now() + 5)
    }

    // MARK: the server of the core asks the extension

    func serviceStop() throws {
        tunnel?.stopCore()
    }

    func serviceReload() throws {
        // A reload is a new start request of the app; nothing is kept here to start again from.
    }

    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        let status = LibboxSystemProxyStatus()
        if let proxy = networkSettings?.proxySettings, proxy.httpServer != nil {
            status.available = true
            status.enabled = proxy.httpEnabled
        }
        return status
    }

    func setSystemProxyEnabled(_ enabled: Bool) throws {
        guard let tunnel, let settings = networkSettings, let proxy = settings.proxySettings, proxy.httpServer != nil,
              proxy.httpEnabled != enabled else { return }
        proxy.httpEnabled = enabled
        proxy.httpsEnabled = enabled
        settings.proxySettings = proxy
        let done = DispatchSemaphore(value: 0)
        tunnel.setTunnelNetworkSettings(settings) { _ in done.signal() }
        done.wait()
    }

    func writeDebugMessage(_ message: String?) {
        guard let message else { return }
        Self.log.debug("\(message, privacy: .public)")
    }

    /// The service ended: what was kept for it goes.
    func reset() {
        networkSettings = nil
        monitor?.cancel()
        monitor = nil
    }
}
