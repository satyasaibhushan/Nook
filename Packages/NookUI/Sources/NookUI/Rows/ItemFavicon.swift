// Licensed under GPL-3.0. See LICENSE.
//
//  ItemFavicon.swift
//  NookUI
//
//  The favicon every row and tile draws, and the inline-rename state the rows and the
//  context menu share.
//

import SwiftUI
import NookTabsCore
import NookWeb

// MARK: - Rename State

/// The row being renamed inline. Shared so a context menu can start a rename on its row.
@MainActor
@Observable
final class SidebarRenameState {
    static let shared = SidebarRenameState()
    var itemID: UUID?
}

extension TabsController {
    /// Creates a "New Folder" under `parent` after `after` and starts renaming it inline.
    public func createFolderForRename(in parent: Parent, after: UUID?) {
        guard let folderID = createFolder(title: "New Folder", in: parent, after: after) else { return }
        if case .folder(let outer) = parent { openFolder(outer) }
        SidebarRenameState.shared.itemID = folderID
    }
}

// MARK: - Favicon

/// A row or tile favicon: the live page's, else the cached one for the item's host, else one
/// fetched from the site for a row with no page, else a globe.
public struct ItemFavicon: View {
    let item: Item
    let session: PageSession?
    @State private var cached: Image?

    public init(item: Item, session: PageSession?) {
        self.item = item
        self.session = session
    }

    public var body: some View {
        (session?.favicon ?? cached ?? Image(systemName: "globe"))
            .resizable()
            .scaledToFit()
            // Keyed on the session too: closing a pinned tab or favorite ends its page but keeps
            // the row, and the cached icon must be loaded then.
            .task(id: "\(item.url.flatMap(FaviconCache.key) ?? "")|\(session == nil)") {
                session?.ensureFaviconLoaded()
                guard let url = item.url, let host = FaviconCache.key(for: url) else { return }
                // A live page fetches its own icon, with its private-window rules; only a saved or
                // pinned row with no page goes to the network here.
                let image = session == nil
                    ? await FaviconCache.shared.image(fetchingIfMissing: url)
                    : await FaviconCache.shared.cachedImage(for: host)
                guard let image, !Task.isCancelled else { return }
                cached = Image(platformImage: image)
            }
    }
}
