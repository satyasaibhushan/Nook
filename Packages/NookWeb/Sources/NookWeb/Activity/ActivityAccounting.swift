// Licensed under GPL-3.0. See LICENSE.

import Foundation

private let activityTrackingNames: Set<String> = ["fbclid", "gclid", "si", "ref", "ref_src", "igshid", "mc_cid", "mc_eid"]

public func normalizedActivityURL(_ url: URL) -> URL? {
    guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
          ["http", "https", "file"].contains(parts.scheme?.lowercased() ?? "")
    else { return nil }
    if parts.scheme?.lowercased() != "file", parts.host?.isEmpty != false { return nil }
    parts.scheme = parts.scheme?.lowercased()
    parts.host = parts.host?.lowercased()
    parts.fragment = nil
    let query = parts.queryItems?.filter {
        let name = $0.name.lowercased()
        return !name.hasPrefix("utm_") && !activityTrackingNames.contains(name)
    }
    parts.queryItems = query?.isEmpty == false ? query : nil
    if parts.percentEncodedPath.count > 1, parts.percentEncodedPath.hasSuffix("/") {
        parts.percentEncodedPath.removeLast()
    }
    return parts.url
}

public func activityLogFileName(machine: String, start: Date, calendar: Calendar = .current) -> String {
    let safe = String(machine.unicodeScalars.map {
        CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) ? Character(String($0)) : "-"
    }).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    let day = calendar.dateComponents([.year, .month, .day], from: start)
    return String(format: "%@-%04d-%02d-%02d.jsonl", safe.isEmpty ? "Mac" : safe,
                  day.year!, day.month!, day.day!)
}

public struct ActivityRecord: Codable, Equatable, Sendable {
    public var v = 1
    public var start: String
    public var end: String
    public var machine: String
    public var space: String
    public var url: String
    public var title: String
    public var active: Double
    public var media: Double
    public var background: Bool
    public var mode: String?

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(machine, forKey: .machine)
        try c.encode(space, forKey: .space)
        try c.encode(url, forKey: .url)
        try c.encode(title, forKey: .title)
        try c.encode(active, forKey: .active)
        try c.encode(media, forKey: .media)
        try c.encode(background, forKey: .background)
        try c.encode(mode, forKey: .mode)
    }
}

public struct ActivityPage: Equatable {
    public var id: UUID
    public var url: URL
    public var title: String
    public var space: String
    /// Non-nil only for the selected tab of the frontmost key browser window.
    public var foregroundWindow: UUID?
    public var playingMedia: Bool

    public init(id: UUID, url: URL, title: String, space: String, foregroundWindow: UUID?, playingMedia: Bool) {
        self.id = id; self.url = url; self.title = title; self.space = space
        self.foregroundWindow = foregroundWindow; self.playingMedia = playingMedia
    }
}

/// The caller supplies event times, so accounting can be checked without an app or wall clock.
public struct ActivityAccounting {
    public struct Stretch: Codable {
        public var id: UUID
        public var fileName: String
        public var record: ActivityRecord
    }
    private struct Open {
        var page: ActivityPage
        var mode: String?
        var start: Date
        var end: Date
        var active = 0.0
        var media = 0.0
        var id = UUID()
    }
    private var open: [UUID: Open] = [:]
    private var lastTime: Date?
    private var lastInput: Date = .distantPast
    private let machine: String
    private var calendar: Calendar

    public init(machine: String, calendar: Calendar = .current) {
        self.machine = machine; self.calendar = calendar
    }

    public mutating func update(at now: Date, pages: [ActivityPage], lastInput: Date, mode: String?) -> [Stretch] {
        var closed: [Stretch] = []
        // Accrue the previous state before adopting a navigation, selection or playback event.
        if let previous = lastTime, now >= previous {
            var cursor = previous
            while cursor < now {
                let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: cursor))!
                let end = min(now, midnight)
                for id in Array(open.keys) {
                    var stretch = open[id]!
                    let duration = end.timeIntervalSince(cursor)
                    if stretch.page.playingMedia { stretch.media += duration }
                    if stretch.page.foregroundWindow != nil {
                        stretch.active += stretch.page.playingMedia ? duration
                            : max(0, min(end, self.lastInput.addingTimeInterval(120)).timeIntervalSince(cursor))
                    }
                    stretch.end = end
                    open[id] = stretch
                }
                if end == midnight {
                    for id in Array(open.keys) {
                        let old = open[id]!
                        if let row = row(old) { closed.append(row) }
                        open[id] = Open(page: old.page, mode: old.mode, start: end, end: end)
                    }
                }
                cursor = end
            }
        }
        let normalized = Dictionary(uniqueKeysWithValues: pages.compactMap { page -> (UUID, ActivityPage)? in
            guard let url = normalizedActivityURL(page.url) else { return nil }
            var page = page; page.url = url
            return (page.id, page)
        })
        let eligible = normalized.filter { $0.value.foregroundWindow != nil || $0.value.playingMedia }
        for id in Array(open.keys) {
            var old = open[id]!
            if let current = normalized[id], current.url == old.page.url { old.page.title = current.title }
            let next = eligible[id]
            if next?.url != old.page.url || next?.space != old.page.space
                || next?.foregroundWindow != old.page.foregroundWindow || old.mode != mode {
                if let row = row(old) { closed.append(row) }
                open.removeValue(forKey: id)
            }
        }
        for (id, page) in eligible {
            if open[id] != nil { open[id]?.page = page }
            else { open[id] = Open(page: page, mode: mode, start: now, end: now) }
        }
        self.lastTime = now
        self.lastInput = lastInput
        return closed
    }

    public var checkpoint: [Stretch] { open.values.compactMap(row) }

    private func row(_ stretch: Open) -> Stretch? {
        guard stretch.active > 0 || stretch.media > 0 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSxxx"
        return Stretch(id: stretch.id, fileName: activityLogFileName(machine: machine, start: stretch.start, calendar: calendar),
            record: ActivityRecord(start: formatter.string(from: stretch.start), end: formatter.string(from: stretch.end),
                machine: machine, space: stretch.page.space, url: stretch.page.url.absoluteString,
                title: stretch.page.title, active: stretch.active, media: stretch.media,
                background: stretch.page.foregroundWindow == nil, mode: stretch.mode))
    }
}
