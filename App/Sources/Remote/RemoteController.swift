//
// Vespertine Remote: the on/off switch, the PIN and the server's state.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Observation
import Darwin

/// Owns the phone remote: starts and stops the server, keeps the PIN and the port. Off until the user turns it on.
@Observable
@MainActor
final class RemoteController {
    static let shared = RemoteController()

    enum Status: Equatable {
        case off
        case starting
        case listening(UInt16)
        case failed(String)
    }

    static let defaultPort = 8765
    private enum Key {
        static let enabled = "remoteEnabled"
        static let port = "remotePort"
        static let pin = "remotePIN"
    }

    private(set) var status: Status = .off
    private(set) var pin: String

    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Key.enabled)
            enabled ? start() : stop()
        }
    }

    var port: Int {
        didSet {
            let clamped = min(max(port, 1024), 65535)
            if clamped != port { port = clamped; return }
            guard port != oldValue else { return }
            defaults.set(port, forKey: Key.port)
            if enabled { start() }
        }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var server: RemoteServer?
    @ObservationIgnored private var api: RemoteAPI?

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: Key.enabled)
        let saved = defaults.integer(forKey: Key.port)
        port = saved == 0 ? Self.defaultPort : min(max(saved, 1024), 65535)
        if let stored = defaults.string(forKey: Key.pin), stored.count == 6, stored.allSatisfy(\.isNumber) {
            pin = stored
        } else {
            let fresh = Self.newPIN()
            defaults.set(fresh, forKey: Key.pin)
            pin = fresh
        }
    }

    /// Called once the app's model exists. Starts the server if the remote was left on.
    func attach(_ model: AppModel) {
        self.model = model
        if enabled { start() }
    }

    func regeneratePIN() {
        let fresh = Self.newPIN()
        defaults.set(fresh, forKey: Key.pin)
        pin = fresh
    }

    nonisolated static func newPIN() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    private func start() {
        stop(keepEnabled: true)
        guard let model else { return }
        status = .starting
        let api = RemoteAPI(model: model, pin: { [weak self] in self?.pin ?? "" })
        self.api = api
        let server = RemoteServer(
            handler: { [weak api] request in
                guard let api else { return .text("Not available", status: 404) }
                return await api.handle(request)
            },
            onState: { [weak self] state in
                Task { @MainActor in self?.serverChanged(state) }
            })
        self.server = server
        server.start(port: UInt16(port))
    }

    private func stop(keepEnabled: Bool = false) {
        server?.stop()
        server = nil
        api = nil
        if !keepEnabled { status = .off }
    }

    private func serverChanged(_ state: RemoteServer.State) {
        // Reports from a server that has since been replaced or stopped are old news.
        guard server != nil else { return }
        switch state {
        case .listening(let port): status = .listening(port)
        case .failed(let reason): status = .failed(reason)
        case .stopped: break
        }
    }

    // MARK: Addresses to show

    /// Web addresses the phone can use, best first: the Mac's `.local` name, then its IPv4 addresses.
    var addresses: [String] {
        let name = ProcessInfo.processInfo.hostName
        var hosts: [String] = []
        if name.hasSuffix(".local") { hosts.append(name) }
        hosts.append(contentsOf: Self.localIPv4Addresses())
        return hosts.map { "http://\($0):\(port)" }
    }

    nonisolated static func localIPv4Addresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if !text.hasPrefix("169.254.") && !result.contains(text) { result.append(text) }
        }
        return result
    }
}
