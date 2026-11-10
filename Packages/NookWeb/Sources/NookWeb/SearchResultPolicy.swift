// Licensed under GPL-3.0. See LICENSE.

import Foundation

public enum SearchInputSource {
    case palette
    case inlineAddress

    public func allowsWebSuggestions(for query: String) -> Bool {
        self == .palette && !isLikelyURL(query)
    }
}

public enum SearchResultPolicy {
    /// Keep displayed targets in place as slower sources finish. New rows follow them.
    public static func retainingShownRows<Row: Identifiable>(
        _ previous: [Row], candidates: [Row], limit: Int
    ) -> [Row] {
        var byID: [Row.ID: Row] = [:]
        for row in candidates where byID[row.id] == nil { byID[row.id] = row }
        var rows: [Row] = []
        for row in previous + candidates {
            if let current = byID.removeValue(forKey: row.id) { rows.append(current) }
            if rows.count == limit { break }
        }
        return rows
    }
}
