// Licensed under GPL-3.0. See LICENSE.

import Foundation

/// Returns a watch URL only for a Shorts video on a YouTube host.
public func youTubeShortsWatchURL(_ url: URL) -> URL? {
    guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
          ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
          ["youtube.com", "www.youtube.com", "m.youtube.com"].contains(parts.host?.lowercased() ?? "")
    else { return nil }
    let path = parts.path.split(separator: "/", omittingEmptySubsequences: false)
    guard path.count == 3 || (path.count == 4 && path[3].isEmpty),
          path[0].isEmpty, path[1] == "shorts", !path[2].isEmpty,
          path[2].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
    else { return nil }
    parts.scheme = "https"
    parts.host = "www.youtube.com"
    parts.port = nil
    parts.path = "/watch"
    parts.queryItems = [URLQueryItem(name: "v", value: String(path[2]))]
        + (parts.queryItems ?? []).filter { $0.name != "v" }
    return parts.url
}
