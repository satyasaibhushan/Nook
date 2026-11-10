// Licensed under GPL-3.0. See LICENSE.

import Foundation

/// The day a log or overrides file covers, from its `<machine>-YYYY-MM-DD.jsonl` name.
public func activityFileDay(_ fileName: String) -> String? {
    guard fileName.hasSuffix(".jsonl") else { return nil }
    let day = String(fileName.dropLast(6).suffix(10))
    return isActivityDay(day) ? day : nil
}

/// `count` local days ending with the one `date` falls on, oldest first, as YYYY-MM-DD.
public func activityReportDays(endingAt date: Date, count: Int, calendar: Calendar = .current) -> [String] {
    let today = calendar.startOfDay(for: date)
    return (0..<max(count, 1)).reversed().compactMap { back in
        calendar.date(byAdding: .day, value: -back, to: today).map { day in
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        }
    }
}

private func isActivityDay(_ text: String) -> Bool {
    let chars = Array(text)
    guard chars.count == 10, chars[4] == "-", chars[7] == "-" else { return false }
    return chars.enumerated().allSatisfy { $0.offset == 4 || $0.offset == 7 || $0.element.isASCII && $0.element.isNumber }
}

/// Where time went over some days. Time is active seconds; background media is counted apart
/// and never added to the total. The JSON file holds exactly these numbers.
public struct ActivityReport: Codable, Equatable, Sendable {
    public struct Share: Codable, Equatable, Sendable {
        public var name: String
        public var seconds: Double
    }
    public struct ModeTime: Codable, Equatable, Sendable {
        public var name: String
        public var seconds: Double
        public var overrides: Int
    }
    public struct Page: Codable, Equatable, Sendable {
        public var url: String
        public var title: String
        public var seconds: Double
        public var scope: String
        public var kind: String?
        public var source: String?
        public var unsure: Bool
    }
    public struct Media: Codable, Equatable, Sendable {
        public var url: String
        public var title: String
        public var foreground: Double
        public var background: Double
    }

    public var from: String
    public var to: String
    public var generatedAt: String
    public var total: Double
    public var backgroundMedia: Double
    /// work, personal, either, unlabelled and internal; empty buckets are left out.
    public var scopes: [Share]
    /// The six kinds, plus unlabelled and internal.
    public var kinds: [Share]
    public var modes: [ModeTime]
    public var outsideModes: Double
    public var overrides: Int
    public var sites: [Share]
    public var pages: [Page]
    public var media: [Media]
    /// Pages with no label or an unsure one, so they can be labelled by hand.
    public var unlabelled: [Page]
    /// Active time per machine, only when more than one machine logged in the range.
    public var machines: [Share]

    public static let topSites = 15
    public static let topPages = 20

