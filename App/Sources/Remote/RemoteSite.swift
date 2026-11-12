//
// Vespertine Remote: serves the phone page that is packed inside the app (the `site` folder).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

nonisolated enum RemoteSite {
    /// The packed page, or nil when the app was built without it.
    static var root: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("site", isDirectory: true)
    }

    static func file(for path: String) -> RemoteResponse {
        guard let root else { return .text("The remote page isn’t packed in this build.", status: 404) }
        var relative = path == "/" ? "index.html" : String(path.drop(while: { $0 == "/" }))
        // Pages like /library or /now are the app's own screens: hand back the page and let it route.
        if (relative as NSString).pathExtension.isEmpty { relative = "index.html" }
        let url = root.appendingPathComponent(relative).standardizedFileURL
        guard url.path.hasPrefix(root.standardizedFileURL.path + "/"),
              let data = try? Data(contentsOf: url) else { return .text("Not found", status: 404) }
        let isPage = url.lastPathComponent == "index.html" || url.lastPathComponent == "sw.js"
        return .file(data, contentType: contentType(url.pathExtension.lowercased()),
                     cache: isPage ? "no-cache" : "public, max-age=3600")
    }

    static func contentType(_ ext: String) -> String {
        switch ext {
        case "html": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json", "webmanifest": "application/json; charset=utf-8"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "ico": "image/x-icon"
        case "woff2": "font/woff2"
        default: "application/octet-stream"
        }
    }
}
