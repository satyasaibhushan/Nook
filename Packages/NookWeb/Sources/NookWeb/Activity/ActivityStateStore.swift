// Licensed under GPL-3.0. See LICENSE.

import Foundation
import Darwin

/// Share this store with Focus. Mutate only owned keys; unknown JSON values survive updates.
public final class ActivityStateStore: @unchecked Sendable {
    public let url: URL
    private static let lock = NSLock()

    public init(directory: URL) { url = directory.appendingPathComponent("state.json") }

    @discardableResult
    public func update(_ change: (inout [String: Any]) -> Void) throws -> [String: Any] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Darwin.open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(fd, LOCK_UN) }
        var state: [String: Any]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            state = object
        } else {
            state = ["mode": NSNull(), "modeStartedAt": NSNull(), "recordingPaused": false]
        }
        if state["mode"] == nil { state["mode"] = NSNull() }
        if state["modeStartedAt"] == nil { state["modeStartedAt"] = NSNull() }
        if state["recordingPaused"] == nil { state["recordingPaused"] = false }
        if state["goal"] == nil { state["goal"] = NSNull() }
        if state["sessionID"] == nil { state["sessionID"] = NSNull() }
        change(&state)
        let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
        return state
    }

    public func read() throws -> [String: Any] { try update { _ in } }
}
