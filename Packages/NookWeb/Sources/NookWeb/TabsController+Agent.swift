// Licensed under GPL-3.0. See LICENSE.
//
//  TabsController+Agent.swift
//  NookWeb
//
//  The Agent space: where DevMCP agents browse. Each connected agent (an MCP session) is a
//  caller with a folder of its own tabs and a website data store of its own, empty or holding a
//  one-way copy of one space's cookies, so nothing an agent does signs the person in or out.
//  Agent activity never changes what a window shows; the person opens the space to watch.
//

import Foundation
import WebKit
import NookTabsCore

/// One connected agent: its folder of tabs in the Agent space, the tab its tools act on, and the
/// data store its pages use.
@MainActor
@Observable
public final class AgentCaller {
    /// The MCP session id.
    public let id: String
    /// The client name with the logins it borrowed, shown as its folder's title.
    public let label: String
    /// The name of the space whose cookies were copied in at the start, or nil for none.
    public let logins: String?
    public let folderID: UUID
    /// The tab tools act on; `TabsController.agentCurrentTab(of:)` falls back when it is gone.
    public internal(set) var currentTab: UUID?
    @ObservationIgnored public let profile: Profile
    /// Tool calls of this caller running now.
    @ObservationIgnored public var callsInFlight = 0
    /// Set while its pages are out of the window for being idle.
    @ObservationIgnored public var isParked = false
    @ObservationIgnored public var idleTask: Task<Void, Never>?

    init(id: String, label: String, logins: String?, folderID: UUID, profile: Profile) {
        self.id = id
        self.label = label
        self.logins = logins
        self.folderID = folderID
        self.profile = profile
    }
}

public enum AgentCallerError: LocalizedError {
    case noSpace
    case unknownLogins(String, available: [String])

    public var errorDescription: String? {
        switch self {
        case .noSpace: return "No space to make the Agent space next to"
        case .unknownLogins(let name, let available):
            return "No space named \(name). logins takes one of: \(available.joined(separator: ", ")), or none."
        }
    }
}

extension TabsController {
    public var agentSpaceID: UUID? { tree.agentSpace?.id }

    public func isInAgentSpace(_ itemID: UUID) -> Bool {
        guard let agent = agentSpaceID else { return false }
        return tree.spaceID(of: itemID) == agent
    }

    /// The Agent space, made on first use.
    @discardableResult
    public func ensureAgentSpace() -> UUID? {
        if let existing = agentSpaceID { return existing }
        var made: UUID?
        perform(.main, "agentSpace", undoable: false) { tree in
            guard let result = tree.ensureAgentSpace(loginsFrom: nil) else { throw TreeError.missingSpace }
            made = result.id
            return result.change
        }
        return made
    }

    // MARK: - Callers

    /// Names `logins` accepts: the person's spaces.
    public var agentLoginChoices: [String] {
        tree.orderedSpaces.filter { !$0.isAgent }.map(\.name)
    }

    /// Starts caller `id`: a folder in the Agent space titled `name · logins` and a fresh data
    /// store, holding a copy of the cookies of the space named `logins` (any case) when given.
    /// Agent space tabs no live caller owns are left from an earlier run and close.
    public func startAgentCaller(id: String, name: String, logins: String?) async throws -> AgentCaller {
        var source: (name: String, profile: Profile)?
        if let logins {
            guard let space = tree.orderedSpaces.first(where: { !$0.isAgent && $0.name.caseInsensitiveCompare(logins) == .orderedSame }),
                  let profile = profile(forSpace: space.id)
            else { throw AgentCallerError.unknownLogins(logins, available: agentLoginChoices) }
            source = (space.name, profile)
        }
        let store = WKWebsiteDataStore.nonPersistent()
        if let source {
            // One way: the agent's sign-outs and new cookies stay in its own store.
            for cookie in await source.profile.dataStore.httpCookieStore.allCookies() {
                await store.httpCookieStore.setCookie(cookie)
            }
        }
        // Another call of this session may have started it while the cookies copied.
        if let existing = agentCallers[id] { return existing }
        guard let agent = ensureAgentSpace() else { throw AgentCallerError.noSpace }
        closeOrphanedAgentTabs(in: agent)

        let label = uniqueAgentLabel("\(name) · \(source?.name ?? "No logins")")
        let profile = Profile(name: label, icon: "sparkles", dataStore: store)
        profile.isEphemeral = true
        let lastFolder = tree.children(of: .tabs(spaceID: agent)).last?.id
        let folderID = UUID()
        guard perform(.main, "agentCaller", undoable: false, {
            try $0.createFolder(id: folderID, title: label, in: .tabs(spaceID: agent), after: lastFolder)
        }) != nil else { throw AgentCallerError.noSpace }
        openFolder(folderID)
        let caller = AgentCaller(id: id, label: label, logins: source?.name, folderID: folderID, profile: profile)
        agentCallers[id] = caller
        return caller
    }

