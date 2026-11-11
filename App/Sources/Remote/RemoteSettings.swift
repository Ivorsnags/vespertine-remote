//
// Vespertine Remote: the Remote tab in Settings.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import CoreImage
import SwiftUI

struct RemoteSettings: View {
    @State private var remote = RemoteController.shared

    var body: some View {
        @Bindable var controller = remote
        Form {
            Section {
                Toggle("Control Vespertine from a phone on this network", isOn: $controller.enabled)
                Text(statusLine).font(.caption).foregroundStyle(.secondary)
            } footer: {
                Text("Vespertine answers only devices on your own network, and only with the PIN. Nothing goes through the internet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if controller.enabled {
                Section("Connect") {
                    if let address = controller.addresses.first {
                        HStack(alignment: .top, spacing: 16) {
                            if let code = Self.qrCode(address) {
                                Image(nsImage: code).interpolation(.none).resizable().frame(width: 110, height: 110)
                                    .accessibilityLabel("QR code for the address")
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text("On the phone, scan the code or open one of these in Safari:")
                                    .font(.caption).foregroundStyle(.secondary)
                                ForEach(controller.addresses, id: \.self) { Text($0).textSelection(.enabled).font(.callout.monospaced()) }
                            }
                        }
                    }
                    LabeledContent("PIN") {
                        HStack {
                            Text(controller.pin).font(.title3.monospacedDigit()).textSelection(.enabled)
                            Button("New PIN") { controller.regeneratePIN() }
                        }
                    }
                    LabeledContent("Port") {
                        TextField("Port", value: $controller.port, format: .number.grouping(.never))
                            .multilineTextAlignment(.trailing).frame(width: 80)
                    }
                    Text("The first time, macOS may ask to let Vespertine find devices on your local network. Choose Allow. After entering the PIN once, the phone remembers it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var statusLine: String {
        switch remote.status {
        case .off: String(localized: "Off.")
        case .starting: String(localized: "Starting…")
        case .listening: String(localized: "On. Waiting for your phone.")
        case .failed(let reason): String(localized: "Couldn’t start: \(reason) Try another port.")
        }
    }

    /// A QR code for `text`, black on white.
    private static func qrCode(_ text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
