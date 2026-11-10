// Licensed under GPL-3.0. See LICENSE.
//
//  SearchManager.swift
//  Alto
//
//  Created by Maciek Bagiński on 31/07/2025.
//

import Foundation
import NookSettings
import Observation
import SwiftUI

@MainActor
@Observable
public class SearchManager {
    private struct Results: Equatable {
        var suggestions: [SearchSuggestion] = []
        var isLoading = false
        var autofillHost: String?
    }

    private var results = Results()
    public var suggestions: [SearchSuggestion] { results.suggestions }
    public var isLoading: Bool { results.isLoading }
    public var autofillHost: String? { results.autofillHost }
    @ObservationIgnored private var typedCompletion: String?
    @ObservationIgnored private var pendingResults: Results?
    @ObservationIgnored private var publication: DispatchWorkItem?

    public init() {}

    private let session = URLSession.shared
    private var searchTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    /// Each leg belongs to one query. Rows from an older query must never remain selectable.
    private var tabRows: [SearchSuggestion] = []
    private var historyRows: [SearchSuggestion] = []
    @ObservationIgnored private var currentQuery: String?
    @ObservationIgnored private var observingTabs = false
    @ObservationIgnored private var shownTabCandidates: [TabSearchCandidate] = []
    private var webRows: [SearchSuggestion] = []
    private var textRows: [SearchSuggestion] = []
    private var searchGeneration = UUID()
    private weak var tabs: TabsController?
    private weak var window: BrowserWindowState?
    private weak var historyManager: HistoryManager?
    private var currentSpaceId: UUID?
    
    /// An open tab the palette can switch to, captured when the query ran.
    public struct TabMatch {
        public let itemID: UUID
        public let title: String
        public let url: URL
        private let resolveFavicon: @MainActor () -> SwiftUI.Image
        @MainActor public var favicon: SwiftUI.Image { resolveFavicon() }

        public init(itemID: UUID, title: String, url: URL, resolveFavicon: @escaping @MainActor () -> SwiftUI.Image) {
            self.itemID = itemID
            self.title = title
            self.url = url
            self.resolveFavicon = resolveFavicon
        }
    }

    public struct SearchSuggestion: Identifiable, Equatable {
        public enum ID: Hashable {
            case tab(UUID)
            case history(URL)
            case url(String)
            case search(String)
        }

        public var id: ID {
            switch type {
            case .tab(let match): return .tab(match.itemID)
            case .history(let entry): return .history(entry.url)
            case .url: return .url(text)
            case .search: return .search(text)
            }
        }
        public let text: String
        public let type: SuggestionType

        public init(text: String, type: SuggestionType) {
            self.text = text
            self.type = type
        }
        
        public enum SuggestionType {
            case search
            case url
            case tab(TabMatch)
            case history(HistoryEntry)
        }
        
        public static func == (lhs: SearchSuggestion, rhs: SearchSuggestion) -> Bool {
            switch (lhs.type, rhs.type) {
            case (.search, .search), (.url, .url):
                return lhs.text == rhs.text
            case (.tab(let lhsTab), .tab(let rhsTab)):
                return lhs.text == rhs.text && lhsTab.itemID == rhsTab.itemID && lhsTab.url == rhsTab.url
            case (.history(let lhsHistory), .history(let rhsHistory)):
                return lhs.text == rhs.text && lhsHistory == rhsHistory
            default:
                return false
            }
        }
    }
    
    /// The controller and window whose space's tabs the palette searches.
    public func setTabs(_ tabs: TabsController?, window: BrowserWindowState?) {
        self.tabs = tabs
        self.window = window
        updateSpaceContext()
    }
    
    public func setHistoryManager(_ historyManager: HistoryManager?) {
        self.historyManager = historyManager
        historyManager?.prepareAutofill()
    }

    @MainActor public func updateSpaceContext() {
        currentSpaceId = window?.spaceID
    }
    
    @MainActor public func searchSuggestions(for query: String, source: SearchInputSource = .palette) {
        searchTask?.cancel()
        historyTask?.cancel()
        let generation = UUID()
        searchGeneration = generation
        let includeWebSuggestions = source.allowsWebSuggestions(for: query)
        historyRows = []
        textRows = []
        webRows = []
        updateSpaceContext()
        let space = currentSpaceId
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clearSuggestions()
            return
        }

        // Known within this keystroke, so the Return row never changes under a finger already moving.
        typedCompletion = historyManager?.autofillHost(prefix: query.trimmingCharacters(in: .whitespacesAndNewlines))

