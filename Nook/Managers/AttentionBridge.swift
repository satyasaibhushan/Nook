// Licensed under GPL-3.0. See LICENSE.
//
//  AttentionBridge.swift
//  Nook
//
//  The one bridge between the Attention tab and the app. The session registers it only
//  while the page shows an Attention URL, and every message is rechecked against the
//  frame's own URL before its body is read. All inputs are validated; a bad one answers
//  with an error and changes nothing.
//

import Foundation
import NookWeb
import WebKit

@MainActor
final class AttentionBridgeHandler: NSObject, WKScriptMessageHandlerWithReply {
    private weak var manager: BrowserManager?
    private weak var session: PageSession?
    private var lastReport: ActivityReport?
    private var lastReportDays = 0
    private var lastEventsByID: [String: AttentionEvent] = [:]

    init(manager: BrowserManager, session: PageSession) {
        self.manager = manager
        self.session = session
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard message.name == PageSession.attentionHandlerName,
              message.world == .page,
              message.frameInfo.isMainFrame,
              let frameURL = message.frameInfo.request.url, isAttentionPageURL(frameURL),
              let session, !session.isPrivate,
              let manager else { return (nil, "Not available here") }
        guard let body = message.body as? [String: Any],
              let method = body["method"] as? String, method.count <= 32 else {
            return (nil, "Bad message")
        }
        switch method {
        case "getState": return (Self.state(manager.focus), nil)
        case "startSession": return start(body, manager: manager, requireActive: false)
        case "switchMode": return start(body, manager: manager, requireActive: true)
        case "endSession":
            manager.focus.end()
            return (["ok": true], nil)
        case "getReport":
            guard let days = Self.days(in: body) else { return (nil, "Bad range") }
            let (report, events) = await buildReport(days: days, manager: manager)
            guard let payload = Self.reportPayload(report, events: events, days: days) else {
                return (nil, "Could not build the report")
            }
            return (payload, nil)
        case "flag": return flag(body, manager: manager)
        case "ask": return await ask(body, manager: manager)
        default: return (nil, "Unknown method")
        }
    }

    // MARK: - State and sessions

    private static func state(_ focus: FocusController) -> [String: Any] {
        var state: [String: Any] = [
            "active": focus.activeMode != nil,
            "hasJudgeKey": focus.labeller.hasJudgeKey,
            "modes": focus.modes.modes.map { mode in
                ["name": mode.name, "description": mode.description, "goalPrompt": mode.goalPrompt,
                 "askGoal": mode.askGoal, "offMode": mode.offMode.rawValue] as [String: Any]
            },
        ]
        if let mode = focus.activeMode { state["mode"] = mode.name }
        if let goal = focus.goal { state["goal"] = goal }
        if let startedAt = focus.startedAt { state["startedAt"] = activityTimestamp(startedAt) }
        if let sessionID = focus.sessionID { state["sessionID"] = sessionID }
        return state
    }

    private func start(_ body: [String: Any], manager: BrowserManager, requireActive: Bool) -> (Any?, String?) {
        if requireActive, manager.focus.activeMode == nil { return (nil, "No session is running") }
        guard let name = Self.string(body["mode"], max: 100),
              let mode = manager.focus.modes.mode(named: name) else { return (nil, "Unknown mode") }
        var goal: String?
        if body["goal"] != nil {
            guard let raw = Self.string(body["goal"], max: 500, allowEmpty: true) else { return (nil, "Bad goal") }
            let oneLine = raw.components(separatedBy: .newlines).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            goal = oneLine.isEmpty ? nil : oneLine
        }
        manager.focus.start(named: mode.name, goal: goal)
        return (["ok": true], nil)
    }

    // MARK: - Report

