// Licensed under GPL-3.0. See LICENSE.
//
//  FocusCoverView.swift
//  Nook
//
//  The cover over a page that does not fit the running Focus mode. Native, like
//  BlockedPageView, so a page can neither see it nor press its buttons.
//

import AppKit
import NookDesign
import NookWeb
import SwiftUI

struct FocusCoverView: View {
    let session: PageSession
    /// The page's own outline, so the cover hides its corners too.
    var shape = AnyShape(Rectangle())

    var body: some View {
        ZStack {
            // Takes no clicks, so an uncovered page underneath behaves as before.
            Color.clear.allowsHitTesting(false)
            if let focus = FocusController.shared, let cover = focus.cover(for: session) {
                FocusCoverCard(session: session, cover: cover, focus: focus)
                    .clipShape(shape)
                    .id((focus.sessionID ?? "") + "|" + cover.url.absoluteString)
            }
        }
        .onAppear { FocusController.shared?.register(session) }
        .onDisappear { FocusController.shared?.unregister(session) }
    }
}

private struct FocusCoverCard: View {
    let session: PageSession
    let cover: FocusCover
    let focus: FocusController

    private static let wait = 10

    @State private var reportedWrong = false
    @State private var continuing = false
    @State private var remaining = Self.wait
    @State private var reason = ""
    @FocusState private var coverFocused: Bool
    @FocusState private var reasonFocused: Bool

    private var host: String {
        let host = cover.url.host ?? cover.url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private var leaveTitle: String {
        session.webView?.canGoBack == true ? "Go Back" : "Close Tab"
    }

    private var canConfirm: Bool {
        remaining == 0 && !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .contentShape(Rectangle())
                .onTapGesture { focusCover() }

            StandardDialog {
                DialogHeader(icon: "moon", title: title, subtitle: subtitle)
            } content: {
                if continuing { continueForm } else { hints }
            } footer: {
                if continuing {
                    DialogFooter(rightButtons: [
                        DialogButton(text: "Cancel") { cancelContinue() },
                        DialogButton(text: "Continue", variant: .primary, isEnabled: canConfirm) { confirm() },
                    ])
                } else {
                    DialogFooter(rightButtons: (cover.decidedBy == .judge ? [
                        DialogButton(text: reportedWrong ? "Reported" : "Wrong Block", isEnabled: !reportedWrong) {
                            focus.wrongBlock(session)
                            reportedWrong = true
                        },
                    ] : []) + (cover.canContinue ? [
                        DialogButton(text: "Continue Anyway") { beginContinue() },
                    ] : []) + [
                        DialogButton(text: leaveTitle, variant: .primary) { focus.leave(session) },
                    ])
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .focusable()
        .focused($coverFocused)
        .focusEffectDisabled()
        .onKeyPress(.return) { handleLeave() }
        .onKeyPress(.escape) { handleLeave() }
        .onKeyPress("c") {
            guard !continuing, cover.canContinue else { return .ignored }
            beginContinue()
            return .handled
        }
        .onAppear { focusCover() }
        .onReceive(NotificationCenter.default.publisher(for: FocusController.refocusCover, object: session)) { _ in
            focusCover()
        }
        .task(id: continuing) {
            guard continuing else { return }
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                remaining -= 1
            }
        }
    }

    private var title: String {
        cover.canContinue ? "\(host) is outside \(cover.mode.name)" : "\(host) is blocked in \(cover.mode.name)"
    }

    private var subtitle: String {
        if cover.decidedBy == .judge { return "This page does not fit your session goal." }
        if cover.mode.isBlockedHost(cover.url) { return "\(cover.mode.name) blocks this site." }
        guard let label = cover.label else { return "This page does not fit \(cover.mode.name)." }
        let words = label.profiles + [label.kind?.rawValue].compactMap { $0 }
        let by: String
        switch label.source {
        case .manual: by = "by you"
        case .rule: by = "by your rules"
        case .jev: by = "by the judge"
        }
        return "Labelled \(words.joined(separator: ", ")) \(by)."
    }

    private var hints: some View {
        VStack(alignment: .leading, spacing: NookDesign.Spacing.sm) {
            if !cover.reason.isEmpty {
                Text(cover.reason)
                    .font(NookDesign.Font.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !cover.mode.description.isEmpty {
                Text(cover.mode.description)
                    .font(NookDesign.Font.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: NookDesign.Spacing.xs) {
                KeycapLabel("return")
                Text("or")
                KeycapLabel("esc")
                Text(leaveTitle.lowercased())
                if cover.canContinue {
                    Text("·")
                    KeycapLabel("c")
                    Text("continue anyway")
                }
            }
            .font(NookDesign.Font.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var continueForm: some View {
        VStack(alignment: .leading, spacing: NookDesign.Spacing.sm) {
            Text(remaining > 0 ? "Take a moment. You can continue in \(remaining) s." : "Why do you need this page now?")
                .font(NookDesign.Font.body)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            TextField("Reason", text: $reason)
                .textFieldStyle(.roundedBorder)
                .focused($reasonFocused)
                .onSubmit { confirm() }
                .onExitCommand { cancelContinue() }
            Text("It stays open for the rest of this \(cover.mode.name) session.")
                .font(NookDesign.Font.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func focusCover() {
        if continuing { reasonFocused = true } else { coverFocused = true }
    }

    private func handleLeave() -> KeyPress.Result {
        guard !continuing else { return .ignored }
        focus.leave(session)
        return .handled
    }

    private func beginContinue() {
        guard cover.canContinue else { return }
        remaining = Self.wait
        reason = ""
        continuing = true
        reasonFocused = true
    }

    private func cancelContinue() {
        continuing = false
        coverFocused = true
    }

    private func confirm() {
        guard canConfirm else { return }
        focus.continueAnyway(session, reason: reason)
    }
}

/// A split pane's cover. Pane controls are separate hosting views so the page gets clicks;
/// this one fills the pane but takes clicks only while it is covering.
final class FocusCoverHostingView: NSHostingView<AnyView> {
    private let itemID: UUID
    private weak var tabs: TabsController?

    init(itemID: UUID, tabs: TabsController, gradientColorManager: GradientColorManager) {
        self.itemID = itemID
        self.tabs = tabs
        super.init(rootView: AnyView(SplitPaneFocusCover(itemID: itemID)
            .environment(tabs)
            .environmentObject(gradientColorManager)))
        safeAreaRegions = []
    }

    @MainActor required init(rootView: AnyView) { fatalError("init(rootView:) has not been implemented") }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let session = tabs?.session(for: itemID), FocusController.shared?.cover(for: session) != nil else { return nil }
        return super.hitTest(point)
    }
}

/// The pane's page can be created after the pane, so it is looked up each time.
private struct SplitPaneFocusCover: View {
    let itemID: UUID
    @Environment(TabsController.self) private var tabs

    var body: some View {
        if let session = tabs.session(for: itemID) {
            FocusCoverView(session: session)
        }
    }
}