        currentQuery = query
        refreshTabs(for: query)
        // The typed Return row and local tabs do not wait for history or the network.
        compose(loading: includeWebSuggestions)

        // History is a local lookup, so it runs on this keystroke rather than waiting for a pause
        // in typing. Only the network request is debounced.
        // ponytail: the scan is bounded at 5k rows; move it behind an index if a large history drags.
        historyTask = Task { [weak self] in
            guard let self else { return }
            // Two spare rows, for when the first three turn out to be open tabs.
            let history = Array(await self.searchHistory(for: query).prefix(5))
            guard !Task.isCancelled, self.searchGeneration == generation,
                  self.window?.spaceID == space else { return }
            self.historyRows = history
            self.compose(coalescing: true)
            // Page text second, so title and URL matches paint without waiting on it.
            let text = await self.searchPageText(for: query)
            guard !Task.isCancelled, self.searchGeneration == generation,
                  self.window?.spaceID == space else { return }
            self.textRows = text
            self.compose(coalescing: true)
        }

        // Inline editing stays local, and complete addresses never reach the provider.
        guard includeWebSuggestions else { return }
        searchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(125)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            let webSuggestions = await self.fetchWebSuggestions(for: query)
            guard !Task.isCancelled, self.searchGeneration == generation,
                  self.window?.spaceID == space else { return }
            self.webRows = webSuggestions
            self.compose(coalescing: true, loading: false)
        }
    }

    /// Rebuilds the visible list from the query's local rows plus whatever each leg last returned.
    @MainActor private func compose(coalescing: Bool = false, loading: Bool? = nil) {
        // A page that is already an open tab shows once, as the tab.
        let open = Set(tabRows.compactMap { row -> String? in
            if case .tab(let match) = row.type { return Self.pageKey(match.url) }
            return nil
        })
        let history = Array(historyRows.filter { row in
            if case .history(let entry) = row.type { return !open.contains(Self.pageKey(entry.url)) }
            return true
        }.prefix(3))
        // Page text matches come after, minus any page already shown above.
        let shown = open.union(history.compactMap { row -> String? in
            if case .history(let entry) = row.type { return Self.pageKey(entry.url) }
            return nil
        })
        let text = textRows.filter { row in
            if case .history(let entry) = row.type { return !shown.contains(Self.pageKey(entry.url)) }
            return false
        }
        updateResults(coalescing: coalescing) {
            let candidates = tabRows + history + Array(text.prefix(3)) + webRows
            $0.suggestions = SearchResultPolicy.retainingShownRows(
                coalescing ? $0.suggestions : [], candidates: candidates, limit: 5
            )
            if let loading { $0.isLoading = loading }
            $0.autofillHost = typedCompletion
        }
    }

    /// History rows found by words in the page's text, when that setting is on.
    @MainActor private func searchPageText(for query: String) async -> [SearchSuggestion] {
        guard let historyManager, tabs?.settings.searchPageTextInHistory == true,
              query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else { return [] }
        // Spare rows for the ones the dedupe in compose drops.
        return await historyManager.searchPageText(query: query, limit: 8).map {
            SearchSuggestion(text: $0.displayTitle, type: .history($0))
        }
    }

    /// One key for a page however its URL was written: no scheme, `www.` or trailing slash.
    private static func pageKey(_ url: URL) -> String {
        var key = (url.host ?? "") + url.path + (url.query.map { "?" + $0 } ?? "")
        if key.hasPrefix("www.") { key.removeFirst(4) }
        if key.hasSuffix("/") { key.removeLast() }
        return key.lowercased()
    }

    /// The words of a query. A row matches when every word is in its title or URL, in any order.
    static func words(of query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// One observation covers the edit session. Re-read current metadata after an observed change.
    private func refreshTabs(for query: String, keepingShownRows: Bool = false) {
        if observingTabs {
            tabRows = searchTabs(for: query, keepingShownRows: keepingShownRows)
            return
        }
        observingTabs = true
        tabRows = withObservationTracking {
            searchTabs(for: query, keepingShownRows: keepingShownRows)
        } onChange: { [weak self] in
            // Observation fires before the write. Read the new title, URL or tree on the next turn.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.observingTabs = false
                guard let query = self.currentQuery else { return }
                self.refreshTabs(for: query, keepingShownRows: true)
                self.compose(coalescing: true)
            }
        }
    }

    @MainActor private func searchTabs(for query: String, keepingShownRows: Bool) -> [SearchSuggestion] {
        guard let tabs, let window, let spaceID = window.spaceID else { return [] }
        let words = Self.words(of: query)
        // This space's tabs first, then the other spaces'. The active page and agent tabs stay out.
        let spaces = [spaceID] + tabs.spaces(visibleIn: window).map(\.id).filter { $0 != spaceID }
        let items = spaces.filter { $0 != tabs.agentSpaceID }.flatMap { tabs.items(inSpace: $0) }
            .filter { $0.id != window.selectedItemID }
        let here = Set(tabs.items(inSpace: spaceID).map(\.id))
        let candidates: [TabSearchCandidate] = items.compactMap { item in
            let session = tabs.session(for: item.id)
            guard let url = session?.url ?? tabs.device.openPages[item.id]?.url ?? item.url else { return nil }
            let title = item.customTitle.flatMap { $0.isEmpty ? nil : $0 } ?? session?.title ?? item.displayTitle
            return TabSearchCandidate(id: item.id, title: title, url: url, isCurrentSpace: here.contains(item.id))
        }
        let ranked = TabSearchRanking.matches(in: candidates, words: words, limit: keepingShownRows ? candidates.count : 2)
        shownTabCandidates = SearchResultPolicy.retainingShownRows(
            keepingShownRows ? shownTabCandidates : [], candidates: ranked, limit: 2
        )
        return shownTabCandidates.map { item in
            let match = TabMatch(itemID: item.id, title: item.title, url: item.url, resolveFavicon: { [weak tabs] in
                tabs?.session(for: item.id)?.favicon
                    ?? FaviconCache.key(for: item.url).flatMap { FaviconCache.shared.swiftUIImage(for: $0) }
                    ?? SwiftUI.Image(systemName: "globe")
            })
            return SearchSuggestion(text: item.title, type: .tab(match))
        }
    }

    @MainActor private func searchHistory(for query: String) async -> [SearchSuggestion] {
        guard let historyManager = historyManager else { return [] }
        
        let words = Self.words(of: query)
        // Enough matches that the sort below, not recency alone, picks the rows shown.
        let historyEntries = await historyManager.searchHistory(query: query, offset: 0, limit: 100)
        
        let matchingHistory = historyEntries.entries.map { entry in
            (entry: entry, titleMatch: words.allSatisfy(entry.title.lowercased().contains))
        }
        let sortedHistory = matchingHistory.sorted { lhs, rhs in
            if lhs.titleMatch != rhs.titleMatch { return lhs.titleMatch }
            if lhs.entry.visitCount != rhs.entry.visitCount { return lhs.entry.visitCount > rhs.entry.visitCount }
            return lhs.entry.lastVisited > rhs.entry.lastVisited
        }
        return sortedHistory.map { SearchSuggestion(text: $0.entry.displayTitle, type: .history($0.entry)) }
    }

    private func fetchWebSuggestions(for query: String) async -> [SearchSuggestion] {
        // Every keystroke goes to the endpoint, so a private window sends none, and Google
        // only hears from people who chose Google. Unknown window or settings: send nothing.
        // ponytail: Google's endpoint only. Add per-engine endpoints if other engines want suggestions.
        guard let window, !window.isIncognito,
              tabs?.settings.searchEngineId == SearchProvider.google.rawValue else { return [] }
        var components = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
        components.queryItems = [URLQueryItem(name: "client", value: "firefox"), URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { return [] }
        do {
            let (data, _) = try await session.data(from: url)
            try Task.checkCancellation()
            guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [Any],
                  jsonArray.count >= 2, let strings = jsonArray[1] as? [String] else { return [] }
            return strings.prefix(5).map {
                SearchSuggestion(text: $0, type: isLikelyURL($0) ? .url : .search)
            }
        } catch { return [] }
    }

    /// Local rows publish immediately. Async legs finishing in one turn share a publication.
    private func updateResults(coalescing: Bool = false, _ update: (inout Results) -> Void) {
        var next = coalescing ? (pendingResults ?? results) : results
        update(&next)
        if coalescing {
            pendingResults = next
            guard publication == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, let pending = self.pendingResults else { return }
                self.pendingResults = nil
                self.publication = nil
                if self.results != pending { self.results = pending }
            }
            publication = work
            DispatchQueue.main.async(execute: work)
        } else {
            publication?.cancel()
            publication = nil
            pendingResults = nil
            if results != next { results = next }
        }
    }

    public func clearSuggestions() {
        searchTask?.cancel()
        historyTask?.cancel()
        typedCompletion = nil
        currentQuery = nil
        shownTabCandidates = []
        tabRows = []
        historyRows = []
        textRows = []
        webRows = []
        searchGeneration = UUID()
        updateResults { $0 = Results() }
    }
}
