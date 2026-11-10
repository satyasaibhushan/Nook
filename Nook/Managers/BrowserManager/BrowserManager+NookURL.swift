// Licensed under GPL-3.0. See LICENSE.
//
//  BrowserManager+NookURL.swift
//  Nook
//

import AppKit
import NookTabsCore
import NookWeb
import OSLog

private let nookURLLog = Logger(subsystem: "com.gstudios.nook", category: "NookURL")

extension BrowserManager {
    /// Runs a nook:// link from another app. Dropped unless Settings > Links allows it.
    func handleNookURL(_ link: URL) {
        guard nookSettings?.allowNookURLs == true else {
            nookURLLog.info("Dropped nook:// link: not allowed in Settings")
            return
        }
        guard let command = NookURLCommand.parse(link) else {
            nookURLLog.info("Ignored nook:// link: \(link.host ?? "", privacy: .public) is not a valid command")
            return
        }
        if !command.ignored.isEmpty {
            nookURLLog.info("Ignored nook:// parameters: \(command.ignored.joined(separator: ","), privacy: .public)")
        }
        switch command.action {
        case .open, .search, .switchSpace:
            break
        case .close(let id), .pin(let id), .unpin(let id), .reload(let id), .move(let id, _), .select(let id):
            runItemCommand(command.action, on: id)
            return
        }

        var spaceID: UUID?
        if let name = command.space {
            let choices = tabs.orderedSpaces.filter { !$0.isAgent }.map { (id: $0.id, name: $0.name) }
            guard let match = NookURLCommand.match(name, in: choices) else {
                nookURLLog.info("Ignored nook:// link: no such space")
                return
            }
            spaceID = match
        }
        guard let window = openBrowserWindow(), !window.isIncognito else { return }
        // A window showing the Agent space opens into the first ordinary one.
        if spaceID == nil, window.spaceID.flatMap({ tabs.space($0) })?.isAgent == true {
            spaceID = tabs.orderedSpaces.first { !$0.isAgent }?.id
        }

        switch command.action {
        case .switchSpace:
            if let spaceID { tabs.setSpace(spaceID, in: window) }
        case .open(let url, let reuse):
            openFromLauncher(url, reuse: reuse, space: spaceID, explicit: command.space != nil, in: window)
        case .search(let query):
            guard let template = nookSettings?.resolvedSearchEngineTemplate,
                  let url = NookURLCommand.searchURL(for: query, template: template) else { return }
            openFromLauncher(url, reuse: false, space: spaceID, explicit: command.space != nil, in: window)
        case .close, .pin, .unpin, .reload, .move, .select:
            break
        }
    }

    /// Acts on one sidebar item from a launcher. Only select brings a window forward (or makes
    /// one); the rest edit the tree or the page directly, so the launcher's app stays in front.
    private func runItemCommand(_ action: NookURLCommand.Action, on id: UUID) {
        // A private window's items resolve to its own temporary space, which is not in this list.
        guard let item = tabs.item(id), let spaceID = tabs.spaceID(of: id),
              tabs.orderedSpaces.contains(where: { $0.id == spaceID && !$0.isAgent }) else {
            nookURLLog.info("Ignored nook:// link: no such item")
            return
        }
        switch action {
        case .close:
            tabs.close(id)
        case .pin:
            guard !item.isFolder, case .tabs? = tabs.section(of: id) else {
                nookURLLog.info("Ignored nook:// pin: not a tab in the tabs section")
                return
            }
            tabs.pin(id, to: .pinned(spaceID: spaceID))
        case .unpin:
            guard !item.isFolder, case .pinned? = tabs.section(of: id) else {
                nookURLLog.info("Ignored nook:// unpin: not a pinned tab")
                return
            }
            tabs.unpin(id)
        case .reload:
            guard let page = tabs.session(for: id), !page.isUnloaded else {
                nookURLLog.info("Ignored nook:// reload: no live page")
                return
            }
            page.refresh()
        case .move(_, let folderID):
            guard folderID != id, tabs.item(folderID)?.isFolder == true, tabs.spaceID(of: folderID) == spaceID else {
                nookURLLog.info("Ignored nook:// move: no such folder in the item's space")
                return
            }
            let folder = Parent.folder(itemID: folderID)
            tabs.move(id, to: folder, after: tabs.children(of: folder).last { $0.id != id }?.id)
        case .select:
            guard !item.isFolder else {
                nookURLLog.info("Ignored nook:// select: a folder")
                return
            }
            guard let window = openBrowserWindow(), !window.isIncognito else { return }
            tabs.select(id, in: window)
        case .open, .search, .switchSpace:
            break
        }
    }

    private func openFromLauncher(_ url: URL, reuse: Bool, space: UUID?, explicit: Bool, in window: BrowserWindowState) {
        if reuse, let target = space ?? window.spaceID,
           let existing = tabs.items(inSpace: target).first(where: { $0.url.map { NookURLCommand.isSamePage($0, url) } == true }) {
            tabs.select(existing.id, in: window)
            return
        }
        // Air Traffic Control only decides when the link names no space.
        if !explicit, siteRoutingManager.applyRoute(url: url, from: nil) { return }
        tabs.open(url: url, in: window, placement: .newTab, parent: space.map { .tabs(spaceID: $0) })
    }
}
