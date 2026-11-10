// Licensed under GPL-3.0. See LICENSE.

import Foundation

struct TabSearchCandidate: Identifiable {
    let id: UUID
    let title: String
    let url: URL
    let isCurrentSpace: Bool
}

enum TabSearchRanking {
    static func matches(in items: [TabSearchCandidate], words: [String], limit: Int) -> [TabSearchCandidate] {
        let matches = items.compactMap { item -> (item: TabSearchCandidate, titleMatch: Bool, titleLength: Int)? in
            let title = item.title.lowercased()
            let haystack = title + " " + item.url.absoluteString.lowercased()
            guard words.allSatisfy(haystack.contains) else { return nil }
            return (item, words.allSatisfy(title.contains), item.title.count)
        }
        return matches.sorted { lhs, rhs in
            if lhs.titleMatch != rhs.titleMatch { return lhs.titleMatch }
            if lhs.item.isCurrentSpace != rhs.item.isCurrentSpace { return lhs.item.isCurrentSpace }
            return lhs.titleLength < rhs.titleLength
        }.prefix(limit).map(\.item)
    }
}