    /// Closes caller `id`'s folder and tabs and drops its data store.
    public func endAgentCaller(_ id: String) {
        guard let caller = agentCallers.removeValue(forKey: id) else { return }
        caller.idleTask?.cancel()
        remove(caller.folderID, promotingChildren: false, archiving: nil)
        caller.profile.destroyEphemeralDataStore()
    }

    /// Closes `caller`'s tabs and keeps its folder and logins for its next call.
    public func closeAgentTabs(of caller: AgentCaller) {
        let tabs = tree.children(of: .folder(itemID: caller.folderID)).map(\.id)
        guard !tabs.isEmpty else { return }
        grouped {
            for id in tabs { remove(id, promotingChildren: false, archiving: nil) }
        }
    }

    /// The caller whose folder holds `itemID`, at any depth.
    public func agentCaller(owning itemID: UUID) -> AgentCaller? {
        guard !agentCallers.isEmpty else { return nil }
        var id = itemID
        for _ in 0..<64 {
            guard let item = tree.item(id) else { return nil }
            if item.isFolder, let caller = agentCallers.values.first(where: { $0.folderID == id }) { return caller }
            guard case .folder(let parent) = item.parent else { return nil }
            id = parent
        }
        return nil
    }

    /// `caller`'s tabs in sidebar order, a tab's trail right after it.
    public func agentTabs(of caller: AgentCaller) -> [UUID] {
        tree.subtree(of: caller.folderID).filter { tree.item($0)?.isFolder == false }
    }

    /// The tab `caller`'s tools act on: its last pick while it still has it, else its first tab.
    public func agentCurrentTab(of caller: AgentCaller) -> UUID? {
        let tabs = agentTabs(of: caller)
        if let current = caller.currentTab, tabs.contains(current) { return current }
        return tabs.first
    }

    /// Whether `itemID` is the tab some caller's tools act on.
    public func isAgentCurrentTab(_ itemID: UUID) -> Bool {
        agentCallers.values.contains { $0.currentTab == itemID }
    }

    /// A new tab at the end of `caller`'s folder, made its current tab.
    @discardableResult
    public func openAgentTab(_ url: URL, for caller: AgentCaller) -> UUID? {
        let last = tree.children(of: .folder(itemID: caller.folderID)).last?.id
        let id = UUID()
        guard perform(.main, "open", {
            try $0.createTab(id: id, url: url, title: url.host ?? url.absoluteString, in: .folder(itemID: caller.folderID), after: last)
        }) != nil else { return nil }
        selectForAgent(id)
        return id
    }

    /// Makes `itemID` its caller's current tab. Windows showing the Agent space show it; the
    /// others only remember it for when the person opens the space. The page loads either way.
    public func selectForAgent(_ itemID: UUID) {
        guard let agent = agentSpaceID, tree.spaceID(of: itemID) == agent else { return }
        agentCaller(owning: itemID)?.currentTab = itemID
        for other in regularWindows {
            if other.spaceID == agent {
                if other.selectedItemID != itemID { select(itemID, in: other) }
            } else {
                other.selectedItemBySpace[agent] = itemID
                other.emptiedSpaces.remove(agent)
                mirror(other)
            }
        }
        guard let session = ensureSession(for: itemID) else { return }
        session.loadWebViewIfNeeded()
        onAgentPage?(session)
    }

    /// The data store of an Agent space page no caller owns: a throwaway one, so even a tab the
    /// person opens there never touches their logins.
    var agentLooseProfile: Profile {
        if let existing = agentLooseProfileStorage { return existing }
        let profile = Profile(name: "Agent", icon: "sparkles", dataStore: .nonPersistent())
        profile.isEphemeral = true
        agentLooseProfileStorage = profile
        return profile
    }

    private func uniqueAgentLabel(_ base: String) -> String {
        let taken = Set(agentCallers.values.map(\.label))
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Top-level tabs and folders of the Agent space's tabs section that no live caller owns.
    private func closeOrphanedAgentTabs(in agent: UUID) {
        let owned = Set(agentCallers.values.map(\.folderID))
        let orphans = tree.children(of: .tabs(spaceID: agent)).map(\.id).filter { !owned.contains($0) }
        guard !orphans.isEmpty else { return }
        grouped {
            for id in orphans { remove(id, promotingChildren: false, archiving: nil) }
        }
    }
}

extension PageSession {
    /// A page in the Agent space: it opens no window, sheet or panel and records no history.
    public var isAgentPage: Bool { controller?.isInAgentSpace(itemID) == true }
}
