// Licensed under GPL-3.0. See LICENSE.
// swiftc Packages/NookWeb/Sources/NookWeb/Activity/*.swift Packages/NookWeb/Checks/AttentionCheck.swift -o /tmp/attention-check && /tmp/attention-check

import Foundation

@main struct AttentionCheck {
    static func main() throws {
        let decoder = JSONDecoder()
        let rules = try decoder.decode(ActivityRules.self, from: Data("""
        {"rules":[{"host":"fixed.test","profiles":["Work","PERSONAL","work"],"kind":"reading"},
          {"host":"judge.test","scope":"either"},{"host":"legacy.test","scope":"work"},
          {"host":"block.test","handling":"block"},{"host":"allow.test","handling":"allow"}]}
        """.utf8))
        precondition(rules.rules[0].profiles == ["work", "personal"])
        precondition(rules.rules[0].source == .you && rules.rules[0].handling == .profile)
        precondition(rules.rules[1].handling == .judge && rules.rules[2].profiles == ["work"])
        let mode = FocusMode(name: "Personal", allowProfiles: ["PERSONAL"])
        func verdict(_ host: String, _ goal: GoalFitDecision? = nil) -> FocusVerdict {
            let url = URL(string: "https://\(host)/")!
            return focusVerdict(for: url, label: resolveActivityLabel(url, rules: rules, remembered: [:]), mode: mode,
                                rule: rules.match(url), goalFit: goal)
        }
        precondition(verdict("fixed.test") == .allowed)
        precondition(verdict("legacy.test") == .covered)
        precondition(verdict("block.test") == .blocked && verdict("allow.test") == .allowed)
        precondition(verdict("judge.test") == .allowed)
        precondition(verdict("judge.test", GoalFitDecision(choice: .off, confidence: 0.9, reason: "Off goal")) == .covered)
        precondition(!activityLabelNeedsJEV(URL(string: "https://fixed.test/")!, rules: rules, remembered: [:]))
        let legacyMode = try decoder.decode(FocusMode.self, from: Data(#"{"name":"Work","allowScopes":["work"]}"#.utf8))
        precondition(legacyMode.allowProfiles == ["work"] && legacyMode.askGoal && legacyMode.filterFeeds)
        let label = try decoder.decode(PageLabel.self, from: Data(#"{"profiles":["WORK","Personal"],"confidence":0.8,"reason":"Both"}"#.utf8))
        precondition(label.profiles == ["work", "personal"] && label.confidence == 0.8 && label.reason == "Both")
        let preferences = try decoder.decode(AttentionPreferences.self, from: Data(#"{"judge":{"confidenceFloor":2},"sites":{"x.com":{"extra":"Less noise"},"bad":false}}"#.utf8))
        precondition(preferences.judge.confidenceFloor == 1 && preferences.sites.count == 1 && preferences.enabled)
        let judge = OpenAIDecisionsJudge()
        func goal(_ choice: String, _ confidence: String) -> GoalFitDecision? {
            judge.goalDecision(from: Data("{\"answers\":[{\"type\":\"choice\",\"name\":\"goalFit\",\"choice\":\"\(choice)\",\"confidence\":\(confidence),\"reason\":\"Reason\"}]}".utf8))
        }
        precondition(goal("off", "0.59")?.choice == .fits)
        precondition(goal("off", "0.6")?.choice == .off && goal("fits", "1")?.reason == "Reason")
        precondition(goal("other", "0.9") == nil && goal("off", "null") == nil && goal("off", "2") == nil)
        precondition(judge.goalDecision(from: Data(#"{"answers":[{"type":"refusal"}]}"#.utf8)) == nil)
        let body = try JSONSerialization.jsonObject(with: judge.goalBody(url: "https://judge.test", title: "Title", goal: "Ship", mode: "Focus")) as! [String: Any]
        precondition((body["questions"] as? [[String: Any]])?.count == 1)
        let posts = (0..<25).map { FeedPost(id: "\($0)", author: "author", text: "Post") }
        let feed = try JSONSerialization.jsonObject(with: judge.feedBody(posts: posts, preferences: "No spam")) as! [String: Any]
        precondition((feed["questions"] as? [[String: Any]])?.count == 20)
        let decisions = judge.feedDecisions(from: Data(#"{"answers":[{"type":"choice","name":"post_1","choice":"hide","confidence":0.9,"reason":"Spam"},{"type":"choice","name":"post_0","choice":"hide","confidence":0.2}]}"#.utf8), posts: posts)
        precondition(decisions.count == 20 && decisions[0].choice == .show && decisions[1].choice == .hide && decisions[2].choice == .show)
        precondition(FeedSitePreferences(mutedAccounts: ["@AUTHOR"]).hides(posts[0]))
        precondition(FeedSitePreferences(keywords: ["post"]).hides(posts[0]))
        let fixedBatch = FeedPostBatch(posts: [posts[0], FeedPost(id: "keep", author: "other", text: "Keep")],
                                       preferences: .init(mutedAccounts: ["author"]))
        precondition(fixedBatch.posts.map(\.id) == ["keep"] && fixedBatch.fixed.map(\.id) == ["0"])
        let fixedBody = String(decoding: try judge.feedBody(posts: fixedBatch.posts, preferences: ""), as: UTF8.self)
        precondition(!fixedBody.contains("\"id\":\"0\"") && fixedBody.contains("Keep"))
        let custom = try judge.labelBody(url: "https://fixed.test", title: "Title", profiles: ["Research", "Personal"])
        precondition(String(decoding: custom, as: UTF8.self).contains("research"))
        let customLabel = judge.pageLabel(from: Data(#"{"answers":[{"type":"choice","name":"profile","choice":"research","confidence":0.9,"reason":"Research paper"}]}"#.utf8), at: "now", profiles: ["research"])
        precondition(customLabel?.profiles == ["research"] && customLabel?.confidence == 0.9 && customLabel?.reason == "Research paper")

        // TypeSafe Jev: questions and answers keyed by id, criteria maps, no reasons in answers.
        let jevConfig = try decoder.decode(ActivityJudgeConfig.self, from: Data(#"{"provider":"typesafe-jev"}"#.utf8))
        precondition(jevConfig.provider == .typeSafeJev && jevConfig.model == "jev-latest")
        precondition(ActivityJudgeConfig().model == "gpt-6-luna" && ActivityJudgeConfig(provider: .typeSafeJev).model == "jev-latest")
        let jev = jevConfig.provider.makeJudge()
        precondition(jev.endpoint.absoluteString == "https://api.typesafe.ai/v1/systemone")
        let jevGoalBody = try JSONSerialization.jsonObject(with: jev.goalBody(url: "https://judge.test", title: "Title", goal: "Ship", mode: "Focus", examples: [], config: jevConfig)) as! [String: Any]
        let jevGoalQuestion = (jevGoalBody["questions"] as? [String: Any])?["goalFit"] as? [String: Any]
        precondition(jevGoalBody["model"] as? String == "jev-latest" && (jevGoalBody["state"] as? [String: Any])?["goal"] as? String == "Ship")
        precondition(jevGoalQuestion?["type"] as? String == "choice" && Set(((jevGoalQuestion?["criteria"] as? [String: Any]) ?? [:]).keys) == ["fits", "off"])
        func jevGoal(_ choice: String, _ confidence: String) -> GoalFitDecision? {
            jev.goalDecision(from: Data("{\"model\":\"jev-1.13.0\",\"answers\":{\"goalFit\":{\"type\":\"choice\",\"choice\":\"\(choice)\",\"confidence\":\(confidence),\"probabilities\":{}}}}".utf8), confidenceFloor: 0.6)
        }
        precondition(jevGoal("off", "0.59")?.choice == .fits && jevGoal("off", "0.9")?.choice == .off)
        precondition(jevGoal("off", "0.9")?.reason.isEmpty == false && jevGoal("maybe", "0.9") == nil && jevGoal("off", "1.5") == nil)
        let jevFeed = try JSONSerialization.jsonObject(with: jev.feedBody(posts: posts, preferences: "No spam", goal: nil, examples: [], config: jevConfig)) as! [String: Any]
        precondition((jevFeed["questions"] as? [String: Any])?.count == 20)
        let jevDecisions = jev.feedDecisions(from: Data(#"{"answers":{"post_1":{"type":"choice","choice":"hide","confidence":0.9},"post_0":{"type":"choice","choice":"hide","confidence":0.2},"post_2":{"type":"refusal"}}}"#.utf8), posts: posts, confidenceFloor: 0.6)
        precondition(jevDecisions.count == 20 && jevDecisions[0].choice == .show && jevDecisions[1].choice == .hide && jevDecisions[2].choice == .show)
        let jevLabelBody = String(decoding: try jev.labelBody(url: "https://fixed.test", title: "Title", profiles: ["Research"], config: jevConfig), as: UTF8.self)
        precondition(jevLabelBody.contains("\"research\":null") && jevLabelBody.contains("\"building\""))
        let jevLabel = jev.pageLabel(from: Data(#"{"answers":{"profile":{"type":"choice","choice":"research","confidence":0.5},"kind":{"type":"choice","choice":"reading","confidence":0.9}}}"#.utf8), at: "now", profiles: ["research"], confidenceFloor: 0.6)
        precondition(jevLabel?.profiles == ["research"] && jevLabel?.kind == .reading && jevLabel?.unsure == true && jevLabel?.confidence == 0.5)
        precondition(jev.pageLabel(from: Data(#"{"answers":{"profile":{"type":"choice","choice":"work","confidence":0.9}}}"#.utf8), at: "now", profiles: ["research"], confidenceFloor: 0.6) == nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("attention-check-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ActivityFiles(directory: root)
        files.seed()
        try files.savePreferences(preferences)
        precondition(files.loadPreferences() == preferences)
        let start = "2026-11-10T10:00:00.000+00:00", middle = "2026-11-10T10:30:00.000+00:00", end = "2026-11-10T11:00:00.000+00:00"
        let session = AttentionSession(at: start, event: .start, session: "s", mode: "Focus", goal: "Ship")
        let ended = AttentionSession(at: end, event: .end, session: "s", mode: "Focus", goal: "Ship")
        let writer = ActivityLogWriter(directory: root)
        let date = parseActivityTimestamp(start)!
        writer.writeSession(session, machine: "Check", date: date)
        writer.writeSession(ended, machine: "Check", date: date)
        let event = AttentionEvent(at: middle, session: "s", mode: "Focus", kind: .continue, url: "https://judge.test/", decidedBy: .you, reason: "Needed")
        writer.writeEvent(event, machine: "Check", date: date)
        writer.writeEvent(.init(at: end, session: "s", kind: .wrongAllow, url: "https://wrong.test/", decidedBy: .you), machine: "Check", date: date)
        writer.writeEvent(.init(at: start, kind: .feedHidden, site: "x.com", decidedBy: .judge, count: 4), machine: "Check", date: date)
        writer.writeEvent(.init(at: start, kind: .feedWrong, site: "x.com", decidedBy: .you, count: 2), machine: "Check", date: date)
        writer.writeEvent(.init(at: start, kind: .feedShow, site: "x.com", decidedBy: .you), machine: "Check", date: date)
        let done = DispatchSemaphore(value: 0)
        writer.drain { done.signal() }; done.wait()
        precondition(files.loadSessions() == [session, ended] && files.loadEvents().first == event)
        precondition(files.judgeExamples().count == 2)
        try Data("bad\n{}\n".utf8).write(to: files.eventsDirectory.appendingPathComponent("bad.jsonl"))
        precondition(files.loadEvents().count == 5)
        func row(_ url: String, _ active: Double) -> ActivityRecord {
            ActivityRecord(start: start, end: end, machine: "Check", space: "Work", url: url, title: "Title", active: active,
                           media: 60, background: false, mode: "Focus", session: "s")
        }
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let report = ActivityReport.make(records: [row("https://judge.test/", 600), row("https://wrong.test/", 120)], overrides: [],
            days: ["2026-11-10"], rules: rules, remembered: [:], generatedAt: end, sessions: files.loadSessions(), events: files.loadEvents(), calendar: utc)
        precondition(report.sessions.count == 1 && report.sessions[0].active == 720)
        precondition(report.sessions[0].onGoal == 300 && report.sessions[0].offGoal == 420)
        precondition(report.sessions[0].continued == 1 && report.sessions[0].wrongAllows == 1)
        precondition(report.sessions[0].end == end && report.sessions[0].goal == "Ship")
        precondition(report.modes[0].sessions == 1 && report.modes[0].onGoal == 300)
        precondition(report.buckets.count == 24 && report.buckets.reduce(0) { $0 + $1.active } == 720)
        precondition(report.buckets.reduce(0) { $0 + $1.media } == 120)
        precondition(report.feeds.count == 1 && report.feeds[0].hidden == 4 && report.feeds[0].shown == 1 && report.feeds[0].wrong == 2)
        let daily = ActivityReport.make(records: [row("https://judge.test/", 600)], overrides: [], days: ["2026-11-10", "2026-11-11"],
            rules: rules, remembered: [:], generatedAt: end, calendar: utc)
        precondition(daily.buckets.count == 2 && daily.buckets[0].active == 600)
        let encoded = try JSONEncoder().encode(report)
        let decoded = try decoder.decode(ActivityReport.self, from: encoded)
        precondition(decoded == report)
        let cover = AttentionEvent(at: start, session: "s", kind: .cover, url: "https://judge.test/", decidedBy: .judge)
        let wrongBlock = AttentionEvent(at: middle, session: "s", kind: .wrongBlock, url: "https://judge.test/", decidedBy: .you)
        let covered = ActivityReport.make(records: [row("https://judge.test/", 600)], overrides: [], days: ["2026-11-10"],
            rules: rules, remembered: [:], generatedAt: end, sessions: [session], events: [cover, wrongBlock], calendar: utc)
        precondition(covered.sessions[0].onGoal == 0 && covered.sessions[0].offGoal == 0 && covered.sessions[0].wrongBlocks == 1)
        let switched = AttentionSession(at: end, event: .switch, session: "s", mode: "Focus", goal: "Ship")
        let continued = ActivityReport.make(records: [row("https://judge.test/", 600)], overrides: [], days: ["2026-11-10"],
            rules: rules, remembered: [:], generatedAt: end, sessions: [session, switched], events: [cover, wrongBlock, event], calendar: utc)
        precondition(continued.sessions[0].onGoal == 0 && continued.sessions[0].offGoal == 300 && continued.sessions[0].end == end)
        var spanning = row("https://judge.test/", 600)
        spanning.start = middle; spanning.end = "2026-11-10T11:30:00.000+00:00"
        let hourly = ActivityReport.make(records: [spanning], overrides: [], days: ["2026-11-10"], rules: rules, remembered: [:], generatedAt: end, calendar: utc)
        precondition(hourly.buckets[10].active == 300 && hourly.buckets[11].active == 300)
        precondition(hourly.buckets[10].start == start)
        let legacyReport = try decoder.decode(ActivityReport.self, from: Data(#"{"from":"2026-11-10","modes":[{"name":"Focus","seconds":15,"overrides":1}]}"#.utf8))
        precondition(legacyReport.sessions.isEmpty && legacyReport.feeds.isEmpty && legacyReport.modes[0].active == 15)
        try Data(#"{"note":"keep","rules":["broken",{"host":"keep.test","profiles":["work"]}]}"#.utf8).write(to: files.rulesURL)
        let blocked = try files.blockSite(host: "block.test")
        precondition(blocked.rules.count == 2 && blocked.rules[0].handling == .block && blocked.rules[0].source == .you)
        let rawRules = try JSONSerialization.jsonObject(with: Data(contentsOf: files.rulesURL)) as! [String: Any]
        precondition(rawRules["note"] as? String == "keep" && (rawRules["rules"] as? [Any])?.count == 3)
        for offset in 0..<25 {
            let at = date.addingTimeInterval(7200 + Double(offset))
            try files.appendEvent(.init(at: activityTimestamp(at), kind: .wrongBlock, decidedBy: .you), machine: "Examples", date: at)
        }
        precondition(files.judgeExamples().count == 20 && parseActivityTimestamp(files.judgeExamples()[0].at) == date.addingTimeInterval(7224))
        let store = ActivityStateStore(directory: root)
        let state = try store.update { $0["goal"] = "Ship"; $0["sessionID"] = "s" }
        precondition(state["goal"] as? String == "Ship" && state["sessionID"] as? String == "s")
        print("AttentionCheck passed")
    }
}
