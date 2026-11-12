// Vespertine Remote: tests for reading a request, the local-network-only rule and the no-PIN safety checks.
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Vespertine

@Suite("Phone remote")
struct RemoteServerTests {
    @Test("A complete GET request is read with its query and lowercased headers")
    func parsesRequest() throws {
        let text = "GET /api/snapshot?queue=7 HTTP/1.1\r\nHost: mac.local:8765\r\nX-Test: yes\r\n\r\n"
        let request = try #require(RemoteServer.parse(Data(text.utf8)))
        #expect(request.method == "GET")
        #expect(request.path == "/api/snapshot")
        #expect(request.query["queue"] == "7")
        #expect(request.headers["x-test"] == "yes")
        #expect(request.body.isEmpty)
    }

    @Test("A POST is read with its JSON body, and waits until the whole body has arrived")
    func parsesBody() throws {
        let body = #"{"type":"next"}"#
        let head = "POST /api/command HTTP/1.1\r\nHost: x\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
        #expect(RemoteServer.parse(Data((head + String(body.dropLast(3))).utf8)) == nil)
        let request = try #require(RemoteServer.parse(Data((head + body).utf8)))
        #expect(String(data: request.body, encoding: .utf8) == body)
    }

    @Test("A body larger than the limit is refused")
    func hugeBody() {
        let head = "POST /api/command HTTP/1.1\r\nContent-Length: \(RemoteServer.maxBodyBytes + 1)\r\n\r\n"
        #expect(RemoteServer.parse(Data(head.utf8)) == nil)
    }

    @Test("A request that hasn't finished its headers is not read yet")
    func incompleteRequest() {
        #expect(RemoteServer.parse(Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)) == nil)
    }

    @Test("A request line that isn't HTTP is refused")
    func badRequestLine() {
        #expect(RemoteServer.parse(Data("HELLO\r\n\r\n".utf8)) == nil)
        #expect(RemoteServer.parse(Data("GET / FTP/1.0\r\n\r\n".utf8)) == nil)
    }

    @Test("Only addresses on the local network are let in")
    func localAddresses() {
        #expect(RemoteServer.isLocalIPv4([192, 168, 1, 20]))
        #expect(RemoteServer.isLocalIPv4([10, 0, 0, 5]))
        #expect(RemoteServer.isLocalIPv4([172, 16, 0, 1]))
        #expect(RemoteServer.isLocalIPv4([172, 31, 255, 1]))
        #expect(RemoteServer.isLocalIPv4([127, 0, 0, 1]))
        #expect(RemoteServer.isLocalIPv4([169, 254, 3, 4]))
        #expect(!RemoteServer.isLocalIPv4([172, 32, 0, 1]))
        #expect(!RemoteServer.isLocalIPv4([172, 15, 0, 1]))
        #expect(!RemoteServer.isLocalIPv4([8, 8, 8, 8]))
        #expect(!RemoteServer.isLocalIPv4([192, 169, 1, 1]))
        #expect(!RemoteServer.isLocalIPv4([1, 2, 3]))
    }

    @Test("Host headers: IP addresses, localhost and .local names pass; other names (DNS rebinding) do not")
    func hosts() {
        #expect(RemoteSecurity.isAllowedHost("192.168.1.20:8765"))
        #expect(RemoteSecurity.isAllowedHost("[::1]:8765"))
        #expect(RemoteSecurity.isAllowedHost("localhost:8765"))
        #expect(RemoteSecurity.isAllowedHost("gavins-mac.local:8765"))
        #expect(!RemoteSecurity.isAllowedHost("evil.example.com:8765"))
        #expect(!RemoteSecurity.isAllowedHost("evil.local.example.com"))
        #expect(!RemoteSecurity.isAllowedHost(nil))
        #expect(!RemoteSecurity.isAllowedHost(""))
    }

    @Test("Changes need a JSON POST with the custom header, and the same origin if one is sent")
    func mutations() {
        func check(_ method: String = "POST", origin: String? = nil, type: String? = "application/json",
                   header: String? = "1") -> String? {
            RemoteSecurity.mutationRejection(method: method, host: "192.168.1.20:8765", origin: origin,
                                             contentType: type, clientHeader: header)
        }
        #expect(check() == nil)
        #expect(check(origin: "http://192.168.1.20:8765") == nil)
        #expect(check("GET") != nil)
        #expect(check(header: nil) != nil)
        #expect(check(type: "text/plain") != nil)
        #expect(check(origin: "http://evil.example.com") != nil)
        #expect(check(origin: "null") != nil)
    }

    @Test("Sample rates are labelled like the Mac app")
    func sampleRates() {
        #expect(RemoteBridge.sampleRateLabel(96_000) == "96kHz")
        #expect(RemoteBridge.sampleRateLabel(44_100) == "44.1kHz")
        #expect(RemoteBridge.sampleRateLabel(5_644_800) == "5.6MHz")
        #expect(RemoteBridge.sampleRateLabel(0) == nil)
    }

    @Test("Page files can't escape the packed folder")
    func siteTraversal() {
        #expect(RemoteSite.file(for: "/../../etc/passwd").status != 200)
        #expect(RemoteSite.contentType("js").hasPrefix("text/javascript"))
    }
}
