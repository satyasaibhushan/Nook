// Licensed under GPL-3.0. See LICENSE.
// swiftc Packages/NookWeb/Sources/NookWeb/Activity/*.swift Packages/NookTweaks/Sources/NookTweaks/FeedFilterHosts.swift Packages/NookWeb/Checks/FeedFilteringCheck.swift -o /tmp/feed-filtering-check && /tmp/feed-filtering-check

import Foundation

@main struct FeedFilteringCheck {
    static func main() throws {
        for host in ["x.com", "www.x.com", "youtube.com", "www.youtube.com", "m.youtube.com", "reddit.com", "www.reddit.com", "old.reddit.com"] {
            precondition(FeedFilterHosts.site(for: URL(string: "https://\(host)/")!) != nil)
        }
        for address in ["https://example.com/", "https://x.com.evil.test/", "https://evil.x.com/", "https://youtube-nocookie.com/", "https://music.youtube.com/", "http://x.com/", "file:///reddit.com"] {
            precondition(FeedFilterHosts.site(for: URL(string: address)!) == nil)
        }
        let muted = FeedPost(id: "muted", author: " @AuThOr ", text: "Harmless")
        let keyword = FeedPost(id: "keyword", author: "other", text: "Some RAGE bait")
        let keep = FeedPost(id: "keep", author: "author-too", text: "Technical detail")
        let rules = FeedSitePreferences(mutedAccounts: ["author"], keywords: ["", "rage"])
        let batch = FeedPostBatch(posts: [muted, keyword, keep], preferences: rules)
        precondition(batch.posts == [keep] && batch.fixed.map(\.id) == ["muted", "keyword"])
        let disabled = FeedPostBatch(posts: [muted], preferences: .init(enabled: false, mutedAccounts: ["author"]))
        precondition(disabled.posts.isEmpty && disabled.fixed.first?.choice == .show)
        let judge = OpenAIDecisionsJudge()
        let posts = [keep] + (0..<25).map { FeedPost(id: "\($0)", author: "a", text: "b") } + [keep]
        let wrong = AttentionEvent(at: "now", kind: .feedWrong, title: "Technical detail", site: "x.com", decidedBy: .you, reason: "Mistakenly hidden")
        let body = try JSONSerialization.jsonObject(with: judge.feedBody(posts: posts, preferences: "No rage", goal: "Build", examples: [wrong])) as! [String: Any]
        precondition((body["questions"] as! [[String: Any]]).count == 20)
        let input = body["input"] as! [[String: Any]]
        let content = input[0]["content"] as! [[String: Any]]
        let payload = content[0]["data"] as! [String: Any]
        precondition((payload["posts"] as! [[String: Any]]).count == 20 && payload["goal"] as? String == "Build")
        precondition((payload["corrections"] as! [[String: String]])[0]["correctChoice"] == "show")
        for response in ["{}", "broken", #"{"answers":[{"type":"refusal"}]}"#, #"{"answers":[{"type":"choice","choice":"hide","confidence":2}]}"#] {
            precondition(judge.feedDecisions(from: Data(response.utf8), posts: [keep]).first?.choice == .show)
        }
        precondition(judge.feedDecisions(from: Data(#"{"answers":[{"type":"choice","choice":"hide","confidence":2}]}"#.utf8), posts: [keep], confidenceFloor: 0).first?.choice == .show)
        precondition(judge.feedDecisions(from: Data(#"{"answers":[{"type":"choice","choice":"hide"}]}"#.utf8), posts: [keep], confidenceFloor: 0).first?.choice == .show)
        let answers = judge.feedDecisions(from: Data(#"{"answers":[{"type":"choice","name":"post_1","choice":"hide","confidence":0.9,"reason":"Rage"},{"type":"choice","name":"post_0","choice":"hide","confidence":0.59}]}"#.utf8), posts: [keep, keyword])
        precondition(answers[0].choice == .show && answers[1].choice == .hide && answers[1].reason == "Rage")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feed-check-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ActivityFiles(directory: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"custom":"keep","enabled":false,"sites":{"youtube.com":{"extra":"Keep videos"},"x.com":{"keywords":["rage"],"custom":42,"mutedAccounts":["@Existing"]}}}"#.utf8).write(to: files.preferencesURL)
        try files.muteFeedAuthor("@AUTHOR", site: "x.com")
        try files.muteFeedAuthor("author", site: "x.com")
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: files.preferencesURL)) as! [String: Any]
        precondition(raw["custom"] as? String == "keep")
        let preferences = files.loadPreferences()
        precondition(!preferences.enabled && preferences.sites["youtube.com"]?.extra == "Keep videos")
        precondition(preferences.sites["x.com"]?.mutedAccounts == ["@Existing", "@AUTHOR"])
        precondition(preferences.sites["x.com"]?.keywords == ["rage"])
        print("Feed filtering checks passed")
    }
}
