// Licensed under GPL-3.0. See LICENSE.
//
//  FocusModeIndicator.swift
//  Nook
//
//  The running Focus mode's name above the bottom bar. Nothing shows when no mode is on.
//

import SwiftUI
import NookDesign
import NookWeb

struct FocusModeIndicator: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState

    @State private var showingDetails = false
    @State private var correctionPage: PageSession?

    var body: some View {
        if !windowState.isIncognito, let mode = browserManager.focus.activeMode {
            HStack(spacing: NookDesign.Spacing.xs) {
                Image(systemName: "moon")
                Text(mode.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !browserManager.focus.labeller.hasJudgeKey {
                    Image(systemName: "exclamationmark.triangle")
                        .help("No judge key. Pages that need judging stay allowed.")
                }
            }
            .font(NookDesign.Font.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, NookDesign.Spacing.sidebarInset)
            .padding(.bottom, NookDesign.Spacing.xs)
            .contentShape(Rectangle())
            .help(help(for: mode))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Focus mode \(mode.name)")
            .onTapGesture {
                correctionPage = browserManager.focus.activePage
                showingDetails = true
            }
            .popover(isPresented: $showingDetails) { details(for: mode) }
            .contextMenu {
                Button("Open Attention") { browserManager.openAttention() }
                Button("Wrong Allow") { browserManager.focus.wrongAllow() }
                if let host = browserManager.focus.activePage?.url.host {
                    Button("Block This Site") { browserManager.focus.blockSite(host: host) }
                }
                Divider()
                Button("End Focus") { browserManager.focus.end() }
            }
        }
    }

    private func details(for mode: FocusMode) -> some View {
        VStack(alignment: .leading, spacing: NookDesign.Spacing.sm) {
            Text(mode.name).font(NookDesign.Font.body)
            if let goal = browserManager.focus.goal {
                Text(goal).font(NookDesign.Font.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !browserManager.focus.labeller.hasJudgeKey {
                Text("No judge key. Pages that need judging stay allowed.")
                    .font(NookDesign.Font.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let page = correctionPage, !page.isPrivate, !page.isAgentPage, !isInternalActivityURL(page.url) {
                Button("Wrong Allow") {
                    browserManager.focus.wrongAllow(page)
                    showingDetails = false
                }
                .disabled(browserManager.focus.cover(for: page) != nil)
                if let host = page.url.host {
                    Button("Block This Site") {
                        browserManager.focus.blockSite(host: host)
                        showingDetails = false
                    }
                }
            }
            Divider()
            Button("Open Attention") {
                showingDetails = false
                browserManager.openAttention()
            }
            Button("End Focus") {
                browserManager.focus.end()
                showingDetails = false
            }
        }
        .padding(NookDesign.Spacing.md)
        .frame(width: 260, alignment: .leading)
    }

    private func help(for mode: FocusMode) -> String {
        guard let started = browserManager.focus.startedAt else { return "\(mode.name) is on" }
        return "\(mode.name) since \(started.formatted(date: .omitted, time: .shortened))"
    }
}
