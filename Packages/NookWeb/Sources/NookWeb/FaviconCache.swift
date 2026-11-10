// Licensed under GPL-3.0. See LICENSE.
//
//  FaviconCache.swift
//  Nook
//
//  Global favicon cache, shared across profiles by design to raise the hit rate and avoid
//  duplicate downloads. Memory LRU of 200 entries plus a disk cache at
//  ~/Library/Caches/FaviconCache/{key}.png that survives relaunch. Disk I/O runs on a
//  background queue.
//

import Foundation
import SwiftUI

public final class FaviconCache: @unchecked Sendable {
    public static let shared = FaviconCache()

    public static let maxMemoryEntries = 200

    private var memory: [String: PlatformImage] = [:]
    /// Insertion order for LRU eviction.
    private var order: [String] = []
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "favicon.cache", attributes: .concurrent)

    public let directory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("FaviconCache")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {}

    /// Cache key for a page: the host, plus `_port` when the port is not the scheme's default.
    public static func key(for url: URL) -> String? {
        guard let host = url.host else { return nil }
        guard let port = url.port, port != (url.scheme == "https" ? 443 : 80) else { return host }
        return "\(host)_\(port)"
    }

    // MARK: - Lookup

    /// Memory cache only, synchronous.
    public func image(for key: String) -> PlatformImage? {
        lock.withLock { memory[key] }
    }

    /// Memory cache only, as a SwiftUI image.
    public func swiftUIImage(for key: String) -> SwiftUI.Image? {
        image(for: key).map { SwiftUI.Image(platformImage: $0) }
    }

    /// Memory first, then disk off the main thread. A disk hit is promoted to memory.
    public func cachedImage(for key: String) async -> PlatformImage? {
        if let hit = image(for: key) { return hit }
        return await withCheckedContinuation { continuation in
            queue.async {
                let image = self.readFromDisk(key)
                if let image { self.insert(image, for: key) }
                continuation.resume(returning: image)
            }
        }
    }

    /// Synchronous disk read with promotion to memory. For startup restore of a few visible rows.
    public func imageFromDiskSync(for key: String) -> PlatformImage? {
        guard let image = readFromDisk(key) else { return nil }
        insert(image, for: key)
        return image
    }

    /// How long a stored favicon is trusted before a visit fetches it again.
    public static let maxAge: TimeInterval = 24 * 60 * 60

    /// True when the disk copy is older than `maxAge`. Memory-only entries (private pages) are never stale.
    public func isStale(_ key: String) async -> Bool {
        let url = fileURL(key)
        return await withCheckedContinuation { continuation in
            queue.async {
                let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                continuation.resume(returning: modified.map { -$0.timeIntervalSinceNow > Self.maxAge } ?? false)
            }
        }
    }

    // MARK: - Store

    /// Stores in memory and writes a PNG to disk.
    public func store(_ image: PlatformImage, for key: String) {
        store(image, for: key, toDisk: true)
    }

    func store(_ image: PlatformImage, for key: String, toDisk: Bool) {
        let image = Self.boundedForCache(image)
        insert(image, for: key)
        guard toDisk else { return }
        // PNG encoding is CPU work, not I/O; do it on the caller.
        guard let png = image.pngData() else { return }
        let url = fileURL(key)
        queue.async(flags: .barrier) {
            try? png.write(to: url)
        }
    }

    // MARK: - Maintenance

    public func clear() {
        lock.withLock {
            memory.removeAll()
            order.removeAll()
        }
        let dir = directory
        queue.async(flags: .barrier) {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Entry counts in memory and on disk.
    public func stats() -> (memory: Int, disk: Int) {
        let memoryCount = lock.withLock { memory.count }
        let diskCount = (try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) ?? 0
        return (memoryCount, diskCount)
    }

    /// Keys currently in memory.
    public var memoryKeys: [String] {
        lock.withLock { Array(memory.keys) }
    }

    // MARK: - Private

    private func insert(_ image: PlatformImage, for key: String) {
        var evicted: [String] = []
        lock.withLock {
            memory[key] = image
            order.removeAll { $0 == key }
            order.append(key)
            if memory.count > Self.maxMemoryEntries {
                let count = memory.count - Self.maxMemoryEntries + 20
                evicted = Array(order.prefix(count))
                for old in evicted { memory.removeValue(forKey: old) }
                order.removeFirst(min(count, order.count))
            }
        }
        guard !evicted.isEmpty else { return }
        let urls = evicted.map(fileURL)
        queue.async(flags: .barrier) {
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Longest side kept in memory and on disk. Rows draw favicons at 16 pt, the largest use
    /// is well under 64 pt at 2x, and a 512 px touch icon decodes to 1 MB on its own.
    static let maxPixelSide = 128

    /// A copy no larger than `maxPixelSide` that keeps the original point size, so it lays out
    /// exactly as before. Images that already fit, or have no bitmap (PDF), are kept as they are.
    static func boundedForCache(_ image: PlatformImage) -> PlatformImage {
        #if canImport(AppKit)
        let pixels = image.representations.reduce(into: (w: 0, h: 0)) { result, rep in
            if rep.pixelsWide * rep.pixelsHigh > result.w * result.h { result = (rep.pixelsWide, rep.pixelsHigh) }
        }
        let size = image.size
        guard max(pixels.w, pixels.h) > maxPixelSide, size.width > 0, size.height > 0 else { return image }
        let scale = CGFloat(maxPixelSide) / CGFloat(max(pixels.w, pixels.h))
        let width = max(1, Int((CGFloat(pixels.w) * scale).rounded()))
        let height = max(1, Int((CGFloat(pixels.h) * scale).rounded()))
        var proposed = CGRect(x: 0, y: 0, width: width, height: height)
        guard let source = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let bounded = context.makeImage() else { return image }
        return PlatformImage(cgImage: bounded, size: size)
        #else
        return image
        #endif
    }

    private func fileURL(_ key: String) -> URL {
        directory.appendingPathComponent(fileName(key))
    }

    /// Only [A-Za-z0-9._-] survive; the rest (IPv6 colons, slashes) become `_`.
    func fileName(_ key: String) -> String {
        let safe = key.unicodeScalars.map { c -> Character in
            let ok = c.isASCII && (c.properties.isAlphabetic || ("0"..."9").contains(c) || "._-".unicodeScalars.contains(c))
            return ok ? Character(c) : "_"
        }
        return String(safe) + ".png"
    }

    private func readFromDisk(_ key: String) -> PlatformImage? {
        guard let data = try? Data(contentsOf: fileURL(key)), let image = PlatformImage(data: data) else { return nil }
        // Files written before the size bound still hold full-size icons.
        return Self.boundedForCache(image)
    }
}
