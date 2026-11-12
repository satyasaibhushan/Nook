// Licensed under GPL-3.0. See LICENSE.

import Foundation

/// The JEV Decisions call for one page. Only the normalised URL and title ever leave Nook.
public enum ActivityJEV {
    public static let endpoint = URL(string: "https://api.openai.com/v1/decisions")!
    public static let model = "gpt-6-luna"
    /// Below this, the answer is remembered but marked unsure, and unsure labels never cover a page.
    public static let confidenceFloor = 0.6

    static let kindDescriptions: [(PageKind, String)] = [
        (.building, "Making something: writing code, documents, designs, configuring tools or infrastructure."),
        (.reading, "Reading or learning: articles, documentation, papers, courses, reference material."),
        (.communication, "Email, chat, messaging, meetings, forums where the person is talking with others."),
        (.admin, "Accounts, billing, settings, calendars, forms, travel, shopping and other errands."),
        (.entertainment, "Video, music, games, streaming, sports and other leisure content."),
        (.social, "Social feeds and networks: scrolling timelines, posts, profiles."),
    ]

    public static func requestBody(url: String, title: String, profiles: [String] = ["work", "personal"], config: ActivityJudgeConfig = .init()) throws -> Data {
        let body: [String: Any] = [
            "model": config.model,
            "input": [[
                "role": "user",
                "content": [["type": "input_json", "data": ["url": url, "title": title]]],
            ]],
            "questions": [
                [
                    "type": "choice",
                    "name": "profile",
                    "instructions": "Which of the person's profiles best describes this page? Use only the supplied profile names. Give a one-line reason.",
                    "choices": normalizedActivityProfiles(profiles).map { ["value": $0, "description": $0] },
                ],
                [
                    "type": "choice",
                    "name": "kind",
                    "instructions": "What kind of activity is this web page mainly used for?",
                    "choices": kindDescriptions.map { ["value": $0.0.rawValue, "description": $0.1] },
                ],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private struct Response: Decodable {
        struct Answer: Decodable {
            var type: String
            var name: String?
            var choice: String?
            var confidence: Double?
            var reason: String?
        }
        var answers: [Answer]
    }

    /// Nil for a refusal, a missing or unknown scope, or anything that does not parse. A kind that
    /// is refused or unknown leaves the kind empty instead of dropping the whole label.
    public static func label(from data: Data, at: String, profiles: [String] = ["work", "personal"], confidenceFloor: Double = 0.6) -> PageLabel? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        func answer(_ name: String, _ index: Int) -> Response.Answer? {
            let named = response.answers.first { $0.name == name }
            let positional = response.answers.indices.contains(index) ? response.answers[index] : nil
            guard let found = named ?? (positional?.name == nil ? positional : nil), found.type == "choice" else { return nil }
            return found
        }
        guard let scopeAnswer = answer("profile", 0) ?? answer("scope", 0),
              let profile = scopeAnswer.choice, normalizedActivityProfiles(profiles).contains(profile.lowercased()) else { return nil }
        let kindAnswer = answer("kind", 1)
        let kind = kindAnswer?.choice.flatMap(PageKind.init(rawValue:))
        let weak = [scopeAnswer.confidence, kind == nil ? nil : kindAnswer?.confidence]
            .contains { ($0 ?? 1) < confidenceFloor }
        let confidence = [scopeAnswer.confidence, kind == nil ? nil : kindAnswer?.confidence].compactMap { $0 }.min()
        return PageLabel(profiles: [profile], kind: kind, source: .jev, unsure: weak, at: at,
                         confidence: confidence, reason: scopeAnswer.reason ?? kindAnswer?.reason)
    }
}
