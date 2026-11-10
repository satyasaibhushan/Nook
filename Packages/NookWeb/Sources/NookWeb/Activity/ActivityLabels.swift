// Licensed under GPL-3.0. See LICENSE.

import Foundation

public enum PageScope: String, Codable, CaseIterable, Sendable { case work, personal, either }

public enum PageKind: String, Codable, CaseIterable, Sendable {
    case building, reading, communication, admin, entertainment, social
}

/// Pages that are never labelled, sent to JEV or covered: Nook's own pages, local files and
/// local development servers.
public func isInternalActivityURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
          let host = url.host?.lowercased(), !host.isEmpty else { return true }
    let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    return bare == "localhost" || bare.hasSuffix(".localhost") || bare == "::1" || bare.hasPrefix("127.")
        || bare == "0.0.0.0"
}

/// Exact host, or a subdomain of it when `includeSubdomains`.
func hostMatches(_ host: String, _ pattern: String, includeSubdomains: Bool) -> Bool {
    let host = host.lowercased(), pattern = pattern.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    guard !pattern.isEmpty else { return false }
    return host == pattern || (includeSubdomains && host.hasSuffix("." + pattern))
}

public struct ActivityRule: Codable, Equatable, Sendable {
    public var host: String
    public var includeSubdomains: Bool
    public var pathPrefix: String?
    public var scope: PageScope
    public var kind: PageKind?

    enum CodingKeys: String, CodingKey { case host, includeSubdomains, pathPrefix, scope, kind }

    public init(host: String, includeSubdomains: Bool = true, pathPrefix: String? = nil, scope: PageScope, kind: PageKind? = nil) {
        self.host = host; self.includeSubdomains = includeSubdomains; self.pathPrefix = pathPrefix
        self.scope = scope; self.kind = kind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decode(String.self, forKey: .host)
        includeSubdomains = try c.decodeIfPresent(Bool.self, forKey: .includeSubdomains) ?? false
        pathPrefix = try c.decodeIfPresent(String.self, forKey: .pathPrefix)
        scope = try c.decode(PageScope.self, forKey: .scope)
        kind = try c.decodeIfPresent(PageKind.self, forKey: .kind)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(host, forKey: .host)
        try c.encode(includeSubdomains, forKey: .includeSubdomains)
        try c.encode(pathPrefix, forKey: .pathPrefix)
        try c.encode(scope, forKey: .scope)
        try c.encodeIfPresent(kind, forKey: .kind)
    }

    func matches(_ url: URL) -> Bool {
        guard let host = url.host, hostMatches(host, self.host, includeSubdomains: includeSubdomains) else { return false }
        var prefix = pathPrefix ?? ""
        while prefix.hasSuffix("/") { prefix.removeLast() }
        guard !prefix.isEmpty else { return true }
        if !prefix.hasPrefix("/") { prefix = "/" + prefix }
        // Whole segments only: /docs and /docs/ match /docs and /docs/a, not /docsearch.
        return url.path == prefix || url.path.hasPrefix(prefix + "/")
    }
}

/// A hand-edited file: one malformed rule is skipped instead of discarding the rest.
private struct Lenient<T: Decodable>: Decodable {
    var value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

public struct ActivityRules: Codable, Equatable, Sendable {
    public var rules: [ActivityRule]

    public init(rules: [ActivityRule]) { self.rules = rules }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rules = (try c.decodeIfPresent([Lenient<ActivityRule>].self, forKey: .rules) ?? []).compactMap(\.value)
    }

    public static let seed = ActivityRules(rules: [
        ActivityRule(host: "aws.amazon.com", scope: .work),
        ActivityRule(host: "x.com", scope: .personal, kind: .social),
        ActivityRule(host: "twitter.com", scope: .personal, kind: .social),
        ActivityRule(host: "youtube.com", scope: .either),
    ])

    /// The most specific rule: longest host, then longest path prefix, then file order.
    public func match(_ url: URL) -> ActivityRule? {
        var best: ActivityRule?
        for rule in rules where rule.matches(url) {
            guard let current = best else { best = rule; continue }
            let a = (rule.host.count, rule.pathPrefix?.count ?? 0), b = (current.host.count, current.pathPrefix?.count ?? 0)
            if a > b { best = rule }
        }
        return best
    }
}

/// A remembered label in labels.json. Rule matches are computed and never stored here.
public struct PageLabel: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case jev, manual }
    public var scope: PageScope
    public var kind: PageKind?
    public var source: Source
    public var unsure: Bool
    public var at: String

    enum CodingKeys: String, CodingKey { case scope, kind, source, unsure, at }

    public init(scope: PageScope, kind: PageKind?, source: Source, unsure: Bool, at: String) {
        self.scope = scope; self.kind = kind; self.source = source; self.unsure = unsure; self.at = at
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scope = try c.decode(PageScope.self, forKey: .scope)
        kind = try c.decodeIfPresent(PageKind.self, forKey: .kind)
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .manual
        unsure = try c.decodeIfPresent(Bool.self, forKey: .unsure) ?? false
        at = try c.decodeIfPresent(String.self, forKey: .at) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(scope, forKey: .scope)
        try c.encode(kind, forKey: .kind)
        try c.encode(source, forKey: .source)
        try c.encode(unsure, forKey: .unsure)
        try c.encode(at, forKey: .at)
    }

    /// Hand-written entries without a source are the owner's, so they count as manual.
    static func decodeAll(_ data: Data) throws -> [String: PageLabel] {
        let raw = try JSONDecoder().decode([String: Lenient<PageLabel>].self, from: data)
        return raw.compactMapValues(\.value)
    }
}

/// The label a page has now, with where it came from.
public struct ResolvedLabel: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case manual, rule, jev }
    public var scope: PageScope
    public var kind: PageKind?
    public var source: Source
    public var unsure: Bool

    public init(scope: PageScope, kind: PageKind?, source: Source, unsure: Bool) {
        self.scope = scope; self.kind = kind; self.source = source; self.unsure = unsure
    }
}

/// Manual label, then a fixed work or personal rule, then a remembered JEV answer. A rule
/// scoped `either` contributes its kind to a JEV answer, and stands alone without one.
public func resolveActivityLabel(_ url: URL, rules: ActivityRules, remembered: [String: PageLabel]) -> ResolvedLabel? {
    guard !isInternalActivityURL(url) else { return nil }
    let key = url.absoluteString
    if let manual = remembered[key], manual.source == .manual {
        return ResolvedLabel(scope: manual.scope, kind: manual.kind, source: .manual, unsure: manual.unsure)
    }
    let rule = rules.match(url)
    if let rule, rule.scope != .either {
        return ResolvedLabel(scope: rule.scope, kind: rule.kind, source: .rule, unsure: false)
    }
    if let jev = remembered[key] {
        return ResolvedLabel(scope: jev.scope, kind: rule?.kind ?? jev.kind, source: .jev, unsure: jev.unsure)
    }
    if let rule { return ResolvedLabel(scope: .either, kind: rule.kind, source: .rule, unsure: false) }
    return nil
}

/// Whether JEV may be asked about `url`. A fixed work or personal rule keeps a page away from
/// JEV for good; that is the owner's privacy rule.
public func activityLabelNeedsJEV(_ url: URL, rules: ActivityRules, remembered: [String: PageLabel]) -> Bool {
    guard !isInternalActivityURL(url), remembered[url.absoluteString] == nil else { return false }
    if let rule = rules.match(url), rule.scope != .either { return false }
    return true
}
