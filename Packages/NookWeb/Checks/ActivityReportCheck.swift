// Licensed under GPL-3.0. See LICENSE.
// swiftc Packages/NookWeb/Sources/NookWeb/Activity/*.swift Packages/NookWeb/Checks/ActivityReportCheck.swift -o /tmp/report-check && /tmp/report-check

import Foundation

@main struct ActivityReportCheck {
    static func main() throws {
        // Days and file names.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let noon = ISO8601DateFormatter().date(from: "2026-11-10T12:00:00Z")!
        precondition(activityReportDays(endingAt: noon, count: 3, calendar: utc) == ["2026-11-08", "2026-11-09", "2026-11-10"])
        precondition(activityReportDays(endingAt: noon, count: 1, calendar: utc) == ["2026-11-10"])
        let leap = ISO8601DateFormatter().date(from: "2024-03-01T08:00:00Z")!
        precondition(activityReportDays(endingAt: leap, count: 2, calendar: utc) == ["2024-02-29", "2024-03-01"])
        precondition(activityFileDay("Sais-MacBook-Pro-2026-11-10.jsonl") == "2026-11-10")
        precondition(activityFileDay("Mac-2026-11-10.json") == nil)
        precondition(activityFileDay("Mac-2026-11-1.jsonl") == nil)
        precondition(activityFileDay("checkpoint.jsonl") == nil)

        // Durations.
        precondition(activityDuration(0) == "0 s")
        precondition(activityDuration(59.4) == "59 s")
        precondition(activityDuration(60) == "1 m")
        precondition(activityDuration(3599) == "59 m")
        precondition(activityDuration(3600) == "1 h")
        precondition(activityDuration(3720) == "1 h 2 m")

        // Aggregation.
        let rules = ActivityRules(rules: [
            ActivityRule(host: "aws.amazon.com", scope: .work, kind: .building),
            ActivityRule(host: "x.com", scope: .personal, kind: .social),
            ActivityRule(host: "youtube.com", scope: .either),
        ])
        let remembered = [
            "https://youtube.com/watch?v=1": PageLabel(scope: .personal, kind: .entertainment, source: .jev, unsure: false, at: "t"),
            "https://example.org/b": PageLabel(scope: .work, kind: .reading, source: .jev, unsure: true, at: "t"),
            // A JEV answer for a page a fixed rule decides is ignored.
            "https://x.com/home": PageLabel(scope: .work, kind: .reading, source: .jev, unsure: false, at: "t"),
        ]
        func row(_ url: String, _ active: Double, media: Double = 0, background: Bool = false, mode: String? = nil,
                 machine: String = "A", day: String = "2026-11-10", end: String = "10:10", title: String = "") -> ActivityRecord {
            ActivityRecord(start: "\(day)T10:00:00.000+05:30", end: "\(day)T\(end):00.000+05:30", machine: machine, space: "Home",
                           url: url, title: title, active: active, media: media, background: background, mode: mode)
        }
        let records = [
            row("https://aws.amazon.com/console", 600, mode: "Focus", title: "AWS Console"),
            row("https://x.com/home", 300, machine: "B", title: "Home / X"),
            row("https://youtube.com/watch?v=1", 120, media: 120, title: "A talk"),
            row("https://youtube.com/watch?v=1", 0, media: 900, background: true),
            row("https://example.com/a", 60, title: "<script>alert('x')</script> & co"),
            row("https://example.org/b", 30, title: "Paper"),
            row("http://localhost:3000", 45, title: "Dev"),
            row("https://old.example.com/", 9999, day: "2026-11-07"),
            row("https://aws.amazon.com/console/?utm_source=a", 100, mode: "Focus", end: "11:00", title: "AWS Console new"),
            row("https://www.example.com/c", 10),
        ]
        let overrides = [
            FocusOverride(at: "2026-11-10T10:05:00.000+05:30", mode: "Focus", url: "https://x.com/home", title: "", reason: "dm"),
            FocusOverride(at: "2026-11-10T10:06:00.000+05:30", mode: "Focus", url: "https://x.com/b", title: "", reason: "dm"),
            FocusOverride(at: "2026-11-09T10:06:00.000+05:30", mode: "Prep", url: "https://x.com/c", title: "", reason: "dm"),
            FocusOverride(at: "2026-11-01T10:06:00.000+05:30", mode: "Focus", url: "https://x.com/d", title: "", reason: "old"),
        ]
        let days = ["2026-11-09", "2026-11-10"]
        let report = ActivityReport.make(records: records, overrides: overrides, days: days, rules: rules,
                                         remembered: remembered, generatedAt: "now")
        func shares(_ list: [ActivityReport.Share]) -> [String: Double] {
            Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0.seconds) })
        }
        precondition(report.from == "2026-11-09" && report.to == "2026-11-10")
        precondition(report.total == 1265, "\(report.total)")
        precondition(report.backgroundMedia == 900)
        precondition(shares(report.scopes) == ["work": 730, "personal": 420, "unlabelled": 70, "internal": 45], "\(report.scopes)")
        precondition(report.scopes.map(\.name) == ["work", "personal", "unlabelled", "internal"])
        precondition(shares(report.kinds) == ["building": 700, "social": 300, "entertainment": 120, "reading": 30,
                                              "unlabelled": 70, "internal": 45], "\(report.kinds)")
        precondition(report.modes == [
            ActivityReport.ModeTime(name: "Focus", seconds: 700, overrides: 2, active: 700),
            ActivityReport.ModeTime(name: "Prep", seconds: 0, overrides: 1),
        ], "\(report.modes)")
        precondition(report.outsideModes == 565)
        precondition(report.overrides == 3)
        precondition(report.sites.map(\.name) == ["aws.amazon.com", "x.com", "youtube.com", "example.com", "localhost", "example.org"],
                     "\(report.sites)")
        precondition(shares(report.sites)["example.com"] == 70)
        precondition(report.pages.first?.url == "https://aws.amazon.com/console")
        precondition(report.pages.first?.title == "AWS Console new")
        precondition(report.pages.first?.seconds == 700)
        precondition(report.pages.first?.source == "rule")
        precondition(report.pages.first { $0.url == "https://x.com/home" }?.scope == "personal")
        precondition(report.pages.allSatisfy { $0.seconds > 0 })
        precondition(report.media == [ActivityReport.Media(url: "https://youtube.com/watch?v=1", title: "A talk", foreground: 120, background: 900)])
        precondition(report.unlabelled.map(\.url) == ["https://example.com/a", "https://example.org/b", "https://www.example.com/c"],
                     "\(report.unlabelled.map(\.url))")
        precondition(report.unlabelled[1].unsure && report.unlabelled[1].scope == "work")
        precondition(shares(report.machines) == ["A": 965, "B": 300])

        // One machine, no split; caps on lists.
        let single = ActivityReport.make(records: (0..<40).map { row("https://site\($0).example/", Double($0 + 1)) },
                                         overrides: [], days: ["2026-11-10"], rules: rules, remembered: [:], generatedAt: "now")
        precondition(single.machines.isEmpty)
        precondition(single.sites.count == ActivityReport.topSites && single.sites.first?.name == "site39.example")
        precondition(single.pages.count == ActivityReport.topPages)
        precondition(single.unlabelled.count == 40)

        // JSON keeps the same numbers.
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(ActivityReport.self, from: data)
        precondition(decoded == report)

        // HTML: escaped, self-contained, sections only when they have something.
        let html = report.html()
        precondition(!html.contains("<script>"))
        precondition(html.contains("&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt; &amp; co"))
        for remote in ["src=", "<link", "@import", "url(", "<script"] { precondition(!html.contains(remote), remote) }
        precondition(html.contains("<h2>Machines</h2>"))
        precondition(html.contains("<h2>Unsure or unlabelled</h2>"))
        precondition(html.contains("unsure: work, reading"))
        precondition(html.contains("21 m") && html.contains("15 m"))
        precondition(activityHTMLEscape("\"a\" <b> & 'c'") == "&quot;a&quot; &lt;b&gt; &amp; &#39;c&#39;")
        precondition(!single.html().contains("<h2>Machines</h2>"))
        let empty = ActivityReport.make(records: [], overrides: [], days: ["2026-11-10"], rules: rules, remembered: [:], generatedAt: "now")
        precondition(empty.html().contains("Nothing was recorded"))
        precondition(empty.html().contains("Tuesday 10 November 2026"))

        // Pages to label: normalised, local pages skipped, latest non-empty title.
        let toLabel = activityPagesToLabel(records)
        precondition(toLabel.map(\.url.absoluteString) == ["https://aws.amazon.com/console", "https://x.com/home",
            "https://youtube.com/watch?v=1", "https://example.com/a", "https://example.org/b", "https://old.example.com/",
            "https://www.example.com/c"], "\(toLabel.map(\.url.absoluteString))")
        precondition(toLabel[0].title == "AWS Console new" && toLabel[2].title == "A talk")

        // Files: logs picked by day from every machine, bad lines skipped, report written beside its numbers.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("report-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ActivityFiles(directory: root)
        try FileManager.default.createDirectory(at: files.logDirectory, withIntermediateDirectories: true)
        func lines(_ rows: [ActivityRecord]) throws -> Data {
            Data(try rows.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }.joined(separator: "\n").utf8)
        }
        try lines([records[0], records[1]]).write(to: files.logDirectory.appendingPathComponent("A-2026-11-10.jsonl"))
        try (lines([records[2]]) + Data("\nnot json\n{}\n".utf8)).write(to: files.logDirectory.appendingPathComponent("B-2026-11-09.jsonl"))
        try lines([records[7]]).write(to: files.logDirectory.appendingPathComponent("A-2026-11-07.jsonl"))
        try Data("x".utf8).write(to: files.logDirectory.appendingPathComponent("checkpoint.json"))
        let loaded = files.loadRecords(days: days)
        precondition(loaded.count == 3 && Set(loaded.map(\.url)).count == 3, "\(loaded)")
        let written = try files.writeReport(report)
        precondition(written.lastPathComponent == "report-2026-11-09-to-2026-11-10.html")
        let numbers = try Data(contentsOf: written.deletingPathExtension().appendingPathExtension("json"))
        let reread = try JSONDecoder().decode(ActivityReport.self, from: numbers)
        let page = try String(contentsOf: written, encoding: .utf8)
        precondition(reread == report && page == report.html())

        print("ActivityReportCheck passed")
    }
}
