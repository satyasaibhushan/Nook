// Licensed under GPL-3.0. See LICENSE.
// swiftc Packages/NookWeb/Sources/NookWeb/Activity/*.swift Packages/NookWeb/Checks/ActivityCheck.swift -o /tmp/activity-check && /tmp/activity-check

import Foundation

@main struct ActivityCheck {
    static func main() throws {
        func normalize(_ raw: String) -> String? { normalizedActivityURL(URL(string: raw)!)?.absoluteString }
        precondition(normalize("HTTPS://EXAMPLE.COM/docs/?utm_source=a&keep=1&fbclid=b&si=c&ref=x#top") == "https://example.com/docs?keep=1")
        precondition(normalize("https://Example.com/?gclid=a&UTM_TEST=b&ref_src=c&igshid=d&mc_cid=e&mc_eid=f") == "https://example.com/")
        precondition(normalize("https://example.com/a%2Fb/?v=one&v=two&blank=&q=a%26b") == "https://example.com/a%2Fb?v=one&v=two&blank=&q=a%26b")
        precondition(normalize("https://example.com") == "https://example.com")
        for raw in ["about:blank", "nook://settings", "javascript:alert(1)", "data:text/html,hello"] { precondition(normalize(raw) == nil) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 19800)!
        let base = ISO8601DateFormatter().date(from: "2026-11-10T00:00:00+05:30")!
        precondition(activityLogFileName(machine: "../Sai/Mac:Book", start: base, calendar: calendar) == "-Sai-Mac-Book-2026-11-10.jsonl")
        precondition(activityLogFileName(machine: "...", start: base, calendar: calendar) == "Mac-2026-11-10.jsonl")
        let id = UUID(), window = UUID()
        var page = ActivityPage(id: id, url: URL(string: "https://example.com/a?utm_source=one")!, title: "First", space: "Work", foregroundWindow: window, playingMedia: false)
        var engine = ActivityAccounting(machine: "Mac", calendar: calendar)
        func time(_ seconds: Double) -> Date { base.addingTimeInterval(seconds) }
        precondition(engine.update(at: time(0), pages: [page], lastInput: base, mode: nil).isEmpty)
        precondition(engine.update(at: time(150), pages: [page], lastInput: base, mode: nil).isEmpty)
        precondition(engine.checkpoint[0].record.active == 120)
        page.url = URL(string: "https://example.com/a?utm_source=two#fragment")!
        page.title = "Final title"
        precondition(engine.update(at: time(160), pages: [page], lastInput: time(160), mode: nil).isEmpty)
        page.url = URL(string: "https://example.com/b?v=two")!
        var rows = engine.update(at: time(170), pages: [page], lastInput: time(160), mode: nil)
        precondition(rows.count == 1 && rows[0].record.active == 130 && rows[0].record.title == "Final title")
        precondition(rows[0].record.mode == nil && rows[0].record.start.hasSuffix("+05:30"))
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rows[0].record)) as! [String: Any]
        precondition(encoded["mode"] is NSNull && encoded["background"] as? Bool == false)
        page.playingMedia = true
        _ = engine.update(at: time(180), pages: [page], lastInput: base, mode: nil)
        page.foregroundWindow = nil
        rows = engine.update(at: time(190), pages: [page], lastInput: base, mode: nil)
        precondition(rows[0].record.active == 20 && rows[0].record.media == 10 && !rows[0].record.background)
        rows = engine.update(at: time(220), pages: [page], lastInput: base, mode: "Deep Work")
        precondition(rows.count == 1 && rows[0].record.active == 0 && rows[0].record.media == 30 && rows[0].record.background)
        rows = engine.update(at: time(230), pages: [], lastInput: base, mode: "Deep Work")
        precondition(rows[0].record.mode == "Deep Work" && rows[0].record.media == 10)
        // Pausing, private windows and disabled recording all supply an empty eligible-page set.
        precondition(engine.update(at: time(300), pages: [], lastInput: base, mode: nil).isEmpty)
        page.foregroundWindow = window; page.playingMedia = false
        _ = engine.update(at: time(300), pages: [page], lastInput: base, mode: nil)
        precondition(engine.update(at: time(310), pages: [], lastInput: base, mode: nil).isEmpty)
        // A different selected tab closes the first stretch even when its URL is the same.
        _ = engine.update(at: time(320), pages: [page], lastInput: time(320), mode: nil)
        var other = page; other.id = UUID()
        rows = engine.update(at: time(330), pages: [other], lastInput: time(320), mode: nil)
        precondition(rows.count == 1 && rows[0].record.active == 10)
        _ = engine.update(at: time(340), pages: [], lastInput: base, mode: nil)
        // Crossing local midnight splits exactly, with the file chosen by each start date.
        page.playingMedia = true
        _ = engine.update(at: time(86390), pages: [page], lastInput: base, mode: nil)
        rows = engine.update(at: time(86410), pages: [page], lastInput: base, mode: nil)
        precondition(rows.count == 1 && rows[0].record.media == 10 && rows[0].fileName == "Mac-2026-11-10.jsonl")
        precondition(engine.checkpoint[0].record.media == 10 && engine.checkpoint[0].fileName == "Mac-2026-11-11.jsonl")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActivityStateStore(directory: directory)
        let initial = try store.read()
        precondition(initial["mode"] is NSNull && initial["modeStartedAt"] is NSNull && initial["recordingPaused"] as? Bool == false)
        try store.update { $0["mode"] = "Work"; $0["future"] = ["nested": [1, 2, 3]] }
        try ActivityStateStore(directory: directory).update { $0["recordingPaused"] = true }
        let state = try store.read()
        precondition(state["mode"] as? String == "Work" && state["future"] is [String: Any] && state["recordingPaused"] as? Bool == true)
        let group = DispatchGroup()
        for _ in 0..<30 {
            group.enter()
            DispatchQueue.global().async {
                try! ActivityStateStore(directory: directory).update { $0["counter"] = ($0["counter"] as? Int ?? 0) + 1 }
                group.leave()
            }
        }
        group.wait()
        let concurrentState = try store.read()
        precondition(concurrentState["counter"] as? Int == 30)
        // A checkpoint becomes one final line after recovery, even across repeated launches.
        let writer = ActivityLogWriter(directory: directory)
        writer.write(closed: [], open: engine.checkpoint)
        let drained = DispatchSemaphore(value: 0)
        writer.drain { drained.signal() }; drained.wait()
        let recovered = ActivityLogWriter(directory: directory)
        recovered.drain { drained.signal() }; drained.wait()
        let logURL = directory.appendingPathComponent("Log/Mac-2026-11-11.jsonl")
        let firstLog = try Data(contentsOf: logURL)
        precondition(String(data: firstLog, encoding: .utf8)!.split(separator: "\n").count == 1)
        let second = ActivityLogWriter(directory: directory)
        second.drain { drained.signal() }; drained.wait()
        let secondLog = try Data(contentsOf: logURL)
        precondition(secondLog == firstLog)
        // Repair a partial row before appending other recovered stretches to the same file.
        let replayDirectory = directory.appendingPathComponent("replay")
        let replayLogs = replayDirectory.appendingPathComponent("Log")
        try FileManager.default.createDirectory(at: replayLogs, withIntermediateDirectories: true)
        let firstStretch = engine.checkpoint[0]
        let nextStretch = ActivityAccounting.Stretch(id: UUID(), fileName: firstStretch.fileName, record: firstStretch.record)
        let rowEncoder = JSONEncoder()
        rowEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Leading whitespace makes these valid row bytes differ from a fresh JSONEncoder's output.
        let rowData = Data(" ".utf8) + (try rowEncoder.encode(firstStretch.record)) + Data("\n".utf8)
        let freshRow = try JSONEncoder().encode(firstStretch.record) + Data("\n".utf8)
        precondition(rowData != freshRow)
        let replayLog = replayLogs.appendingPathComponent(firstStretch.fileName)
        try rowData.prefix(rowData.count / 2).write(to: replayLog)
        let journal: [[String: Any]] = [
            ["stretch": try JSONSerialization.jsonObject(with: JSONEncoder().encode(firstStretch)), "offset": 0, "row": rowData.base64EncodedString()],
            ["stretch": try JSONSerialization.jsonObject(with: JSONEncoder().encode(nextStretch))]
        ]
        let journalURL = replayDirectory.appendingPathComponent("checkpoint.json")
        try JSONSerialization.data(withJSONObject: journal).write(to: journalURL)
        let repair = ActivityLogWriter(directory: replayDirectory)
        repair.drain { drained.signal() }; drained.wait()
        let repairedLog = try Data(contentsOf: replayLog)
        precondition(repairedLog.starts(with: rowData))
        let repairedRows = try repairedLog.split(separator: 0x0a).map { try JSONDecoder().decode(ActivityRecord.self, from: Data($0)) }
        precondition(repairedRows == [firstStretch.record, nextStretch.record])
        // Simulate death after append but before its journal entry was removed.
        try JSONSerialization.data(withJSONObject: [journal[0]]).write(to: journalURL)
        let repeated = ActivityLogWriter(directory: replayDirectory)
        repeated.drain { drained.signal() }; drained.wait()
        let repeatedLog = try Data(contentsOf: replayLog)
        precondition(repeatedLog == repairedLog)
        // Old checkpoints have no row bytes, including an interrupted or completed append.
        let oldEntry: [String: Any] = ["stretch": journal[0]["stretch"]!, "offset": rowData.count]
        try (rowData + rowData.prefix(rowData.count / 2)).write(to: replayLog)
        try JSONSerialization.data(withJSONObject: [oldEntry]).write(to: journalURL)
        let oldRepair = ActivityLogWriter(directory: replayDirectory)
        oldRepair.drain { drained.signal() }; drained.wait()
        let oldLog = try Data(contentsOf: replayLog)
        let oldRows = try oldLog.split(separator: 0x0a).map { try JSONDecoder().decode(ActivityRecord.self, from: Data($0)) }
        precondition(oldLog.starts(with: rowData) && oldRows == [firstStretch.record, firstStretch.record])
        try JSONSerialization.data(withJSONObject: [oldEntry]).write(to: journalURL)
        let oldRepeated = ActivityLogWriter(directory: replayDirectory)
        oldRepeated.drain { drained.signal() }; drained.wait()
        let oldRepeatedLog = try Data(contentsOf: replayLog)
        precondition(oldRepeatedLog == oldLog)
        try JSONSerialization.data(withJSONObject: [["stretch": journal[0]["stretch"]!, "offset": 0]]).write(to: journalURL)
        let oldDifferentEncoding = ActivityLogWriter(directory: replayDirectory)
        oldDifferentEncoding.drain { drained.signal() }; drained.wait()
        let oldPreservedLog = try Data(contentsOf: replayLog)
        precondition(oldPreservedLog == oldLog)
        let oldOpen: [String: Any] = ["stretch": journal[1]["stretch"]!]
        try JSONSerialization.data(withJSONObject: [oldOpen]).write(to: journalURL)
        let oldCheckpoint = ActivityLogWriter(directory: replayDirectory)
        oldCheckpoint.drain { drained.signal() }; drained.wait()
        let oldCheckpointLog = try Data(contentsOf: replayLog)
        precondition(oldCheckpointLog.split(separator: 0x0a).count == 3)

        // Bad journals preserve every complete line, discard only an incomplete tail and allow new writes.
        var badPartial = journal[0]
        badPartial["offset"] = rowData.count
        var badOffset = journal[0]
        badOffset["offset"] = 1
        for (name, badJournal, contents, complete) in [
            ("mismatch", try JSONSerialization.data(withJSONObject: [badPartial]), rowData + Data("broken row".utf8), rowData),
            ("complete", try JSONSerialization.data(withJSONObject: [journal[0]]), freshRow, freshRow),
            ("offset", try JSONSerialization.data(withJSONObject: [badOffset]), rowData, rowData),
            ("corrupt", Data("not JSON".utf8), Data("broken row".utf8), Data()),
            ("duplicate", try JSONSerialization.data(withJSONObject: [journal[0], journal[0]]), Data(), Data())
        ] {
            let badDirectory = directory.appendingPathComponent(name)
            let badLogs = badDirectory.appendingPathComponent("Log")
            try FileManager.default.createDirectory(at: badLogs, withIntermediateDirectories: true)
            let badLog = badLogs.appendingPathComponent(firstStretch.fileName)
            try contents.write(to: badLog)
            try badJournal.write(to: badDirectory.appendingPathComponent("checkpoint.json"))
            let continuing = ActivityLogWriter(directory: badDirectory)
            continuing.write(closed: [nextStretch], open: [])
            continuing.drain { drained.signal() }; drained.wait()
            let continuedLog = try Data(contentsOf: badLog)
            let continuedRows = try continuedLog.split(separator: 0x0a).map { try JSONDecoder().decode(ActivityRecord.self, from: Data($0)) }
            precondition(continuedLog.starts(with: complete))
            precondition(continuedRows.count == (complete.isEmpty ? 1 : 2))
            let aside = try FileManager.default.contentsOfDirectory(at: badDirectory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("checkpoint-") }
            precondition(aside.count == 1)
            let savedBadJournal = try Data(contentsOf: aside[0])
            precondition(savedBadJournal == badJournal)
            let restart = ActivityLogWriter(directory: badDirectory)
            restart.drain { drained.signal() }; drained.wait()
            let restartedLog = try Data(contentsOf: badLog)
            precondition(restartedLog == continuedLog)
        }
        // A transient append failure retries the pending row on the next write in the same launch.
        let retryDirectory = directory.appendingPathComponent("retry")
        let retry = ActivityLogWriter(directory: retryDirectory)
        retry.drain { drained.signal() }; drained.wait()
        try FileManager.default.createDirectory(at: retryDirectory, withIntermediateDirectories: true)
        let blockedLogs = retryDirectory.appendingPathComponent("Log")
        try Data().write(to: blockedLogs)
        retry.write(closed: [firstStretch], open: [])
        retry.drain { drained.signal() }; drained.wait()
        retry.write(closed: [nextStretch], open: [])
        retry.drain { drained.signal() }; drained.wait()
        try FileManager.default.removeItem(at: blockedLogs)
        let laterStretch = ActivityAccounting.Stretch(id: UUID(), fileName: firstStretch.fileName, record: firstStretch.record)
        retry.write(closed: [laterStretch], open: [])
        retry.drain { drained.signal() }; drained.wait()
        let retriedLog = try Data(contentsOf: blockedLogs.appendingPathComponent(firstStretch.fileName))
        let retriedRows = try retriedLog.split(separator: 0x0a).map { try JSONDecoder().decode(ActivityRecord.self, from: Data($0)) }
        precondition(retriedRows == [firstStretch.record, nextStretch.record, laterStretch.record])
        let stateData = try Data(contentsOf: store.url)
        try Data("not JSON".utf8).write(to: store.url)
        do {
            _ = try store.update { $0["recordingPaused"] = false }
            preconditionFailure("Corrupt state must not be overwritten")
        } catch { }
        let corruptState = try Data(contentsOf: store.url)
        precondition(corruptState == Data("not JSON".utf8))
        try stateData.write(to: store.url)
        print("ActivityCheck passed")
    }
}