    public static func make(records: [ActivityRecord], overrides: [FocusOverride], days: [String],
                            rules: ActivityRules, remembered: [String: PageLabel], generatedAt: String) -> ActivityReport {
        let range = Set(days)
        let rows = records.filter { range.contains(String($0.start.prefix(10))) }

        struct Entry {
            var url: String
            var parsed: URL?
            var title = ""
            var titleEnd = ""
            var active = 0.0
            var foreground = 0.0
            var background = 0.0
        }
        var entries: [String: Entry] = [:]
        var order: [String] = []
        var scopes: [String: Double] = [:], kinds: [String: Double] = [:], sites: [String: Double] = [:]
        var modes: [String: Double] = [:], machines: [String: Double] = [:]
        var total = 0.0, backgroundMedia = 0.0, outsideModes = 0.0
        var labels: [String: ResolvedLabel?] = [:]

        func label(_ key: String, _ url: URL?) -> ResolvedLabel? {
            if let cached = labels[key] { return cached }
            let found = url.flatMap { isInternalActivityURL($0) ? nil : resolveActivityLabel($0, rules: rules, remembered: remembered) }
            labels[key] = found
            return found
        }

        for row in rows {
            let parsed = URL(string: row.url).flatMap(normalizedActivityURL)
            let key = parsed?.absoluteString ?? row.url
            if entries[key] == nil { entries[key] = Entry(url: key, parsed: parsed); order.append(key) }
            var entry = entries[key]!
            if !row.title.isEmpty, row.end >= entry.titleEnd { entry.title = row.title; entry.titleEnd = row.end }
            entry.active += row.active
            if row.background { entry.background += row.media } else { entry.foreground += row.media }
            entries[key] = entry

            total += row.active
            if row.background { backgroundMedia += row.media }
            machines[row.machine, default: 0] += row.active
            if let mode = row.mode { modes[mode, default: 0] += row.active } else { outsideModes += row.active }
            guard row.active > 0 else { continue }
            let isLocal = parsed.map(isInternalActivityURL) ?? true
            let found = label(key, parsed)
            scopes[isLocal ? "internal" : found?.scope.rawValue ?? "unlabelled", default: 0] += row.active
            kinds[isLocal ? "internal" : found?.kind?.rawValue ?? "unlabelled", default: 0] += row.active
            sites[Self.site(parsed), default: 0] += row.active
        }

        let inRange = overrides.filter { range.contains(String($0.at.prefix(10))) }
        var overridesByMode: [String: Int] = [:]
        for line in inRange { overridesByMode[line.mode, default: 0] += 1 }

        func page(_ entry: Entry) -> Page {
            let isLocal = entry.parsed.map(isInternalActivityURL) ?? true
            let found = label(entry.url, entry.parsed)
            return Page(url: entry.url, title: entry.title, seconds: Self.round(entry.active),
                        scope: isLocal ? "internal" : found?.scope.rawValue ?? "unlabelled",
                        kind: found?.kind?.rawValue, source: found?.source.rawValue, unsure: found?.unsure ?? false)
        }
        let all = order.compactMap { entries[$0] }

        return ActivityReport(
            from: days.first ?? "", to: days.last ?? "", generatedAt: generatedAt,
            total: Self.round(total), backgroundMedia: Self.round(backgroundMedia),
            scopes: Self.shares(scopes), kinds: Self.shares(kinds),
            modes: Set(modes.keys).union(overridesByMode.keys)
                .map { ModeTime(name: $0, seconds: Self.round(modes[$0] ?? 0), overrides: overridesByMode[$0] ?? 0) }
                .sorted { ($0.seconds, $1.name) > ($1.seconds, $0.name) },
            outsideModes: Self.round(outsideModes), overrides: inRange.count,
            sites: Array(Self.shares(sites).prefix(topSites)),
            pages: Array(all.filter { $0.active > 0 }.sorted { ($0.active, $1.url) > ($1.active, $0.url) }
                .prefix(topPages).map(page)),
            media: all.filter { $0.foreground + $0.background > 0 }
                .sorted { ($0.foreground + $0.background, $1.url) > ($1.foreground + $1.background, $0.url) }
                .map { Media(url: $0.url, title: $0.title, foreground: Self.round($0.foreground), background: Self.round($0.background)) },
            unlabelled: all.map(page).filter { $0.scope == "unlabelled" || $0.unsure }
                .sorted { ($0.seconds, $1.url) > ($1.seconds, $0.url) },
            machines: machines.count > 1 ? Self.shares(machines, keepEmpty: true) : [])
    }

    private static func site(_ url: URL?) -> String {
        guard let url, url.scheme != "file", let host = url.host, !host.isEmpty else { return "Files" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func shares(_ values: [String: Double], keepEmpty: Bool = false) -> [Share] {
        values.filter { keepEmpty || $0.value > 0 }
            .map { Share(name: $0.key, seconds: round($0.value)) }
            .sorted { ($0.seconds, $1.name) > ($1.seconds, $0.name) }
    }

    private static func round(_ seconds: Double) -> Double { seconds.rounded() }
}

/// Pages in `records` that labels could apply to: normalised, local pages left out, each once,
/// with the title from its latest row.
public func activityPagesToLabel(_ records: [ActivityRecord]) -> [(url: URL, title: String)] {
    var found: [String: (url: URL, title: String, end: String)] = [:]
    var order: [String] = []
    for row in records {
        guard let url = URL(string: row.url).flatMap(normalizedActivityURL), !isInternalActivityURL(url) else { continue }
        let key = url.absoluteString
        guard let seen = found[key] else {
            found[key] = (url, row.title, row.end)
            order.append(key)
            continue
        }
        if !row.title.isEmpty, seen.title.isEmpty || row.end >= seen.end { found[key] = (url, row.title, row.end) }
    }
    return order.compactMap { found[$0].map { ($0.url, $0.title) } }
}

extension ActivityFiles {
    /// Log rows from every machine for the given days. Files are picked by the day in their
    /// name; lines that do not parse are skipped.
    public func loadRecords(days: [String]) -> [ActivityRecord] {
        let wanted = Set(days)
        let decoder = JSONDecoder()
        return jsonlFiles(in: logDirectory)
            .filter { activityFileDay($0.lastPathComponent).map(wanted.contains) ?? false }
            .flatMap { url -> [ActivityRecord] in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
                return text.split(separator: "\n").compactMap { try? decoder.decode(ActivityRecord.self, from: Data($0.utf8)) }
            }
    }

    /// Writes `report-<from>-to-<to>.html` and a `.json` with the same numbers; returns the page.
    @discardableResult
    public func writeReport(_ report: ActivityReport) throws -> URL {
        try FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)
        let base = reportsDirectory.appendingPathComponent("report-\(report.from)-to-\(report.to)")
        let page = base.appendingPathExtension("html")
        try Self.encoder.encode(report).write(to: base.appendingPathExtension("json"), options: .atomic)
        try Data(report.html().utf8).write(to: page, options: .atomic)
        return page
    }
}
