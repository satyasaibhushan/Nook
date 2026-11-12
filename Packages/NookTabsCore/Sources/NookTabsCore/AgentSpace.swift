// Licensed under GPL-3.0. See LICENSE.
//
//  AgentSpace.swift
//  NookTabsCore
//
//  The space DevMCP agents browse in. It is found by a marker in `icon`, which nothing
//  displays or edits and older builds carry through a save unchanged; the marker also names
//  the space whose logins (website data store) the agent uses.
//

import Foundation

extension SpaceRecord {
    static let agentIconPrefix = "nook.agent:"
    /// Fixed accent, so folder icons and selection tint match the agent chrome.
    public static let agentAccentHex = "#F2541B"

    public static func agentIcon(loginsFrom spaceID: UUID) -> String { agentIconPrefix + spaceID.uuidString }

    public var isAgent: Bool { Self.isAgentIcon(icon) }
    static func isAgentIcon(_ icon: String) -> Bool { icon.hasPrefix(agentIconPrefix) }

    /// The space whose logins this agent space borrows, as recorded at creation.
    public var agentLoginSpaceID: UUID? {
        isAgent ? UUID(uuidString: String(icon.dropFirst(Self.agentIconPrefix.count))) : nil
    }
}

extension TabTree {
    public var agentSpace: SpaceRecord? { orderedSpaces.first(where: \.isAgent) }

    /// The space whose data store `spaceID`'s pages use: itself, or for the agent space the
    /// space it borrows logins from, else the first ordinary space.
    public func loginSpace(for spaceID: UUID) -> UUID? {
        guard let space = space(spaceID) else { return nil }
        guard space.isAgent else { return spaceID }
        if let borrowed = space.agentLoginSpaceID.flatMap(self.space), !borrowed.isAgent { return borrowed.id }
        return orderedSpaces.first { !$0.isAgent }?.id
    }

    /// The id of the website data store `spaceID`'s pages use: its login space's shared store,
    /// else that space's own.
    public func dataStoreID(for spaceID: UUID) -> UUID? {
        guard let login = loginSpace(for: spaceID).flatMap(space) else { return nil }
        return login.dataStoreID ?? login.id
    }

    /// The agent space, created last in order with logins from `loginsFrom` when there is none.
    /// An existing one with no tabs takes `loginsFrom`'s logins too, so the agent signs in as the
    /// space the person is on now; with tabs it keeps its logins, since a switch would reload
    /// pages an agent is working in.
    public mutating func ensureAgentSpace(loginsFrom: UUID?, now: Date = Date()) -> (id: UUID, change: Change)? {
        let given = loginsFrom.flatMap(space).flatMap { $0.isAgent ? nil : $0 }
        if let existing = agentSpace {
            let hasTabs = items.values.contains { $0.deletedAt == nil && !$0.isFolder && spaceID(of: $0.id) == existing.id }
            guard let given, !hasTabs, existing.agentLoginSpaceID != given.id,
                  let change = try? updateSpace(existing.id, icon: SpaceRecord.agentIcon(loginsFrom: given.id), now: now)
            else { return (existing.id, Change()) }
            return (existing.id, change)
        }
        let login = given ?? orderedSpaces.first { !$0.isAgent }
        guard let login else { return nil }
        let id = UUID()
        let change = createSpace(id: id, name: "Agent", icon: SpaceRecord.agentIcon(loginsFrom: login.id),
                                 accentHex: SpaceRecord.agentAccentHex, after: orderedSpaces.last?.id, now: now)
        return (id, change)
    }
}
