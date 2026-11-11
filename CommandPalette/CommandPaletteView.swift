// Licensed under GPL-3.0. See LICENSE.
//
//  CommandPaletteView.swift
//  Nook
//
//  Created by Maciek Bagiński on 28/07/2025.
//

import AppKit
import SwiftUI
import Garnish
import NookDesign
import NookSettings
import NookWeb
import NookUI

struct CommandPaletteView: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(CommandPalette.self) private var commandPalette
    @EnvironmentObject var gradientColorManager: GradientColorManager
    @State private var searchManager = SearchManager()
    @Environment(\.nookSettings) var nookSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var text: String = ""
    @State private var selectedSuggestionID: SearchManager.SearchSuggestion.ID?
    @State private var hoveredSuggestionID: SearchManager.SearchSuggestion.ID?
    @State private var userTypedText: String = ""
    @State private var isNavigatingSuggestion: Bool = false
    @State private var activeSiteSearch: SiteSearchEntry? = nil
    /// Set by a deletion, so backspacing out of a completion does not bring it straight back.
    @State private var completionSuppressed: Bool = false

    private var siteSearchMatch: SiteSearchEntry? {
        guard activeSiteSearch == nil else { return nil }
        return SiteSearchEntry.match(for: text, in: nookSettings.siteSearchEntries)
    }

    private var selectedSuggestionIndex: Int {
        guard let selectedSuggestionID else { return -1 }
        return visibleSuggestions.firstIndex { $0.id == selectedSuggestionID } ?? -1
    }

    /// The Return row first, then what the search found.
    private var visibleSuggestions: [SearchManager.SearchSuggestion] {
        var found = searchManager.suggestions
        if activeSiteSearch != nil {
            found = found.filter {
                if case .search = $0.type { return true }
                return false
            }
        }
        guard let primary = primarySuggestion else { return found }
        let rest = found.filter { row in
            switch row.type {
            case .tab, .history: return true
            case .url, .search: return row.text.caseInsensitiveCompare(primary.text) != .orderedSame
            }
        }
        return [primary] + rest.prefix(4)
    }

    /// What Return does with what was typed: the completed host, the address, or a search. The
    /// completion is known within the keystroke, so this row does not change once shown.
    private var primarySuggestion: SearchManager.SearchSuggestion? {
        let typed = userTypedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }
        if let host = completionHost { return SearchManager.SearchSuggestion(text: host, type: .url) }
        return SearchManager.SearchSuggestion(text: typed, type: activeSiteSearch == nil && isLikelyURL(typed) ? .url : .search)
    }

    let commandPaletteWidth: CGFloat = 765
    let commandPaletteHorizontalPadding: CGFloat = 10
    
    /// Active window width
    private var currentWindowWidth: CGFloat {
        return NSApplication.shared.keyWindow?.frame.width ?? 0
    }
    
    /// Check if the command palette fits in the window
    private var isWindowTooNarrow: Bool {
        let requiredWidth = commandPaletteWidth + (commandPaletteHorizontalPadding * 2)
        return currentWindowWidth <= requiredWidth
    }
    
    /// Caclulate the correct command palette width
    private var effectiveCommandPaletteWidth: CGFloat {
        if isWindowTooNarrow {
            return max(200, currentWindowWidth - (commandPaletteHorizontalPadding * 2))
        } else {
            return commandPaletteWidth
        }
    }

    var body: some View {
        let isVisible = commandPalette.isVisible
        let textFieldColor: Color = text.isEmpty ? .secondary : .primary

        return ZStack {
            Color.clear
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .backgroundDraggable(onClick: {
                    commandPalette.close()
                })

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    VStack {
                        VStack(alignment: .center,spacing: 6) {
                            HStack(spacing: 15) {
                                Image(systemName: leadingIconName)
                                .id(leadingIconName)
                                .transition(.blur(intensity: 2, scale: 0.6).animation(NookDesign.Motion.standard))
                                .font(NookDesign.Font.bodyRegular)
                                .foregroundStyle(Color.primary)
                                .frame(width: 15)

                                if let site = activeSiteSearch {
                                    Text(site.name)
                                        .font(NookDesign.Font.label)
                                        .foregroundStyle(Garnish.contrastingShade(of: site.color, targetRatio: 4.5, blendStyle: .strong) ?? .white)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(site.color)
                                        .clipShape(Capsule())
                                        .transition(
                                            .blur(intensity: 8, scale: 0.6)
                                            .animation(NookDesign.Motion.spring)
                                        )
                                }

                                ZStack(alignment: .trailing) {
                                    PaletteSearchField(
                                        text: $text,
                                        placeholder: activeSiteSearch.map { "Search \($0.name)..." } ?? "Search or enter URL...",
                                        isVisible: isVisible,
                                        focusRequest: commandPalette.focusRequest,
                                        prefill: commandPalette.prefilledText,
                                        textColor: NSColor(textFieldColor),
                                        accentColor: NSColor(gradientColorManager.accentColor),
                                        onTextChange: { value in
                                            isNavigatingSuggestion = false
                                            text = value
                                            updateQuery(value)
                                        },
                                        onCommand: handleFieldCommand
                                    )
                                    .frame(height: 22)
                                    .overlay(alignment: .leading) {
                                        if let suffix = inlineCompletionSuffix {
                                            (Text(text).foregroundColor(.clear) + Text(suffix).foregroundColor(.secondary))
                                                .font(NookDesign.Font.heading)
                                                .lineLimit(1)
                                                .allowsHitTesting(false)
                                        }
                                    }
                                    .onChange(of: text) { _, newValue in
                                        guard commandPalette.isVisible else { return }
                                        if isNavigatingSuggestion {
                                            isNavigatingSuggestion = false
                                            return
                                        }
                                        if newValue != userTypedText { updateQuery(newValue) }
                                    }

                                    if activeSiteSearch == nil, let match = siteSearchMatch {
                                        HStack(spacing: 6) {
                                            Text("Search \(match.name)")
                                                .font(NookDesign.Font.body)
                                                .foregroundStyle(Color.secondary)

                                            Text("Tab")
                                                .font(NookDesign.Font.caption)
                                                .foregroundStyle(Color.secondary)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(
                                                    NookDesign.Radius.shape(NookDesign.Radius.xs)
                                                        .fill(NookDesign.Surface.fill)
                                                )
                                                .overlay(
                                                    NookDesign.Radius.shape(NookDesign.Radius.xs)
                                                        .stroke(NookDesign.Surface.hairline, lineWidth: 0.5)
                                                )
                                        }
                                        .allowsHitTesting(false)
                                        .transition(
                                            .blur(intensity: 4, scale: 0.92)
                                            .animation(NookDesign.Motion.standard)
                                        )
                                    }
                                }
                            }
                            .animation(NookDesign.Motion.spring, value: activeSiteSearch != nil)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 8)

                            if !visibleSuggestions.isEmpty {
                                Capsule()
                                    .fill(NookDesign.Surface.hairline)
                                    .frame(height: 0.5)
                                    .frame(maxWidth: .infinity)
                            }

                            if !visibleSuggestions.isEmpty {
                                CommandPaletteSuggestionsListView(
                                    suggestions: visibleSuggestions,
                                    selectedID: selectedSuggestionID ?? visibleSuggestions.first?.id,
                                    hoveredID: $hoveredSuggestionID,
                                    onSelect: { suggestion in
                                        selectSuggestion(suggestion)
                                    }
                                )
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .frame(width: effectiveCommandPaletteWidth)
                        .nookFloatingSurface(in: NookDesign.Radius.shape(NookDesign.Radius.xxl))
                        Spacer()
                    }
                    .frame(
                        width: effectiveCommandPaletteWidth,
                        height: 328
                    )

                    Spacer()
                }
                Spacer()
            }

        }
        .allowsHitTesting(isVisible)
        .animation(isVisible && !reduceMotion ? .easeOut(duration: 0.09) : nil) { content in
            content.opacity(isVisible ? 1.0 : 0.0)
        }
        .onChange(of: commandPalette.focusRequest, initial: true) { _, _ in
            guard commandPalette.isVisible else { return }
            searchManager.setTabs(browserManager.tabs, window: windowState)
            searchManager.setHistoryManager(browserManager.historyManager)
            text = commandPalette.prefilledText
            userTypedText = text
            completionSuppressed = false
            selectedSuggestionID = nil
            searchManager.searchSuggestions(for: text)
        }
        .onChange(of: commandPalette.isVisible) { _, newVisible in
            if !newVisible {
                searchManager.clearSuggestions()
                text = ""
                userTypedText = ""
                activeSiteSearch = nil
                selectedSuggestionID = nil
            }
        }
        .onChange(of: windowState.spaceID) { _, _ in
            if commandPalette.isVisible {
                searchManager.updateSpaceContext()
                searchManager.searchSuggestions(for: userTypedText)
            }
        }
        .onChange(of: searchManager.suggestions) { _, _ in
            if let selectedSuggestionID, !visibleSuggestions.contains(where: { $0.id == selectedSuggestionID }) {
                self.selectedSuggestionID = nil
                isNavigatingSuggestion = true
                text = userTypedText
            }
            if let hoveredSuggestionID, !visibleSuggestions.contains(where: { $0.id == hoveredSuggestionID }) {
                self.hoveredSuggestionID = nil
            }
        }
    }

    private func updateQuery(_ value: String) {
        completionSuppressed = value.count < userTypedText.count
        userTypedText = value
        selectedSuggestionID = nil
        searchManager.searchSuggestions(for: value)
    }

    private func handleFieldCommand(_ selector: Selector, _ modifiers: NSEvent.ModifierFlags) -> Bool {
        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            if let match = siteSearchMatch, activeSiteSearch == nil {
                withAnimation(NookDesign.Motion.spring) { activeSiteSearch = match }
                text = ""
                updateQuery("")
            } else if acceptInlineCompletion() {
                return true
            } else if selectedSuggestionIndex < 0, visibleSuggestions.count > 1 {
                navigateSuggestions(direction: 1)
            } else if selectedSuggestionIndex >= 0, selectedSuggestionIndex < visibleSuggestions.count {
                selectSuggestion(visibleSuggestions[selectedSuggestionIndex])
            } else {
                return false
            }
        case #selector(NSResponder.insertNewline(_:)): handleReturn()
        case #selector(NSResponder.moveRight(_:)):
            return caretIsAtEnd && acceptInlineCompletion()
        case #selector(NSResponder.moveUp(_:)): navigateSuggestions(direction: -1)
        case #selector(NSResponder.moveDown(_:)): navigateSuggestions(direction: 1)
        case #selector(NSResponder.cancelOperation(_:)):
            if activeSiteSearch != nil {
                withAnimation(NookDesign.Motion.standard) { activeSiteSearch = nil }
            } else { commandPalette.close() }
        case #selector(NSResponder.deleteBackward(_:)):
            if modifiers.contains(.shift), removeSelectedHistoryRow() { return true }
            if activeSiteSearch != nil, text.isEmpty {
                withAnimation(NookDesign.Motion.standard) { activeSiteSearch = nil }
            } else { return false }
        default: return false
        }
        return true
    }

    // MARK: - Suggestions List Subview
    private struct CommandPaletteSuggestionsListView: View {
        let suggestions: [SearchManager.SearchSuggestion]
        let selectedID: SearchManager.SearchSuggestion.ID?
        @Binding var hoveredID: SearchManager.SearchSuggestion.ID?
        let onSelect: (SearchManager.SearchSuggestion) -> Void

        var body: some View {
            LazyVStack(spacing: 5) {
                ForEach(suggestions) { suggestion in
                    let isHovered = hoveredID == suggestion.id
                    // Rows keep the text roles on a neutral fill, so the chosen row reads on any accent.
                    row(for: suggestion, isSelected: false)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 11)
                        .background(
                            selectedID == suggestion.id
                                ? NookDesign.Surface.fillPressed
                                : isHovered
                                    ? NookDesign.Surface.fill
                                    : .clear
                        )
                        .clipShape(
                            NookDesign.Radius.shape(NookDesign.Radius.sm)
                        )
                        .font(NookDesign.Font.label)
                        .foregroundStyle(.primary)
                        .contentShape(NookDesign.Radius.shape(NookDesign.Radius.sm))
                        .onHoverTracking { hovering in
                            withAnimation(NookDesign.Motion.quick) {
                                if hovering {
                                    hoveredID = suggestion.id
                                } else {
                                    hoveredID = nil
                                }
                            }
                        }
                        .onTapGesture { onSelect(suggestion) }
                }
            }
        }

        @ViewBuilder
        private func row(
            for suggestion: SearchManager.SearchSuggestion,
            isSelected: Bool
        ) -> some View {
            switch suggestion.type {
            case .tab(let tab):
                TabSuggestionItem(tab: tab, isSelected: isSelected)
            case .history(let entry):
                HistorySuggestionItem(entry: entry, isSelected: isSelected)
            case .url:
                GenericSuggestionItem(
                    icon: Image(systemName: "link"),
                    text: suggestion.text,
                    isSelected: isSelected
                )
            case .search:
                GenericSuggestionItem(
                    icon: Image(systemName: "magnifyingglass"),
                    text: suggestion.text,
                    isSelected: isSelected
                )
            }
        }
    }

    private func handleReturn() {
        if let site = activeSiteSearch {
            let query: String
            if selectedSuggestionIndex >= 0 && selectedSuggestionIndex < visibleSuggestions.count {
                query = visibleSuggestions[selectedSuggestionIndex].text
            } else {
                query = text
            }
            guard !query.isEmpty else { return }
            let navigateURL: String
            if let url = site.searchURL(for: query) {
                navigateURL = url.absoluteString
            } else {
                // Fallback: search on the site's domain directly
                navigateURL = "https://\(site.domain)/search?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)"
            }
            if let url = URL(string: navigateURL) {
                open(url)
            }
            text = ""
            activeSiteSearch = nil
            selectedSuggestionID = nil
            commandPalette.close()
            return
        }

        if selectedSuggestionIndex >= 0
            && selectedSuggestionIndex < visibleSuggestions.count
        {
            let suggestion = visibleSuggestions[selectedSuggestionIndex]
            selectSuggestion(suggestion)
        } else if let primary = primarySuggestion {
            selectSuggestion(primary)
        }
    }

    private func selectSuggestion(_ suggestion: SearchManager.SearchSuggestion)
    {
        switch suggestion.type {
        case .tab(let match):
            guard browserManager.tabs.item(match.itemID) != nil else { return }
            browserManager.tabs.select(match.itemID, in: windowState)
        case .history(let historyEntry):
            open(historyEntry.url)
        case .url, .search:
            // A page another window holds is not navigated from here; the text opens a new tab.
            if commandPalette.shouldNavigateCurrentTab, let session = browserManager.tabs.controllableSession(in: windowState) {
                session.navigate(to: suggestion.text)
            } else {
                // Normalize the URL/search query first, then create the tab with
                // the correct URL so the webview loads it directly without a race.
                let template = browserManager.nookSettings?.resolvedSearchEngineTemplate ?? SearchProvider.google.queryTemplate
                let resolved = normalizeURL(suggestion.text, queryTemplate: template)
                if let url = URL(string: resolved) {
                    browserManager.tabs.open(url: url, in: windowState, placement: .newTab)
                }
            }
        }

        text = ""
        activeSiteSearch = nil
        selectedSuggestionID = nil
        commandPalette.close()
    }

    /// Loads `url` in the selected page when the palette was opened to navigate it, else in a new tab.
    private func open(_ url: URL) {
        let navigateCurrent = commandPalette.shouldNavigateCurrentTab && windowState.selectedItemID != nil
        browserManager.tabs.open(url: url, in: windowState, placement: navigateCurrent ? .replaceCurrent : .newTab)
    }

    /// Makes the inline completion the field's text. False when none is showing.
    private func acceptInlineCompletion() -> Bool {
        guard let host = autofillTarget else { return false }
        text = host
        updateQuery(host)
        return true
    }

    private var caretIsAtEnd: Bool {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return true }
        return editor.selectedRange().location >= (editor.string as NSString).length
    }

    private func navigateSuggestions(direction: Int) {
        let maxIndex = visibleSuggestions.count - 1

        let index: Int
        if direction > 0 {
            guard maxIndex >= 1 else { return }
            index = min(max(selectedSuggestionIndex, 0) + 1, maxIndex)
        } else {
            index = selectedSuggestionIndex <= 1 ? -1 : selectedSuggestionIndex - 1
        }
        selectedSuggestionID = index < 0 ? nil : visibleSuggestions[index].id

        // Update text field to show selected suggestion's info
        isNavigatingSuggestion = true
        if selectedSuggestionIndex >= 0 && selectedSuggestionIndex < visibleSuggestions.count {
            text = displayTextForSuggestion(visibleSuggestions[selectedSuggestionIndex])
        } else {
            text = userTypedText
        }
    }

    private func stripScheme(_ urlString: String) -> String {
        for prefix in ["https://", "http://"] {
            if urlString.hasPrefix(prefix) {
                return String(urlString.dropFirst(prefix.count))
            }
        }
        return urlString
    }

    private func displayTextForSuggestion(_ suggestion: SearchManager.SearchSuggestion) -> String {
        switch suggestion.type {
        case .tab(let tab):
            return stripScheme(tab.url.absoluteString)
        case .history(let entry):
            return stripScheme(entry.url.absoluteString)
        case .url, .search:
            return suggestion.text
        }
    }

    /// Globe once Return would navigate, which includes the case where only the inline
    /// completion makes it a URL.
    private var leadingIconName: String {
        guard activeSiteSearch == nil else { return "magnifyingglass" }
        return isLikelyURL(text) || autofillTarget != nil ? "globe" : "magnifyingglass"
    }

    /// Host that what was typed completes to, while it still prefixes it.
    private var completionHost: String? {
        guard activeSiteSearch == nil,
              !completionSuppressed,
              !userTypedText.isEmpty,
              let host = searchManager.autofillHost,
              host.count > userTypedText.count,
              host.lowercased().hasPrefix(userTypedText.lowercased()) else { return nil }
        return host
    }

    /// The completion shown in the field. Nil while a suggestion is selected by hand, since the
    /// field then holds that row's text instead.
    private var autofillTarget: String? {
        guard selectedSuggestionIndex == -1, text == userTypedText else { return nil }
        return completionHost
    }

    /// Shift-Delete on a history row forgets that page and puts the typed text back.
    private func removeSelectedHistoryRow() -> Bool {
        guard selectedSuggestionIndex >= 0, selectedSuggestionIndex < visibleSuggestions.count,
              case .history(let entry) = visibleSuggestions[selectedSuggestionIndex].type else { return false }
        browserManager.historyManager.deleteHistoryEntry(entry.id)
        selectedSuggestionID = nil
        text = userTypedText
        searchManager.searchSuggestions(for: userTypedText)
        return true
    }

    private var inlineCompletionSuffix: String? {
        autofillTarget.map { String($0.dropFirst(text.count)) }
    }
}

