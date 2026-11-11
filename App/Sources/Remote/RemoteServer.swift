//
// Vespertine Remote: a tiny HTTP server for the phone remote, on the local network only.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Network

/// One request from the phone: only what the remote needs (no request bodies are read).
nonisolated struct RemoteRequest: Sendable {
    let method: String
    let path: String
    let query: [String: String]
    /// Header names are lowercased.
    let headers: [String: String]
}

nonisolated struct RemoteResponse: Sendable {
    var status: Int
    var contentType: String
    var body: Data
    var extraHeaders: [String: String] = [:]

    static func text(_ text: String, status: Int = 200) -> RemoteResponse {
        RemoteResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    static func html(_ page: String) -> RemoteResponse {
        RemoteResponse(status: 200, contentType: "text/html; charset=utf-8", body: Data(page.utf8),
                       extraHeaders: ["Content-Security-Policy":
                                        "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src blob: data:; connect-src 'self'"])
    }

    /// `value` must hold only finite numbers: JSONSerialization raises on NaN and infinity.
    static func json(_ value: [String: Any], status: Int = 200) -> RemoteResponse {
        let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8)
        return RemoteResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    static func jpeg(_ data: Data) -> RemoteResponse {
        RemoteResponse(status: 200, contentType: "image/jpeg", body: data)
    }
}

/// Listens for HTTP/1.1 requests and answers each with `handler`. It talks only to devices on the local network
/// (private, link-local and loopback addresses); anything else is dropped before a byte is read.
/// All state is touched on `queue` only.
nonisolated final class RemoteServer: @unchecked Sendable {
    typealias Handler = @Sendable (RemoteRequest) async -> RemoteResponse

    nonisolated enum State: Sendable, Equatable {
        case listening(UInt16)
        case failed(String)
        case stopped
    }

    /// A request larger than this (headers only are expected) is refused.
    static let maxRequestBytes = 16 * 1024
    /// A connection that hasn't finished its request and response by then is closed.
    static let connectionSeconds = 15.0

    private let queue = DispatchQueue(label: "org.szeremeta.vespertine.remote-server")
    private let handler: Handler
    private var listener: NWListener?
    private let onState: @Sendable (State) -> Void

    init(handler: @escaping Handler, onState: @escaping @Sendable (State) -> Void) {
        self.handler = handler
        self.onState = onState
    }

    func start(port: UInt16) {
        queue.async { [self] in
            stopNow()
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                onState(.failed("The port number isn't valid."))
                return
            }
            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                let listener = try NWListener(using: parameters, on: nwPort)
                listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state, port: port) }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                self.listener = listener
                listener.start(queue: queue)
            } catch {
                onState(.failed(error.localizedDescription))
            }
        }
    }

    func stop() {
        queue.async { [self] in
            stopNow()
            onState(.stopped)
        }
    }

    private func stopNow() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
    }

    private func listenerChanged(_ state: NWListener.State, port: UInt16) {
        switch state {
        case .ready: onState(.listening(port))
        case .failed(let error):
            stopNow()
            onState(.failed(error.localizedDescription))
        default: break
        }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        guard Self.isLocal(connection.endpoint) else { connection.cancel(); return }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.connectionSeconds) { connection.cancel() }
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > Self.maxRequestBytes {
                self.send(.text("Request too large", status: 413), on: connection)
            } else if let request = Self.parse(buffer) {
                self.answer(request, on: connection)
            } else if error != nil || isComplete {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func answer(_ request: RemoteRequest, on connection: NWConnection) {
        let handler = self.handler
        Task {
            let response = await handler(request)
            self.queue.async { self.send(response, on: connection) }
        }
    }

    private func send(_ response: RemoteResponse, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\nCache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n"
        for (name, value) in response.extraHeaders { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(response.body)
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: Parsing and checks

    /// The request once its header block is complete (ends with a blank line); nil while more is expected or when
    /// the request line is unusable.
    static func parse(_ data: Data) -> RemoteRequest? {
        let end = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: end),
              let text = String(data: data[data.startIndex..<range.lowerBound], encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/"),
              let components = URLComponents(string: "http://remote" + requestLine[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return RemoteRequest(method: String(requestLine[0]).uppercased(), path: components.path, query: query, headers: headers)
    }

    /// Whether a device at `endpoint` is on the local network: private IPv4 (10/8, 172.16/12, 192.168/16),
    /// link-local, loopback, or the IPv6 equivalents.
    static func isLocal(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return isLocalIPv4(Array(address.rawValue))
        case .ipv6(let address):
            if let mapped = address.asIPv4 { return isLocalIPv4(Array(mapped.rawValue)) }
            return address.isLoopback || address.isLinkLocal || address.isUniqueLocal
        default:
            return false
        }
    }

    static func isLocalIPv4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        return b[0] == 10 || b[0] == 127
            || (b[0] == 192 && b[1] == 168)
            || (b[0] == 172 && (16...31).contains(b[1]))
            || (b[0] == 169 && b[1] == 254)
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        case 429: "Too Many Requests"
        default: "Error"
        }
    }
}
