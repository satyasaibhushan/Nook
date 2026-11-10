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

    var body: some View {
        if !windowState.isIncognito, let mode = browserManager.focus.activeMode {
            HStack(spacing: NookDesign.Spacing.xs) {
                Image(systemName: "moon")
                Text(mode.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
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
            .contextMenu {
                Button("End Focus") { browserManager.focus.end() }
            }
        }
    }

    private func help(for mode: FocusMode) -> String {
        guard let started = browserManager.focus.startedAt else { return "\(mode.name) is on" }
        return "\(mode.name) since \(started.formatted(date: .omitted, time: .shortened))"
    }
}
