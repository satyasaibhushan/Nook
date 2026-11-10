// Licensed under GPL-3.0. See LICENSE.
import Foundation
import NookWeb

@main struct FindManagerChecks {
    @MainActor static func drain() async { try? await Task.sleep(for: .milliseconds(10)) }

    @MainActor static func main() async {
        let manager = FindManager()
        let first = PageSession(), second = PageSession()
        manager.showFindBar(for: first)
        manager.search(for: "old", in: first)
        let oldSearch = first.callbacks.removeFirst()
        manager.hideFindBar()
        manager.showFindBar(for: first)
        manager.search(for: "new", in: first)
        first.callbacks.removeFirst()(.success((3, 1)))
        oldSearch(.success((99, 99)))
        try? await Task.sleep(for: .milliseconds(300))
        precondition(manager.searchText == "new" && manager.matchCount == 3 && manager.currentSession === first)

        manager.findNext()
        let oldNext = first.callbacks.removeFirst()
        manager.findPrevious()
        let oldPrevious = first.callbacks.removeFirst()
        manager.search(for: "latest", in: first)
        first.callbacks.removeFirst()(.success((4, 2)))
        oldNext(.success((50, 50)))
        oldPrevious(.success((60, 60)))
        await drain()
        precondition(manager.matchCount == 4 && manager.currentMatchIndex == 2)

        manager.findNext()
        let oldSessionResult = first.callbacks.removeFirst()
        manager.updateCurrentSession(second)
        second.callbacks.removeFirst()(.success((7, 1)))
        oldSessionResult(.success((90, 90)))
        await drain()
        precondition(manager.searchText == "latest" && manager.matchCount == 7 && manager.currentSession === second)

        manager.findNext()
        let beforeNavigation = second.callbacks.removeFirst()
        second.loadingNavigationID = UUID()
        beforeNavigation(.success((88, 88)))
        await drain()
        precondition(manager.matchCount == 7)
        manager.clearSearch()
        precondition(!manager.isSearching && manager.matchCount == 0 && manager.searchText.isEmpty)
        print("FindManager checks passed: reopen, query, next/previous, session and navigation generations")
    }
}
