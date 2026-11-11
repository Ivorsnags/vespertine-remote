// Vespertine Remote: tests for reading a request, the local-network-only rule and the PIN check.
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Vespertine

@Suite("Phone remote")
struct RemoteServerTests {
    @Test("A complete GET request is read with its query and lowercased headers")
    func parsesRequest() throws {
        let text = "POST /api/seek?to=12.5 HTTP/1.1\r\nHost: mac.local:8765\r\nX-Pin: 123456\r\n\r\n"
        let request = try #require(RemoteServer.parse(Data(text.utf8)))
        #expect(request.method == "POST")
        #expect(request.path == "/api/seek")
        #expect(request.query["to"] == "12.5")
        #expect(request.headers["x-pin"] == "123456")
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

    @Test("The PIN must match exactly, and an empty PIN never matches")
    func pinMatching() {
        #expect(RemoteAPI.matches("123456", "123456"))
        #expect(!RemoteAPI.matches("123457", "123456"))
        #expect(!RemoteAPI.matches("12345", "123456"))
        #expect(!RemoteAPI.matches("1234567", "123456"))
        #expect(!RemoteAPI.matches("", ""))
    }

    @Test("A new PIN is six digits")
    @MainActor
    func newPIN() {
        for _ in 0..<50 {
            let pin = RemoteController.newPIN()
            #expect(pin.count == 6 && pin.allSatisfy(\.isNumber))
        }
    }

    @Test("Numbers sent to the phone are always finite")
    func finiteNumbers() {
        #expect(RemoteAPI.finite(.nan) == 0)
        #expect(RemoteAPI.finite(.infinity) == 0)
        #expect(RemoteAPI.finite(12.5) == 12.5)
    }
}
