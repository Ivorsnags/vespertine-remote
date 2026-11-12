//
// Vespertine Remote: a tiny HTTP server for the phone remote, on the local network only.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Network

/// One request from the phone. Bodies are read (JSON commands are small); everything else is ignored.
nonisolated struct RemoteRequest: Sendable {
    let method: String
    let path: String
    let query: [String: String]
    /// Header names are lowercased.
    let headers: [String: String]
    let body: Data
}

nonisolated struct RemoteResponse: Sendable {
    var status: Int
    var contentType: String
    var body: Data
    var extraHeaders: [String: String] = [:]
    /// The connection stays open after `body` and gets every later `broadcast` event (Server-Sent Events).
    var keepsOpen = false

    static func text(_ text: String, status: Int = 200) -> RemoteResponse {
        RemoteResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    /// `value` must hold only finite numbers: JSONSerialization refuses NaN and infinity.
    static func json(_ value: Any, status: Int = 200) -> RemoteResponse {
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) else {
            return .text("Couldn’t make that answer", status: 500)
        }
        return RemoteResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    static func file(_ data: Data, contentType: String, cache: String) -> RemoteResponse {
        RemoteResponse(status: 200, contentType: contentType, body: data, extraHeaders: ["Cache-Control": cache])
    }

    /// The opening events of a live stream.
    static func eventStream(initial: Data) -> RemoteResponse {
        RemoteResponse(status: 200, contentType: "text/event-stream; charset=utf-8", body: initial, keepsOpen: true)
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

    /// Headers plus body larger than this are refused.
    static let maxRequestBytes = 80 * 1024
    static let maxBodyBytes = 64 * 1024
    /// A connection that hasn't finished its request and response by then is closed (live streams excepted).
    static let connectionSeconds = 15.0
    /// A comment sent down every live stream this often, so a dead connection is noticed.
    static let keepAliveSeconds = 15.0

    private let queue = DispatchQueue(label: "org.szeremeta.vespertine.remote-server")
    private let handler: Handler
    private let onState: @Sendable (State) -> Void
    private let onClients: @Sendable (Int) -> Void
    private let countLock = NSLock()
    private var openStreams = 0
    private var listener: NWListener?
    private var streams: [ObjectIdentifier: NWConnection] = [:]
    private var keepAlive: DispatchSourceTimer?

    init(handler: @escaping Handler, onState: @escaping @Sendable (State) -> Void,
         onClients: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.handler = handler
        self.onState = onState
        self.onClients = onClients
    }

    /// Phones with a live stream open; safe to read from any thread.
    var streamCount: Int {
        countLock.lock()
        defer { countLock.unlock() }
        return openStreams
    }

    /// Call on `queue` after `streams` changed.
    private func streamsChanged() {
        countLock.lock()
        openStreams = streams.count
        countLock.unlock()
        onClients(streams.count)
    }

    func start(port: UInt16) {
        queue.async { [self] in
            stopNow()
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                onState(.failed("The port number isn’t valid."))
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
                startKeepAlive()
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

    /// Sends one Server-Sent Event to every phone with a live stream open.
    func broadcast(event: String, json: Data) {
        queue.async { [self] in
            guard !streams.isEmpty else { return }
            var frame = Data("event: \(event)\ndata: ".utf8)
            frame.append(json)
            frame.append(Data("\n\n".utf8))
            write(frame, toStreams: Array(streams))
        }
    }

    private func stopNow() {
        keepAlive?.cancel()
        keepAlive = nil
        for connection in streams.values { connection.cancel() }
        streams = [:]
        streamsChanged()
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
    }

    private func startKeepAlive() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.keepAliveSeconds, repeating: Self.keepAliveSeconds)
        timer.setEventHandler { [weak self] in
            guard let self, !self.streams.isEmpty else { return }
            self.write(Data(": keep-alive\n\n".utf8), toStreams: Array(self.streams))
        }
        keepAlive = timer
        timer.resume()
    }

    private func write(_ data: Data, toStreams list: [(key: ObjectIdentifier, value: NWConnection)]) {
        for (id, connection) in list {
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard error != nil else { return }
                self?.queue.async {
                    self?.streams[id]?.cancel()
                    self?.streams[id] = nil
                    self?.streamsChanged()
                }
            })
        }
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
        let id = ObjectIdentifier(connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.queue.async { self?.streams[id] = nil; self?.streamsChanged() }
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.connectionSeconds) { [weak self] in
            if self?.streams[id] == nil { connection.cancel() }
        }
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
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
        var headers: [String: String] = [
            "Content-Type": response.contentType,
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
            "Referrer-Policy": "no-referrer",
        ]
        if response.keepsOpen {
            headers["Connection"] = "keep-alive"
            headers["X-Accel-Buffering"] = "no"
        } else {
            headers["Connection"] = "close"
            headers["Content-Length"] = String(response.body.count)
        }
        for (name, value) in response.extraHeaders { headers[name] = value }
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(response.body)
        if response.keepsOpen {
            streams[ObjectIdentifier(connection)] = connection
            streamsChanged()
            connection.send(content: out, completion: .contentProcessed { _ in })
        } else {
            connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    // MARK: Parsing and checks

    /// The request once its header block and body are complete; nil while more is expected or when the request line is
    /// unusable.
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
        let length = headers["content-length"].flatMap { Int($0) } ?? 0
        guard length >= 0, length <= maxBodyBytes else { return nil }
        let bodyStart = range.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= length else { return nil }
        let body = Data(data[bodyStart..<data.index(bodyStart, offsetBy: length)])
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return RemoteRequest(method: String(requestLine[0]).uppercased(), path: components.path, query: query,
                             headers: headers, body: body)
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
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        default: "Error"
        }
    }
}
