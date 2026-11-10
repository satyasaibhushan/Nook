// Licensed under GPL-3.0. See LICENSE.
// Compile with SearchUtils.swift and SearchResultPolicy.swift.

import Foundation

@main
struct SearchResultPolicyCheck {
    struct Row: Identifiable {
        let id: String
        let destination: String
    }

    static func main() {
        let tab = Row(id: "tab:1", destination: "https://tab.test")
        let selected = Row(id: "history:2", destination: "https://selected.test")
        let history = Row(id: "history:3", destination: "https://late.test")
        let web = Row(id: "search:late", destination: "https://search.test/?q=late")
        let first = [tab, selected]
        let selectedID = first[1].id
        let withWeb = SearchResultPolicy.retainingShownRows(first, candidates: first + [web], limit: 5)
        let withHistory = SearchResultPolicy.retainingShownRows(
            withWeb, candidates: [tab, history, selected, web], limit: 5
        )
        precondition(withHistory.map(\.id) == [tab.id, selected.id, web.id, history.id])
        precondition(withHistory.first { $0.id == selectedID }?.destination == selected.destination)
        let capped = SearchResultPolicy.retainingShownRows(withWeb, candidates: [history] + withWeb, limit: 3)
        precondition(capped.map(\.id) == withWeb.map(\.id))
        let removed = SearchResultPolicy.retainingShownRows(withHistory, candidates: [tab, history], limit: 5)
        precondition(removed.map(\.id) == [tab.id, history.id])
        let renamed = Row(id: tab.id, destination: "https://updated.test")
        let refreshed = SearchResultPolicy.retainingShownRows([tab], candidates: [renamed, renamed], limit: 5)
        precondition(refreshed.count == 1 && refreshed[0].destination == renamed.destination)
        let newQuery = SearchResultPolicy.retainingShownRows([Row](), candidates: [web, tab], limit: 5)
        precondition(newQuery.map(\.id) == [web.id, tab.id])

        for query in ["ordinary query", "example.com", "https://private.test/path?token=example", "localhost:3000"] {
            precondition(!SearchInputSource.inlineAddress.allowsWebSuggestions(for: query))
        }
        precondition(SearchInputSource.palette.allowsWebSuggestions(for: "ordinary query"))
        precondition(!SearchInputSource.palette.allowsWebSuggestions(for: "https://example.test/path"))
        print("SearchResultPolicyCheck passed")
    }
}
