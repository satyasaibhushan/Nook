// Licensed under GPL-3.0. See LICENSE.
import Foundation
import SwiftUI
import NookWeb

@MainActor
class FindManager: ObservableObject {
    @Published var isFindBarVisible = false
    @Published var searchText = ""
    @Published var matchCount = 0
    @Published var currentMatchIndex = 0
    @Published var isSearching = false

    private(set) var currentSession: PageSession?
    private var generation = UUID()
    private var cleanupTask: Task<Void, Never>?

    private func invalidateRequests() {
        generation = UUID()
        cleanupTask?.cancel()
        cleanupTask = nil
        isSearching = false
    }

    func showFindBar(for session: PageSession? = nil) {
        invalidateRequests()
        currentSession?.clearFindInPage()
        currentSession = session
        isFindBarVisible = true
        searchText = ""
        matchCount = 0
        currentMatchIndex = 0
    }

    func hideFindBar() {
        invalidateRequests()
        currentSession?.clearFindInPage()
        isFindBarVisible = false
        let generation = generation
        // Preserve the outgoing text during the exit animation, unless another presentation starts.
        cleanupTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.25))
            guard !Task.isCancelled, let self, self.generation == generation,
                  !self.isFindBarVisible else { return }
            self.searchText = ""
            self.matchCount = 0
            self.currentMatchIndex = 0
            self.currentSession = nil
            self.cleanupTask = nil
        }
    }

    func search(for text: String, in session: PageSession?) {
        guard isFindBarVisible else { return }
        invalidateRequests()
        if currentSession !== session { currentSession?.clearFindInPage() }
        currentSession = session
        searchText = text
        matchCount = 0
        currentMatchIndex = 0
        guard let session, !text.isEmpty else {
            currentSession?.clearFindInPage()
            return
        }
        isSearching = true
        session.findInPage(text, completion: completion(for: session))
    }

    func findNext() {
        guard isFindBarVisible, let session = currentSession, !searchText.isEmpty else { return }
        invalidateRequests()
        session.findNextInPage(completion: completion(for: session))
    }

    func findPrevious() {
        guard isFindBarVisible, let session = currentSession, !searchText.isEmpty else { return }
        invalidateRequests()
        session.findPreviousInPage(completion: completion(for: session))
    }

    private func completion(for session: PageSession) -> PageSession.FindCompletion {
        let generation = generation
        let query = searchText
        let navigationID = session.loadingNavigationID
        let webViewID = session.webView.map(ObjectIdentifier.init)
        return { [weak self, weak session] result in
            DispatchQueue.main.async {
                guard let self, let session, self.generation == generation,
                      self.currentSession === session, self.searchText == query,
                      session.loadingNavigationID == navigationID,
                      session.webView.map(ObjectIdentifier.init) == webViewID,
                      self.isFindBarVisible else { return }
                self.isSearching = false
                switch result {
                case .success(let (count, index)):
                    self.matchCount = count
                    self.currentMatchIndex = index
                case .failure:
                    break
                }
            }
        }
    }

    func clearSearch() {
        invalidateRequests()
        currentSession?.clearFindInPage()
        searchText = ""
        matchCount = 0
        currentMatchIndex = 0
    }

    func updateCurrentSession(_ session: PageSession?) {
        guard currentSession !== session else { return }
        invalidateRequests()
        currentSession?.clearFindInPage()
        currentSession = session
        matchCount = 0
        currentMatchIndex = 0
        if isFindBarVisible && !searchText.isEmpty {
            search(for: searchText, in: session)
        }
    }
}
