//
// Vespertine Remote: the checks that keep the phone remote safe without a PIN.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Darwin

/// Like the GR Player remote, this one has no pairing code (it is only for use at home), so these checks do the work:
///
/// 1. Only devices on the local network may connect (see `RemoteServer.isLocal`).
/// 2. The Host header must be an IP address, `localhost` or a `.local` name. That defeats DNS rebinding, where a web
///    page on some other site points its own domain at the Mac to read or drive the remote.
/// 3. Every state-changing request is a JSON POST carrying a custom header. A web page on another site can't send that
///    header without a CORS preflight, which this server never approves; a matching Origin is also required when the
///    browser sends one.
nonisolated enum RemoteSecurity {
    static let clientHeader = "x-vespertine-remote"

    /// The name part of a Host header, without port or IPv6 brackets.
    static func hostname(fromHostHeader host: String?) -> String? {
        guard let host else { return nil }
        let value = host.trimmingCharacters(in: .whitespaces).lowercased()
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]"), close > value.index(after: value.startIndex) else { return nil }
            return String(value[value.index(after: value.startIndex)..<close])
        }
        let colons = value.filter { $0 == ":" }.count
        if colons == 1, let colon = value.lastIndex(of: ":") {
            let name = String(value[value.startIndex..<colon])
            return name.isEmpty ? nil : name
        }
        return value
    }

    static func isIPAddress(_ text: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, text, &v4) == 1 || inet_pton(AF_INET6, text, &v6) == 1
    }

    /// Host names the remote answers to: IP literals, localhost and Bonjour (`.local`) names.
    static func isAllowedHost(_ host: String?) -> Bool {
        guard let name = hostname(fromHostHeader: host) else { return false }
        if isIPAddress(name) || name == "localhost" { return true }
        return name.range(of: #"^[a-z0-9]([a-z0-9-]{0,62})?(\.[a-z0-9]([a-z0-9-]{0,62})?)*\.local\.?$"#,
                          options: .regularExpression) != nil
    }

    /// nil when a state-changing request is acceptable, otherwise the reason it is not.
    static func mutationRejection(method: String, host: String?, origin: String?, contentType: String?,
                                  clientHeader: String?) -> String? {
        guard method == "POST" else { return "Use POST" }
        guard clientHeader == "1" else { return "Missing \(Self.clientHeader) header" }
        guard let contentType, contentType.lowercased().hasPrefix("application/json") else { return "Expected JSON" }
        if let origin {
            if origin == "null" { return "Cross-origin request refused" }
            guard let originHost = URL(string: origin)?.host.map({ hostWithPort(URL(string: origin)!, $0) }) else { return "Bad origin" }
            guard let host, originHost == host.trimmingCharacters(in: .whitespaces).lowercased() else {
                return "Cross-origin request refused"
            }
        }
        return nil
    }

    private static func hostWithPort(_ url: URL, _ host: String) -> String {
        let name = host.contains(":") ? "[\(host)]" : host
        return (url.port.map { "\(name):\($0)" } ?? name).lowercased()
    }
}
