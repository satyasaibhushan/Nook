// Licensed under GPL-3.0. See LICENSE.
//
//  BrowserManager+Attention.swift
//  Nook
//
//  Opens the Attention tab, reusing the one already open instead of stacking copies.
//

import Foundation
import NookWeb

extension BrowserManager {
    /// Shows the Attention tab in the last-used regular window. A section of "activity"
    /// lands on the Activity part of the page.
    func openAttention(section: String? = nil) {
        let target = attentionPageURL(section: section)
        guard let window = openBrowserWindow(), !window.isIncognito else { return }

        // An agent space copy stays the agent's; a person's Attention tab is in a regular space.
        for space in tabs.orderedSpaces where !space.isAgent {
            guard let existing = tabs.items(inSpace: space.id).first(where: {
                !$0.isFolder && $0.url.map(isAttentionPageURL) == true
            }) else { continue }
            tabs.select(existing.id, in: window)
            if existing.url.map({ !NookURLCommand.isSamePage($0, target) }) == true,
               let session = tabs.session(for: existing.id) {
                session.load(target)
            }
            return
        }

        // A window showing the Agent space opens into the first ordinary one, as nook://open does.
        let ordinary = tabs.orderedSpaces.first { !$0.isAgent }?.id
        let inAgent = window.spaceID.flatMap { tabs.space($0) }?.isAgent == true
        tabs.open(url: target, in: window, placement: .newTab,
                  parent: inAgent ? ordinary.map { .tabs(spaceID: $0) } : nil, title: "Attention")
    }
}
