// Licensed under GPL-3.0. See LICENSE.
// swiftc Packages/NookWeb/Sources/NookWeb/Activity/*.swift Packages/NookWeb/Checks/FocusCheck.swift -o /tmp/focus-check && /tmp/focus-check

import Foundation

@main struct FocusCheck {
    static func main() throws {
        func url(_ raw: String) -> URL { normalizedActivityURL(URL(string: raw)!) ?? URL(string: raw)! }

        // Internal pages.
        for raw in ["nook://settings", "about:blank", "file:///Users/a/report.html", "http://localhost:3000/x",
                    "http://127.0.0.1:8080", "https://app.localhost/", "http://[::1]:5000/"] {
            precondition(isInternalActivityURL(URL(string: raw)!), raw)
        }
        precondition(!isInternalActivityURL(url("https://example.com/")))
        precondition(!isInternalActivityURL(url("https://localhost.example.com/")))

        // Rules: subdomains, path segments, most specific wins.
        let rules = ActivityRules(rules: [
            ActivityRule(host: "google.com", includeSubdomains: true, scope: .either),
            ActivityRule(host: "docs.google.com", includeSubdomains: false, scope: .work, kind: .building),
            ActivityRule(host: "docs.google.com", includeSubdomains: false, pathPrefix: "/forms", scope: .personal, kind: .admin),
            ActivityRule(host: "github.com", includeSubdomains: false, pathPrefix: "/me/", scope: .personal),
            ActivityRule(host: "github.com", includeSubdomains: false, scope: .work, kind: .building),
        ])
        precondition(rules.match(url("https://mail.google.com/a"))?.scope == .either)
        precondition(rules.match(url("https://google.com"))?.scope == .either)
        precondition(rules.match(url("https://notgoogle.com")) == nil)
        precondition(rules.match(url("https://docs.google.com/document/1"))?.kind == .building)
        precondition(rules.match(url("https://docs.google.com/forms/x"))?.scope == .personal)
        precondition(rules.match(url("https://docs.google.com/forms"))?.scope == .personal)
        precondition(rules.match(url("https://docs.google.com/formsx"))?.scope == .work)
        precondition(rules.match(url("https://github.com/me"))?.scope == .personal)
        precondition(rules.match(url("https://github.com/me/repo"))?.scope == .personal)
        precondition(rules.match(url("https://github.com/meow"))?.scope == .work)
        precondition(rules.match(url("https://gist.github.com/x")) == nil)
        precondition(ActivityRules.seed.match(url("https://m.youtube.com/watch?v=1"))?.scope == .either)
        precondition(ActivityRules.seed.match(url("https://console.aws.amazon.com/"))?.scope == .work)
        precondition(ActivityRules.seed.match(url("https://amazon.com/")) == nil)

        // Hand-edited rules: defaults, and a bad rule skipped without losing the rest.
        let edited = try JSONDecoder().decode(ActivityRules.self, from: Data("""
        {"rules":[{"host":"a.com","scope":"work"},{"host":"b.com","scope":"nonsense"},{"host":"c.com","scope":"personal","kind":"social","includeSubdomains":true,"pathPrefix":null}]}
        """.utf8))
        precondition(edited.rules.map(\.host) == ["a.com", "c.com"])
        precondition(edited.rules[0].includeSubdomains == false && edited.rules[0].kind == nil)
        let rulesRoundTrip = try JSONDecoder().decode(ActivityRules.self, from: JSONEncoder().encode(ActivityRules.seed))
        precondition(rulesRoundTrip == ActivityRules.seed)

        // Label resolution and the JEV privacy rule.
        let stamp = "2026-11-10T09:00:00.000+05:30"
        let docs = url("https://docs.google.com/document/1")
        let mail = url("https://mail.google.com/mail/u/0")
        let news = url("https://news.example.com/story")
        var remembered: [String: PageLabel] = [
            mail.absoluteString: PageLabel(scope: .work, kind: .communication, source: .jev, unsure: false, at: stamp),
            news.absoluteString: PageLabel(scope: .personal, kind: .reading, source: .manual, unsure: false, at: stamp),
        ]
        precondition(resolveActivityLabel(docs, rules: rules, remembered: remembered)
            == ResolvedLabel(scope: .work, kind: .building, source: .rule, unsure: false))
        precondition(!activityLabelNeedsJEV(docs, rules: rules, remembered: [:]))
        precondition(resolveActivityLabel(mail, rules: rules, remembered: remembered)?.source == .jev)
        precondition(resolveActivityLabel(mail, rules: rules, remembered: remembered)?.kind == .communication)
        precondition(resolveActivityLabel(url("https://maps.google.com/"), rules: rules, remembered: remembered)
            == ResolvedLabel(scope: .either, kind: nil, source: .rule, unsure: false))
        precondition(activityLabelNeedsJEV(url("https://maps.google.com/"), rules: rules, remembered: remembered))
        precondition(!activityLabelNeedsJEV(mail, rules: rules, remembered: remembered))
        precondition(resolveActivityLabel(news, rules: rules, remembered: remembered)?.source == .manual)
        precondition(activityLabelNeedsJEV(url("https://unknown.example/"), rules: rules, remembered: remembered))
        precondition(!activityLabelNeedsJEV(URL(string: "http://localhost:3000/")!, rules: rules, remembered: [:]))
        precondition(resolveActivityLabel(url("https://unknown.example/"), rules: rules, remembered: remembered) == nil)
        // Manual beats a fixed rule.
        remembered[docs.absoluteString] = PageLabel(scope: .personal, kind: .reading, source: .manual, unsure: false, at: stamp)
        precondition(resolveActivityLabel(docs, rules: rules, remembered: remembered)?.scope == .personal)
        // An either rule's kind wins over JEV's kind; JEV's scope fills in.
        let yt = url("https://youtube.com/watch?v=1")
        let kinded = ActivityRules(rules: [ActivityRule(host: "youtube.com", scope: .either, kind: .entertainment)])
        let ytLabel = [yt.absoluteString: PageLabel(scope: .work, kind: .reading, source: .jev, unsure: false, at: stamp)]
        precondition(resolveActivityLabel(yt, rules: kinded, remembered: ytLabel)
            == ResolvedLabel(scope: .work, kind: .entertainment, source: .jev, unsure: false))

        // labels.json: missing source reads as manual, broken entries are skipped.
        let labels = try PageLabel.decodeAll(Data("""
        {"https://a.com":{"scope":"work"},"https://b.com":{"scope":"sideways"},"https://c.com":{"scope":"personal","kind":"social","source":"jev","unsure":true,"at":"x"}}
        """.utf8))
        precondition(labels.count == 2 && labels["https://a.com"]?.source == .manual && labels["https://c.com"]?.unsure == true)

        // Modes and the fit decision.
        let modes = FocusModes.seed
        precondition(modes.mode(named: "focus")?.name == "Focus" && modes.mode(named: " PREP ")?.name == "Prep")
        precondition(modes.mode(named: "off") == nil)
        let focus = modes.mode(named: "Focus")!, work = modes.mode(named: "Work")!, prep = modes.mode(named: "Prep")!
        func label(_ scope: PageScope, _ kind: PageKind?, unsure: Bool = false) -> ResolvedLabel {
            ResolvedLabel(scope: scope, kind: kind, source: .jev, unsure: unsure)
        }
        let page = url("https://example.com/a")
        precondition(focusVerdict(for: page, label: label(.work, .building), mode: focus) == .allowed)
        precondition(focusVerdict(for: page, label: label(.work, nil), mode: focus) == .allowed)
        precondition(focusVerdict(for: page, label: label(.work, .social), mode: focus) == .covered)
        precondition(focusVerdict(for: page, label: label(.personal, .reading), mode: focus) == .covered)
        precondition(focusVerdict(for: page, label: label(.personal, .reading, unsure: true), mode: focus) == .allowed)
        precondition(focusVerdict(for: page, label: nil, mode: focus) == .allowed)
        precondition(focusVerdict(for: page, label: label(.either, .reading), mode: focus) == .allowed)
        precondition(focusVerdict(for: page, label: label(.either, .entertainment), mode: focus) == .covered)
        precondition(focusVerdict(for: page, label: label(.work, .social), mode: work) == .allowed)
        precondition(focusVerdict(for: page, label: label(.personal, .reading), mode: prep) == .allowed)
        precondition(focusVerdict(for: page, label: label(.personal, .entertainment), mode: prep) == .covered)
        var strict = focus
        strict.offMode = .block
        strict.blockHosts = ["reddit.com"]
        precondition(focusVerdict(for: page, label: label(.personal, .social), mode: strict) == .blocked)
        precondition(focusVerdict(for: url("https://old.reddit.com/r/x"), label: nil, mode: strict) == .blocked)
        precondition(focusVerdict(for: url("https://reddit.com/"), label: label(.work, .building), mode: strict) == .blocked)
        precondition(focusVerdict(for: url("https://notreddit.com/"), label: nil, mode: strict) == .allowed)
        precondition(focusVerdict(for: URL(string: "nook://settings")!, label: nil, mode: strict) == .allowed)

        // modes.json: defaults, unknown offMode falls back to friction, duplicates and bad modes dropped.
        let parsed = try JSONDecoder().decode(FocusModes.self, from: Data("""
        {"modes":[{"name":"Calm","offMode":"loud","forceTweaks":["youTubeHideShorts"]},{"name":"calm","offMode":"block"},{"description":"no name"},{"name":"Hard","allowScopes":["work"],"offMode":"block","blockHosts":["x.com"]}]}
        """.utf8))
        precondition(parsed.modes.map(\.name) == ["Calm", "Hard"])
        precondition(parsed.modes[0].offMode == .friction && parsed.modes[0].allowScopes.isEmpty && parsed.modes[0].forceTweaks == ["youTubeHideShorts"])
        precondition(parsed.modes[1].offMode == .block && parsed.modes[1].blockHosts == ["x.com"])
        let modesRoundTrip = try JSONDecoder().decode(FocusModes.self, from: JSONEncoder().encode(FocusModes.seed))
        precondition(modesRoundTrip == FocusModes.seed)

        // Files: seeding never overwrites, broken files read as empty, JEV merge keeps manual entries.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ActivityFiles(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"rules\":[]}".utf8).write(to: files.rulesURL)
        files.seed()
        precondition(files.loadRules().rules.isEmpty)
        precondition(files.loadModes() == FocusModes.seed)
        try FileManager.default.removeItem(at: files.rulesURL)
        files.seed()
        precondition(files.loadRules() == ActivityRules.seed)
        precondition(files.loadLabels().isEmpty)
        try Data("{\"https://m.com\":{\"scope\":\"personal\",\"source\":\"manual\"},\"note\":\"keep me\"}".utf8).write(to: files.labelsURL)
        let merged = try files.mergeJEVLabels([
            "https://m.com": PageLabel(scope: .work, kind: nil, source: .jev, unsure: false, at: stamp),
            "https://j.com": PageLabel(scope: .work, kind: .reading, source: .jev, unsure: true, at: stamp),
        ])
        precondition(merged["https://m.com"]?.scope == .personal && merged["https://j.com"]?.kind == .reading)
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: files.labelsURL)) as! [String: Any]
        precondition(raw["note"] as? String == "keep me")
        precondition(files.loadLabels()["https://j.com"] == PageLabel(scope: .work, kind: .reading, source: .jev, unsure: true, at: stamp))
        try Data("{not json".utf8).write(to: files.labelsURL)
        precondition(files.loadLabels().isEmpty)
        do { try files.mergeJEVLabels(["https://k.com": PageLabel(scope: .work, kind: nil, source: .jev, unsure: false, at: stamp)]); preconditionFailure() } catch {}
        let untouched = try String(contentsOf: files.labelsURL, encoding: .utf8)
        precondition(untouched == "{not json")

        // Overrides append per machine and day, and read back from every machine.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 19800)!
        let day = parseActivityTimestamp(stamp)!
        precondition(activityTimestamp(day).hasPrefix("2026-11-10T"))
        precondition(parseActivityTimestamp("2026-11-10T09:00:00+05:30") == day)
        try files.appendOverride(FocusOverride(at: stamp, mode: "Focus", url: "https://x.com/", title: "X", reason: "reply"), machine: "Air", date: day, calendar: calendar)
        try files.appendOverride(FocusOverride(at: stamp, mode: "Focus", url: "https://y.com/", title: "Y \"q\"", reason: "look"), machine: "Air", date: day, calendar: calendar)
        try files.appendOverride(FocusOverride(at: stamp, mode: "Prep", url: "https://z.com/", title: "Z", reason: "n"), machine: "Pro", date: day, calendar: calendar)
        try Data("garbage\n".utf8).write(to: files.overridesDirectory.appendingPathComponent("Old-2026-11-09.jsonl"))
        precondition(FileManager.default.fileExists(atPath: files.overridesDirectory.appendingPathComponent("Air-2026-11-10.jsonl").path))
        let overrides = files.loadOverrides()
        precondition(overrides.count == 3 && overrides.contains { $0.title == "Y \"q\"" } && overrides.contains { $0.mode == "Prep" })

        // JEV request carries only URL and title; responses parse defensively.
        let body = try JSONSerialization.jsonObject(with: ActivityJEV.requestBody(url: "https://a.com/x", title: "A")) as! [String: Any]
        let input = (body["input"] as! [[String: Any]])[0]["content"] as! [[String: Any]]
        precondition((input[0]["data"] as! [String: String]) == ["url": "https://a.com/x", "title": "A"])
        let questions = body["questions"] as! [[String: Any]]
        precondition(questions.map { $0["name"] as! String } == ["profile", "kind"])
        precondition((questions[1]["choices"] as! [[String: String]]).map { $0["value"]! } == PageKind.allCases.map(\.rawValue))
        func answer(_ json: String) -> PageLabel? { ActivityJEV.label(from: Data(json.utf8), at: stamp) }
        precondition(answer("""
        {"answers":[{"type":"choice","name":"scope","choice":"work","confidence":0.9},{"type":"choice","name":"kind","choice":"reading","confidence":0.8}],"model":"m"}
        """) == PageLabel(profiles: ["work"], kind: .reading, source: .jev, at: stamp, confidence: 0.8))
        precondition(answer("""
        {"answers":[{"type":"choice","name":"scope","choice":"personal","confidence":0.55},{"type":"choice","name":"kind","choice":"social","confidence":0.9}]}
        """)?.unsure == true)
        precondition(answer("""
        {"answers":[{"type":"choice","name":"scope","choice":"work","confidence":0.9},{"type":"choice","name":"kind","choice":"social","confidence":0.3}]}
        """)?.unsure == true)
        precondition(answer("""
        {"answers":[{"type":"choice","name":"scope","choice":"work","confidence":0.9},{"type":"refusal","name":"kind"}]}
        """) == PageLabel(profiles: ["work"], source: .jev, at: stamp, confidence: 0.9))
        precondition(answer("""
        {"answers":[{"type":"refusal","name":"scope"},{"type":"choice","name":"kind","choice":"social","confidence":0.9}]}
        """) == nil)
        precondition(answer("""
        {"answers":[{"type":"choice","name":"kind","choice":"social","confidence":0.9},{"type":"choice","name":"scope","choice":"personal","confidence":0.9}]}
        """)?.kind == .social)
        precondition(answer("{\"error\":{\"message\":\"bad key\"}}") == nil)
        precondition(answer("not json") == nil)
        precondition(answer("{\"answers\":[{\"type\":\"choice\",\"name\":\"scope\",\"choice\":\"either\"}]}") == nil)

        print("FocusCheck passed")
    }
}