/// Focus and prefill selection happen together, before the next key event can reach the page.
private struct PaletteSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isVisible: Bool
    let focusRequest: UUID
    let prefill: String
    let textColor: NSColor
    let accentColor: NSColor
    let onTextChange: (String) -> Void
    let onCommand: (Selector, NSEvent.ModifierFlags) -> Bool

    final class Field: NSTextField {
        var focusRequest: UUID?
        var appliedFocusRequest: UUID?
        var prefill = ""

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyFocusRequest()
        }

        func applyFocusRequest() {
            guard let window, let focusRequest, appliedFocusRequest != focusRequest else { return }
            stringValue = prefill
            if window.makeFirstResponder(self) {
                currentEditor()?.selectAll(nil)
                appliedFocusRequest = focusRequest
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteSearchField
        init(_ parent: PaletteSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.onTextChange(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            return parent.onCommand(selector, NSApp.currentEvent?.modifierFlags ?? [])
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.font = .systemFont(ofSize: 17, weight: .semibold)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        field.textColor = textColor
        field.prefill = prefill
        field.focusRequest = isVisible ? focusRequest : nil
        if field.stringValue != text { field.stringValue = text }
        field.applyFocusRequest()
        if let editor = field.currentEditor() as? NSTextView {
            editor.insertionPointColor = accentColor
            if !isVisible { field.window?.makeFirstResponder(nil) }
        }
    }
}