    /// Loads and builds off the main thread. The recorder is flushed first so the stretch
    /// still open is in the log. Labelling is left to the static report; the numbers this
    /// page shows do not need it, and opening a tab must not call the AI judge.
    private func buildReport(days: Int, manager: BrowserManager) async -> (ActivityReport, [String: [AttentionEvent]]) {
        let recorder = manager.activityRecorder
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in recorder.flush { done.resume() } }
        let range = activityReportDays(endingAt: Date(), count: days)
        let files = manager.focus.labeller.files
        let rules = manager.focus.labeller.rules
        let remembered = manager.focus.labeller.remembered
        let generatedAt = activityTimestamp(Date())
        let (report, events) = await Task.detached(priority: .utility) {
            let records = files.loadRecords(days: range)
            let allEvents = files.loadEvents()
            let report = ActivityReport.make(records: records, overrides: files.loadOverrides(), days: range,
                                             rules: rules, remembered: remembered, generatedAt: generatedAt,
                                             sessions: files.loadSessions(), events: allEvents)
            let wanted = Set(range)
            let ids = Set(report.sessions.map(\.id))
            var bySession: [String: [AttentionEvent]] = [:]
            for event in allEvents.sorted(by: { $0.at < $1.at }) {
                guard let id = event.session, ids.contains(id), wanted.contains(String(event.at.prefix(10))),
                      bySession[id, default: []].count < 100 else { continue }
                bySession[id, default: []].append(event)
            }
            return (report, bySession)
        }.value
        lastReport = report
        lastReportDays = days
        lastEventsByID = Dictionary(events.values.flatMap { $0 }.map { (Self.eventID($0), $0) },
                                    uniquingKeysWith: { _, latest in latest })
        return (report, events)
    }

    private static func eventID(_ event: AttentionEvent) -> String {
        "\(event.at)|\(event.kind.rawValue)|\(event.url ?? event.site ?? "")"
    }

    private static func reportPayload(_ report: ActivityReport, events: [String: [AttentionEvent]], days: Int) -> [String: Any]? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(report),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let bySession = events.mapValues { list in
            list.map { event -> [String: Any] in
                var row: [String: Any] = ["id": eventID(event), "at": event.at, "kind": event.kind.rawValue,
                                          "decidedBy": event.decidedBy.rawValue]
                if let url = event.url { row["url"] = url }
                if let title = event.title { row["title"] = title }
                if let site = event.site { row["site"] = site }
                if let reason = event.reason { row["reason"] = reason }
                if let confidence = event.confidence { row["confidence"] = confidence }
                if let count = event.count { row["count"] = count }
                return row
            }
        }
        return ["report": parsed, "eventsBySession": bySession, "days": days]
    }

    // MARK: - Corrections

    private func flag(_ body: [String: Any], manager: BrowserManager) -> (Any?, String?) {
        let kind: AttentionEvent.Kind
        switch Self.string(body["kind"], max: 32) {
        case "wrongBlock": kind = .wrongBlock
        case "wrongAllow": kind = .wrongAllow
        default: return (nil, "Bad correction")
        }
        var url = Self.string(body["url"], max: 2048)
        var title = Self.string(body["title"], max: 300, allowEmpty: true)
        var sessionID = Self.string(body["sessionID"], max: 100)
        var modeName = Self.string(body["mode"], max: 100)
        if url == nil, let eventID = Self.string(body["eventId"], max: 300), let event = lastEventsByID[eventID] {
            url = event.url
            title = title ?? event.title
            sessionID = sessionID ?? event.session
            modeName = modeName ?? event.mode
        }
        guard let url else { return (nil, "No page to mark") }
        guard manager.focus.recordCorrection(kind: kind, urlString: url, title: title,
                                             sessionID: sessionID, modeName: modeName) else {
            return (nil, "That page cannot be marked")
        }
        return (["ok": true], nil)
    }

    // MARK: - Ask

    /// A plain summary of the loaded range, computed on this Mac. There is no AI judge
    /// question behind it yet; swap this body when one exists.
    private func ask(_ body: [String: Any], manager: BrowserManager) async -> (Any?, String?) {
        guard Self.string(body["question"], max: 500) != nil else { return (nil, "Bad question") }
        if body["days"] != nil, Self.days(in: body) == nil { return (nil, "Bad range") }
        let days = Self.days(in: body) ?? (lastReportDays > 0 ? lastReportDays : 1)
        let report: ActivityReport
        if let lastReport, lastReportDays == days {
            report = lastReport
        } else {
            report = await buildReport(days: days, manager: manager).0
        }
        let sessions = report.sessions
        let range = days == 1 ? "today" : "in the last \(days) days"
        guard !sessions.isEmpty else {
            return (["answer": "No focus sessions \(range) yet. Start one above and this page fills in as you browse."], nil)
        }
        let active = sessions.reduce(0) { $0 + $1.active }
        let on = sessions.reduce(0) { $0 + $1.onGoal }
        let off = sessions.reduce(0) { $0 + $1.offGoal }
        let share = on + off > 0 ? Int((on / (on + off) * 100).rounded()) : 100
        let covers = sessions.reduce(0) { $0 + $1.covers }
        let continued = sessions.reduce(0) { $0 + $1.continued }
        var answer = "\(sessions.count) focus session\(sessions.count == 1 ? "" : "s") \(range), "
            + "\(Self.duration(active)) in focus and \(share)% of it on goal. "
            + "\(covers) page\(covers == 1 ? "" : "s") covered, \(continued) continued past."
        if let top = report.sites.first {
            answer += " Most time went to \(top.name) at \(Self.duration(top.seconds))."
        }
        answer += " This summary is computed on this Mac; the AI judge does not answer questions yet."
        return (["answer": answer], nil)
    }

    // MARK: - Validation

    private static func string(_ value: Any?, max: Int, allowEmpty: Bool = false) -> String? {
        guard let raw = value as? String, raw.count <= max else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return allowEmpty || !trimmed.isEmpty ? trimmed : nil
    }

    private static func days(in body: [String: Any]) -> Int? {
        guard let value = body["days"] as? Int, [1, 7, 30].contains(value) else { return nil }
        return value
    }

    private static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60
        if hours > 0 { return minutes > 0 ? "\(hours) h \(minutes) m" : "\(hours) h" }
        return "\(minutes) m"
    }
}
