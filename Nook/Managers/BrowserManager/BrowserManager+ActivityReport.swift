// Licensed under GPL-3.0. See LICENSE.
//
//  BrowserManager+ActivityReport.swift
//  Nook
//

import Foundation
import NookWeb
import OSLog

private let reportLog = Logger(subsystem: "com.gstudios.nook", category: "Activity")
/// One report at a time; labelling can take a while and a second request would only repeat it.
@MainActor private var reportInFlight = false

extension BrowserManager {
    /// Writes the activity report for `days` days ending today and opens it in a new tab of the
    /// last-used window. Nook is never brought forward, so a launcher can ask for one.
    func openActivityReport(days: Int = 1) {
        guard !reportInFlight else { return }
        reportInFlight = true
        let labeller = focus.labeller, recorder = activityRecorder
        Task { @MainActor in
            defer { reportInFlight = false }
            // Open stretches sit in the checkpoint until they close; close them so time up to now is in the log.
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in recorder.flush { done.resume() } }
            let range = activityReportDays(endingAt: Date(), count: days)
            let files = labeller.files
            let (records, overrides, sessions, events) = await Task.detached(priority: .utility) {
                (files.loadRecords(days: range), files.loadOverrides(), files.loadSessions(), files.loadEvents())
            }.value
            // Private windows are never recorded, so every logged page may be labelled.
            await labeller.labelNow(activityPagesToLabel(records))
            let report = ActivityReport.make(records: records, overrides: overrides, days: range, rules: labeller.rules,
                                             remembered: labeller.remembered, generatedAt: activityTimestamp(Date()), sessions: sessions, events: events)
            do {
                let page = try await Task.detached(priority: .utility) { try files.writeReport(report) }.value
                showActivityReport(page)
            } catch {
                reportLog.error("Could not write the activity report: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func showActivityReport(_ page: URL) {
        let ordinary = tabs.orderedSpaces.first { !$0.isAgent }?.id
        guard let window = windowRegistry?.mostRecentRegularWindow else {
            if let ordinary { tabs.openInBackground(url: page, spaceID: ordinary) }
            return
        }
        // A window showing the Agent space opens into the first ordinary one, as nook://open does.
        let inAgent = window.spaceID.flatMap { tabs.space($0) }?.isAgent == true
        tabs.open(url: page, in: window, placement: .newTab, parent: inAgent ? ordinary.map { .tabs(spaceID: $0) } : nil)
    }
}
