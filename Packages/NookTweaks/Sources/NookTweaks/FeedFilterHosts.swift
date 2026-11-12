// Licensed under GPL-3.0. See LICENSE.

import Foundation

public enum FeedFilterHosts {
    /// Explicit aliases only. Embedded players and unrelated subdomains have no feed adapter.
    public static func site(for url: URL) -> String? {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return nil }
        switch host {
        case "x.com", "www.x.com": return "x.com"
        case "youtube.com", "www.youtube.com", "m.youtube.com": return "youtube.com"
        case "reddit.com", "www.reddit.com", "old.reddit.com": return "reddit.com"
        default: return nil
        }
    }
}
