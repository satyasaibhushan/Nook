// Licensed under GPL-3.0. See LICENSE.
//
//  AgentSpace.swift
//  NookTabsCore
//
//  The space DevMCP agents browse in. It is found by a marker in `icon`, which nothing
//  displays or edits and older builds carry through a save unchanged. The marker also names a
//  space, whose logins older builds lent the agent; agents now get data stores of their own
//  (`TabsController+Agent.swift`), so the space has none.
//

import Foundation

extension SpaceRecord {
    static let agentIconPrefix = "nook.agent:"
    /// Fixed accent, so folder icons and selection tint match the agent chrome.
    public static let agentAccentHex = "#F2541B"

    public static func agentIcon(loginsFrom spaceID: UUID) -> String { agentIconPrefix + spaceID.uuidString }

    public var isAgent: Bool { Self.isAgentIcon(icon) }
    static func isAgentIcon(_ icon: String) -> Bool { icon.hasPrefix(agentIconPrefix) }
}

extension TabTree {
    public var agentSpace: SpaceRecord? { orderedSpaces.first(where: \.isAgent) }

    /// The id of the website data store `spaceID`'s pages use: the space's shared store, else its
    /// own. Nil for the agent space, whose pages use their callers' stores.
    public func dataStoreID(for spaceID: UUID) -> UUID? {
        guard let space = space(spaceID), !space.isAgent else { return nil }
        return space.dataStoreID ?? space.id
    }

    /// The agent space, created last in order when there is none. Its marker names `loginsFrom`,
    /// else the first ordinary space, for older builds to lend logins from.
    public mutating func ensureAgentSpace(loginsFrom: UUID?, now: Date = Date()) -> (id: UUID, change: Change)? {
        if let existing = agentSpace { return (existing.id, Change()) }
        let given = loginsFrom.flatMap(space).flatMap { $0.isAgent ? nil : $0 }
        let login = given ?? orderedSpaces.first { !$0.isAgent }
        guard let login else { return nil }
        let id = UUID()
        let change = createSpace(id: id, name: "Agent", icon: SpaceRecord.agentIcon(loginsFrom: login.id),
                                 accentHex: SpaceRecord.agentAccentHex, after: orderedSpaces.last?.id, now: now)
        return (id, change)
    }
}
