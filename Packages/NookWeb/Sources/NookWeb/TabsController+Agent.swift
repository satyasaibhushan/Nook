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
    /// The name of the space whose cookies seed new browsing sessions, or nil for none.
    public let logins: String?
    let loginSpaceID: UUID?
    public let folderID: UUID
    /// The tab tools act on; `TabsController.agentCurrentTab(of:)` falls back when it is gone.
    public internal(set) var currentTab: UUID?
    /// Tabs opened with a `tab` name, so workers sharing one connection each keep their own
    /// tab without moving `currentTab` under the others.
    @ObservationIgnored public internal(set) var tabNames: [String: UUID] = [:]
    @ObservationIgnored public internal(set) var profile: Profile
    /// Tool calls of this caller running now.
    @ObservationIgnored public var callsInFlight = 0
    /// Set while its pages are out of the window for being idle.
    @ObservationIgnored public var isParked = false
    /// The size its pages render at, in points; nil follows the window. A window showing the
    /// Agent space renders them at its own size.
    @ObservationIgnored public var viewport: CGSize?
    @ObservationIgnored public var idleTask: Task<Void, Never>?

    init(id: String, label: String, logins: String?, loginSpaceID: UUID?, folderID: UUID, profile: Profile) {
        self.id = id
        self.label = label
        self.logins = logins
        self.loginSpaceID = loginSpaceID
        self.folderID = folderID
        self.profile = profile
    }
}

public enum AgentCallerError: LocalizedError {
    case noSpace
    case unknownLogins(String, available: [String])
    case workspaceClosed
    case tabNameInUse(String)

    public var errorDescription: String? {
        switch self {
        case .noSpace: return "No space to make the Agent space next to"
        case .workspaceClosed: return "The agent workspace closed before the tab could open. Retry the request."
        case .tabNameInUse(let name): return "A tab named \(name) is already open."
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

    /// Starts a caller's folder. A named space seeds the store when its first tab opens.
    /// Agent space tabs no live caller owns are left from an earlier run and close.
    public func startAgentCaller(id: String, name: String, logins: String?) throws -> AgentCaller {
        if let existing = agentCallers[id] { return existing }
        let source: SpaceRecord?
        if let logins {
            guard let space = tree.orderedSpaces.first(where: { !$0.isAgent && $0.name.caseInsensitiveCompare(logins) == .orderedSame })
            else { throw AgentCallerError.unknownLogins(logins, available: agentLoginChoices) }
            source = space
        } else {
            source = nil
        }
        guard let agent = ensureAgentSpace() else { throw AgentCallerError.noSpace }
        closeOrphanedAgentTabs(in: agent)

        let label = uniqueAgentLabel("\(name) · \(source?.name ?? "No logins")")
        let lastFolder = tree.children(of: .tabs(spaceID: agent)).last?.id
        let folderID = UUID()
        guard perform(.main, "agentCaller", undoable: false, {
            try $0.createFolder(id: folderID, title: label, in: .tabs(spaceID: agent), after: lastFolder)
        }) != nil else { throw AgentCallerError.noSpace }
        openFolder(folderID)
        let caller = AgentCaller(id: id, label: label, logins: source?.name, loginSpaceID: source?.id,
                                 folderID: folderID, profile: agentProfile(label: label))
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

    /// `caller`'s tab opened under `name`, while it still has it.
    public func agentTab(named name: String, of caller: AgentCaller) -> UUID? {
        guard let id = caller.tabNames[name], agentTabs(of: caller).contains(id) else { return nil }
        return id
    }

    /// The name `itemID` was opened under, if any.
    public func agentTabName(_ itemID: UUID, of caller: AgentCaller) -> String? {
        caller.tabNames.first { $0.value == itemID }?.key
    }

    /// Whether `itemID` is the tab some caller's tools act on.
    public func isAgentCurrentTab(_ itemID: UUID) -> Bool {
        agentCallers.values.contains { $0.currentTab == itemID }
    }

    /// A new tab at the end of `caller`'s folder: its current tab, or, given a `name`, a tab
    /// addressed by that name that leaves the current tab alone.
    @discardableResult
    public func openAgentTab(_ url: URL, for caller: AgentCaller, name: String? = nil) async throws -> UUID? {
        try await refreshAgentLoginsIfEmpty(caller)
        try Task.checkCancellation()
        guard agentCallers[caller.id] === caller, tree.item(caller.folderID) != nil else {
            throw AgentCallerError.workspaceClosed
        }
        if let name, agentTab(named: name, of: caller) != nil {
            throw AgentCallerError.tabNameInUse(name)
        }
        let last = tree.children(of: .folder(itemID: caller.folderID)).last?.id
        let id = UUID()
        guard perform(.main, "open", {
            try $0.createTab(id: id, url: url, title: url.host ?? url.absoluteString, in: .folder(itemID: caller.folderID), after: last)
        }) != nil else { return nil }
        if let name { caller.tabNames[name] = id }
        selectForAgent(id, makeCurrent: name == nil)
        return id
    }

    /// Replace the store so removed source cookies and the agent's old cookies cannot survive.
    /// An opener that lost the race uses the winner's store, or retries if that batch already closed.
    private func refreshAgentLoginsIfEmpty(_ caller: AgentCaller) async throws {
        guard let sourceID = caller.loginSpaceID, let logins = caller.logins else { return }
        while agentTabs(of: caller).isEmpty {
            guard agentCallers[caller.id] === caller, tree.item(caller.folderID) != nil else {
                throw AgentCallerError.workspaceClosed
            }
            guard let source = profile(forSpace: sourceID) else {
                throw AgentCallerError.unknownLogins(logins, available: agentLoginChoices)
            }
            let previous = caller.profile
            let refreshed = agentProfile(label: caller.label)
            for cookie in await source.dataStore.httpCookieStore.allCookies() {
                try Task.checkCancellation()
                await refreshed.dataStore.httpCookieStore.setCookie(cookie)
            }
            try Task.checkCancellation()
            guard agentCallers[caller.id] === caller, tree.item(caller.folderID) != nil else {
                throw AgentCallerError.workspaceClosed
            }
            guard agentTabs(of: caller).isEmpty else { return }
            guard caller.profile === previous else { continue }
            caller.profile = refreshed
            previous.destroyEphemeralDataStore()
            return
        }
    }

    private func agentProfile(label: String) -> Profile {
        let profile = Profile(name: label, icon: "sparkles", dataStore: .nonPersistent())
        profile.isEphemeral = true
        return profile
    }

    /// Makes `itemID` its caller's current tab. Windows showing the Agent space show it; the
    /// others only remember it for when the person opens the space. The page loads either way;
    /// with `makeCurrent` false only that happens, for a tab addressed by name.
    public func selectForAgent(_ itemID: UUID, makeCurrent: Bool = true) {
        guard let agent = agentSpaceID, tree.spaceID(of: itemID) == agent else { return }
        if makeCurrent { agentCaller(owning: itemID)?.currentTab = itemID }
        for other in regularWindows where makeCurrent {
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
        let profile = agentProfile(label: "Agent")
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
