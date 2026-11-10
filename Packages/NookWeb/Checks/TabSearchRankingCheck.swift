// Licensed under GPL-3.0. See LICENSE.
// Compile with SearchUtils.swift, SearchResultPolicy.swift and TabSearchRanking.swift.
// Run with -O for the timing sample.

import Foundation

@main
struct TabSearchRankingCheck {
    static func original(_ items: [TabSearchCandidate], words: [String]) -> [TabSearchCandidate] {
        items.filter { item in
            let haystack = item.title.lowercased() + " " + item.url.absoluteString.lowercased()
            return words.allSatisfy(haystack.contains)
        }.sorted { lhs, rhs in
            let leftTitle = words.allSatisfy(lhs.title.lowercased().contains)
            let rightTitle = words.allSatisfy(rhs.title.lowercased().contains)
            if leftTitle != rightTitle { return leftTitle }
            if lhs.isCurrentSpace != rhs.isCurrentSpace { return lhs.isCurrentSpace }
            return lhs.title.count < rhs.title.count
        }.prefix(2).map { $0 }
    }

    static func main() {
        var items = (0..<200).map { index in
            TabSearchCandidate(id: UUID(), title: ["GitHub Issue", "Mail", "Chess Game", "Café Docs", "SEARCH"][index % 5] + " \(index)",
                               url: URL(string: "https://site\(index).test/github/docs?q=\(index)")!,
                               isCurrentSpace: index % 3 == 0)
        }
        let queries = ["github", "docs", "mail", "chess game", "café", "search", "site190", "missing", "issue github"]
        func verify() {
            for query in queries {
                let words = query.lowercased().split(separator: " ").map(String.init)
                let expected = original(items, words: words).map(\.id)
                let found = TabSearchRanking.matches(in: items, words: words, limit: 2).map(\.id)
                precondition(found == expected, "Ranking changed for \(query)")
            }
        }
        verify()
        let shown = TabSearchRanking.matches(in: items, words: ["github"], limit: 2)
        let added = TabSearchCandidate(id: UUID(), title: "GitHub", url: URL(string: "https://added.test")!, isCurrentSpace: true)
        let reranked = TabSearchRanking.matches(in: items + [added], words: ["github"], limit: items.count + 1)
        precondition(reranked.first?.id == added.id)
        let stable = SearchResultPolicy.retainingShownRows(shown, candidates: reranked, limit: 2)
        precondition(stable.map(\.id) == shown.map(\.id), "A new tab displaced a shown target")
        let removedID = shown[1].id
        let afterClose = SearchResultPolicy.retainingShownRows(stable, candidates: reranked.filter { $0.id != removedID }, limit: 2)
        precondition(!afterClose.contains { $0.id == removedID })
        precondition(afterClose.first?.id == stable.first?.id)
        let firstID = items[0].id
        items[0] = TabSearchCandidate(id: firstID, title: "Renamed mail", url: URL(string: "https://changed.test")!, isCurrentSpace: true)
        verify()
        precondition(!TabSearchRanking.matches(in: [items[0]], words: ["github"], limit: 2).contains { $0.id == firstID })
        items.remove(at: 1)
        items.append(TabSearchCandidate(id: UUID(), title: "Mail", url: URL(string: "https://new.test")!, isCurrentSpace: true))
        verify()

        let clock = ContinuousClock()
        var timings: [Double] = []
        var checksum = 0
        for index in 0..<1000 {
            let words = queries[index % queries.count].lowercased().split(separator: " ").map(String.init)
            let start = clock.now
            checksum += TabSearchRanking.matches(in: items, words: words, limit: 2).count
            let elapsed = start.duration(to: clock.now).components
            timings.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
        }
        timings.sort()
        precondition(checksum > 0)
        print(String(format: "TabSearchRankingCheck passed, 200 items, 1000 queries, p50 %.3f ms, p95 %.3f ms", timings[500], timings[950]))
    }
}
