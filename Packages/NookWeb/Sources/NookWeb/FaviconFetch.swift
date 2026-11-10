// Licensed under GPL-3.0. See LICENSE.
//
//  FaviconFetch.swift
//  Nook
//
//  A favicon for a URL with no live page: saved and pinned rows, history. Apart from
//  FaviconCache.swift so the key check can keep compiling that file on its own.
//

import Foundation
import FaviconFinder

extension FaviconCache {
    /// The cached icon for `url`'s host, else one fetched from the site and stored. Rows of one
    /// host share a fetch, and a host that failed is not asked again for a few minutes.
    @MainActor
    public func image(fetchingIfMissing url: URL) async -> PlatformImage? {
        guard url.scheme == "http" || url.scheme == "https", let key = Self.key(for: url) else { return nil }
        if let cached = await cachedImage(for: key) { return cached }
        if let failed = FaviconFetches.failures[key], Date().timeIntervalSince(failed) < FaviconFetches.failureTTL { return nil }
        let fetch = FaviconFetches.inFlight[key] ?? {
            let task = Task { @MainActor () -> PlatformImage? in
                defer { FaviconFetches.inFlight[key] = nil }
                guard let image = try? await FaviconFinder(url: url).fetchFaviconURLs().download().largest().image?.image else {
                    FaviconFetches.failures[key] = Date()
                    return nil
                }
                self.store(image, for: key)
                return self.image(for: key) ?? image
            }
            FaviconFetches.inFlight[key] = task
            return task
        }()
        return await fetch.value
    }
}

@MainActor
private enum FaviconFetches {
    static var inFlight: [String: Task<PlatformImage?, Never>] = [:]
    static var failures: [String: Date] = [:]
    static let failureTTL: TimeInterval = 300
}
