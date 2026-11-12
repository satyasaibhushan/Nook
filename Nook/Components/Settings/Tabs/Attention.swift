// Licensed under GPL-3.0. See LICENSE.
//
//  Attention.swift
//  Nook
//
//  The Attention settings tab: Focus modes, site rules, feed preferences,
//  the AI judge, and general switches. Each list row pushes its own page;
//  nothing is edited underneath a list. Everything reads and writes the
//  Activity folder through ActivityFiles, off the main thread, and the
//  file watchers in FocusController pick the changes up.
//

import SwiftUI
import OSLog
import NookDesign
import NookSettings
import NookWeb

private let attentionSettingsLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "AttentionSettings")

// MARK: - Store

/// The three hand-editable files behind this tab, loaded once and saved as they change.
@MainActor
@Observable
final class AttentionSettingsStore {
    var modes: [FocusMode] = []
    var rules: [ActivityRule] = []
    var preferences = AttentionPreferences()
    private(set) var loaded = false
    private(set) var saveFailed = false

    let files: ActivityFiles

    init(files: ActivityFiles) {
        self.files = files
    }

    func load() async {
        guard !loaded else { return }
        let files = files
        let snapshot = await Task.detached(priority: .utility) {
            files.seed()
            return (files.loadModes().modes, files.loadRules().rules, files.loadPreferences())
        }.value
        modes = snapshot.0
        rules = snapshot.1
        preferences = snapshot.2
        loaded = true
    }

    func saveModes() {
        let value = FocusModes(modes: modes), files = files
        save { try files.saveModes(value) }
    }

    func saveRules() {
        let value = ActivityRules(rules: rules), files = files
        save { try files.saveRules(value) }
    }

    func savePreferences() {
        let value = preferences, files = files
        save { try files.savePreferences(value) }
    }

    private func save(_ write: @escaping @Sendable () throws -> Void) {
        Task {
            do {
                try await Task.detached(priority: .utility, operation: write).value
                saveFailed = false
            } catch {
                saveFailed = true
                attentionSettingsLog.error("Could not save Attention settings: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

// MARK: - Tab

struct SettingsAttentionTab: View {
    enum Page: Hashable {
        case root
        case modes
        case mode(Int)
        case rules
        case rule(Int)
        case feeds
        case feedSite(String)
        case judge
        case general
    }

    let browserManager: BrowserManager
    @State private var store: AttentionSettingsStore
    @State private var page: Page = .root

    init(browserManager: BrowserManager) {
        self.browserManager = browserManager
        _store = State(initialValue: AttentionSettingsStore(files: browserManager.focus.labeller.files))
    }

    private var profileNames: [String] {
        browserManager.tabs.orderedSpaces.filter { !$0.isAgent }.map(\.name)
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.loaded {
                pageContent
                    .id(page)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if store.saveFailed {
                Text("Could not save to the Activity folder. Your change is still on screen.")
                    .font(NookDesign.Font.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, NookDesign.Spacing.xl)
                    .padding(.vertical, NookDesign.Spacing.sm)
            }
        }
        .task { await store.load() }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .root:
            AttentionRootPage(store: store) { page = $0 }
        case .modes:
            AttentionModesPage(store: store, show: { page = $0 }, back: { page = .root })
        case .mode(let index):
            if store.modes.indices.contains(index) {
                AttentionModePage(store: store, index: index, profileNames: profileNames) { page = .modes }
            }
        case .rules:
            AttentionRulesPage(store: store, show: { page = $0 }, back: { page = .root })
        case .rule(let index):
            if store.rules.indices.contains(index) {
                AttentionRulePage(store: store, index: index, profileNames: profileNames) { page = .rules }
            }
        case .feeds:
            AttentionFeedsPage(store: store, show: { page = $0 }, back: { page = .root })
        case .feedSite(let host):
            AttentionFeedSitePage(store: store, host: host) { page = .feeds }
        case .judge:
            AttentionJudgePage(store: store) { page = .root }
        case .general:
            AttentionGeneralPage(store: store, browserManager: browserManager) { page = .root }
        }
    }
}

// MARK: - Shared rows

/// The pushed page title and its way back, as one quiet row above the form.
private struct AttentionBackRow: View {
    let parent: String
    let title: String
    let back: () -> Void

    var body: some View {
        HStack(spacing: NookDesign.Spacing.sm) {
            Button(action: back) {
                HStack(spacing: NookDesign.Spacing.xxs) {
                    Image(systemName: "chevron.backward")
                    Text(parent)
                }
                .font(NookDesign.Font.body)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            Text(title)
                .font(NookDesign.Font.heading)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .listRowInsets(EdgeInsets(top: NookDesign.Spacing.sm, leading: NookDesign.Spacing.xl, bottom: NookDesign.Spacing.xs, trailing: NookDesign.Spacing.xl))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

/// A list row that pushes a page: title, one line under it, a value, a chevron.
private struct AttentionNavRow: View {
    let title: String
    var detail: String? = nil
    var value: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookDesign.Spacing.md) {
                VStack(alignment: .leading, spacing: NookDesign.Spacing.xxs) {
                    Text(title)
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(NookDesign.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: NookDesign.Spacing.md)
                if let value {
                    Text(value)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(NookDesign.Font.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A small pill, as in the mockup: quiet fill, or red for a block.
private struct AttentionPill: View {
    enum Tone { case quiet, blocked, accent }
    let text: String
    var tone: Tone = .quiet

    var body: some View {
        Text(text)
            .font(NookDesign.Font.caption)
            .foregroundStyle(foreground)
            .padding(.horizontal, NookDesign.Spacing.sm)
            .padding(.vertical, NookDesign.Spacing.xxs)
            .background(background, in: Capsule())
            .lineLimit(1)
    }

    private var foreground: Color {
        switch tone {
        case .quiet: return .secondary
        case .blocked: return .red
        case .accent: return .accentColor
        }
    }

    private var background: Color {
        switch tone {
        case .quiet: return NookDesign.Surface.fill
        case .blocked: return Color.red.opacity(0.12)
        case .accent: return Color.accentColor.opacity(NookDesign.Surface.tintOpacity)
        }
    }
}

/// A tappable token for multi-select lists, filled when picked.
private struct AttentionChip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(NookDesign.Font.secondary)
                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                .padding(.horizontal, NookDesign.Spacing.lg)
                .padding(.vertical, NookDesign.Spacing.xs)
                .background(isOn ? Color.accentColor.opacity(NookDesign.Surface.tintOpacity) : NookDesign.Surface.fill, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Chips laid out left to right at their own widths, wrapping onto new rows.
private struct AttentionChipRow<Item: Identifiable>: View where Item.ID == String {
    let items: [Item]
    let isOn: (Item) -> Bool
    let toggle: (Item) -> Void

    var body: some View {
        AttentionFlowLayout(spacing: NookDesign.Spacing.sm) {
            ForEach(items) { item in
                AttentionChip(title: item.id, isOn: isOn(item)) { toggle(item) }
            }
        }
    }
}

/// The smallest wrapping layout: each view at its ideal size, a new row when one would overflow.
private struct AttentionFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: min(widest, maxWidth), height: y + rowHeight), positions)
    }
}

/// One selectable choice in a short list: profile names and page kinds both read as chips.
private struct AttentionChoice: Identifiable {
    let id: String
}

/// A list of plain strings with remove buttons and one add row, for blocked
/// hosts, muted accounts, and keywords.
private struct AttentionStringList: View {
    let values: [String]
    let addTitle: String
    let prompt: String
    let normalize: (String) -> String
    let update: ([String]) -> Void

    @State private var showingAdd = false
    @State private var draft = ""

    var body: some View {
        ForEach(values, id: \.self) { value in
            LabeledContent {
                Button {
                    update(values.filter { $0 != value })
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            } label: {
                Text(value)
            }
        }
        Button {
            showingAdd = true
        } label: {
            Label(addTitle, systemImage: "plus")
        }
        .alert(addTitle, isPresented: $showingAdd) {
            TextField(prompt, text: $draft)
            Button("Add") {
                let value = normalize(draft)
                draft = ""
                guard !value.isEmpty, !values.contains(value) else { return }
                update(values + [value])
            }
            .disabled(normalize(draft).isEmpty)
            Button("Cancel", role: .cancel) { draft = "" }
        }
    }
}

private func kindName(_ kind: PageKind) -> String {
    kind.rawValue.prefix(1).uppercased() + kind.rawValue.dropFirst()
}

/// How a stored (lowercased) profile reads: the space name when one matches.
private func profileDisplayName(_ stored: String, spaces: [String]) -> String {
    spaces.first { $0.lowercased() == stored } ?? (stored.prefix(1).uppercased() + stored.dropFirst())
}

/// Space names plus any profile names only the files know, so nothing picked by
/// hand in JSON disappears from the editor.
private func knownProfiles(spaces: [String], extra: [String]) -> [AttentionChoice] {
    var names = spaces
    for stored in normalizedActivityProfiles(extra) where !names.contains(where: { $0.lowercased() == stored }) {
        names.append(profileDisplayName(stored, spaces: spaces))
    }
    return names.map { AttentionChoice(id: $0) }
}

// MARK: - Root

private struct AttentionRootPage: View {
    let store: AttentionSettingsStore
    let show: (SettingsAttentionTab.Page) -> Void

    var body: some View {
        Form {
            Section {
                AttentionNavRow(title: "Modes", detail: "Ways of working, and what each one allows.", value: "\(store.modes.count)") { show(.modes) }
                AttentionNavRow(title: "Site rules", detail: "Which sites are for which profiles, and which depend on the page.", value: "\(store.rules.count)") { show(.rules) }
            } header: {
                Text("Focus")
            }
            Section {
                AttentionNavRow(title: "Feeds", detail: "What never to show you, per site, plus feed tweaks.") { show(.feeds) }
            } header: {
                Text("Feeds")
            }
            Section {
                AttentionNavRow(title: "AI judge", detail: "Decides the pages and posts your own rules do not.", value: judgeProviderName(store.preferences.judge.provider)) { show(.judge) }
                AttentionNavRow(title: "General", detail: "Switches, the shortcut, and the Attention page.") { show(.general) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Attention")
    }
}

private func judgeProviderName(_ provider: ActivityJudgeProvider) -> String {
    switch provider {
    case .openAIDecisions: return "OpenAI Decisions"
    }
}

// MARK: - Modes

private struct AttentionModesPage: View {
    let store: AttentionSettingsStore
    let show: (SettingsAttentionTab.Page) -> Void
    let back: () -> Void

    var body: some View {
        Form {
            AttentionBackRow(parent: "Attention", title: "Modes", back: back)
            Section {
                ForEach(Array(store.modes.enumerated()), id: \.offset) { index, mode in
                    Button {
                        show(.mode(index))
                    } label: {
                        HStack(spacing: NookDesign.Spacing.md) {
                            VStack(alignment: .leading, spacing: NookDesign.Spacing.xxs) {
                                Text(mode.name)
                                    .foregroundStyle(.primary)
                                if !mode.description.isEmpty {
                                    Text(mode.description)
                                        .font(NookDesign.Font.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: NookDesign.Spacing.md)
                            AttentionPill(text: mode.offMode == .block ? "Blocks" : "Covers", tone: mode.offMode == .block ? .blocked : .quiet)
                            Image(systemName: "chevron.right")
                                .font(NookDesign.Font.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button(action: addMode) {
                    Label("New Mode", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } footer: {
                Text("Saved to modes.json as you change it.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Modes")
    }

    private func addMode() {
        var name = "New Mode"
        var counter = 2
        while store.modes.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            name = "New Mode \(counter)"
            counter += 1
        }
        store.modes.append(FocusMode(name: name, allowProfiles: []))
        store.saveModes()
        show(.mode(store.modes.count - 1))
    }
}

private struct AttentionModePage: View {
    let store: AttentionSettingsStore
    let index: Int
    let profileNames: [String]
    let back: () -> Void

    @State private var draft: FocusMode
    @State private var nameDraft: String
    @State private var showingDelete = false

    init(store: AttentionSettingsStore, index: Int, profileNames: [String], back: @escaping () -> Void) {
        self.store = store
        self.index = index
        self.profileNames = profileNames
        self.back = back
        let mode = store.modes[index]
        _draft = State(initialValue: mode)
        _nameDraft = State(initialValue: mode.name)
    }

    var body: some View {
        Form {
            AttentionBackRow(parent: "Modes", title: draft.name, back: goBack)
            Section {
                LabeledContent("Name") {
                    TextField("Name", text: $nameDraft)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commitName)
                }
                LabeledContent("Description") {
                    TextField("Description", text: $draft.description)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commit)
                }
            }
            Section {
                VStack(alignment: .leading, spacing: NookDesign.Spacing.sm) {
                    Text("Pages for")
                    AttentionChipRow(items: knownProfiles(spaces: profileNames, extra: draft.allowProfiles),
                                     isOn: { draft.allowProfiles.contains($0.id.lowercased()) },
                                     toggle: toggleProfile)
                }
                VStack(alignment: .leading, spacing: NookDesign.Spacing.sm) {
                    Text("Doing")
                    AttentionChipRow(items: PageKind.allCases.map { AttentionChoice(id: kindName($0)) },
                                     isOn: { choice in PageKind(rawValue: choice.id.lowercased()).map { draft.allowKinds.contains($0) } ?? false },
                                     toggle: toggleKind)
                }
            } header: {
                Text("Allow")
            } footer: {
                Text("Leave a row with nothing picked to allow anything.")
            }
            Section("Everything else") {
                HStack(spacing: NookDesign.Spacing.md) {
                    offModeCard(.friction, title: "Cover", detail: "Hidden behind a cover. Continue Anyway waits 10 seconds and asks why.")
                    offModeCard(.block, title: "Block", detail: "No way through until the session ends.")
                }
            }
            Section("Always blocked in \(draft.name)") {
                AttentionStringList(values: draft.blockHosts, addTitle: "Add a Site", prompt: "Site (e.g. chess.com)",
                                    normalize: { SiteRoutingRule.normalizeDomain($0) }) { values in
                    draft.blockHosts = values
                    commit()
                }
            }
            Section {
                Toggle(isOn: binding(\.askGoal)) {
                    VStack(alignment: .leading, spacing: NookDesign.Spacing.xxs) {
                        Text("Ask for a goal when starting")
                        Text("Pages that depend are checked against the goal, not just the mode.")
                            .font(NookDesign.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if draft.askGoal {
                    LabeledContent("Goal prompt") {
                        TextField("Goal prompt", text: $draft.goalPrompt)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(commit)
                    }
                }
                Toggle(isOn: binding(\.filterFeeds)) {
                    VStack(alignment: .leading, spacing: NookDesign.Spacing.xxs) {
                        Text("Filter feeds during the session")
                        Text("Feed posts off the goal are hidden too, on top of what Feeds already hides.")
                            .font(NookDesign.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Session")
            }
            Section {
                Button("Delete Mode", role: .destructive) { showingDelete = true }
            } footer: {
                Text("Saved to modes.json as you change it.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(draft.name)
        .confirmationDialog("Delete \(draft.name)?", isPresented: $showingDelete, titleVisibility: .visible) {
            Button("Delete Mode", role: .destructive) {
                guard store.modes.indices.contains(index) else { back(); return }
                store.modes.remove(at: index)
                store.saveModes()
                back()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sessions that used it stay in your activity. The mode itself is gone.")
        }
    }

    private func offModeCard(_ offMode: FocusMode.OffMode, title: String, detail: String) -> some View {
        let isOn = draft.offMode == offMode
        return Button {
            draft.offMode = offMode
            commit()
        } label: {
            VStack(alignment: .leading, spacing: NookDesign.Spacing.xs) {
                Text(title)
                    .font(NookDesign.Font.label)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(NookDesign.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(NookDesign.Spacing.lg)
            .background(isOn ? Color.accentColor.opacity(NookDesign.Surface.tintOpacity) : NookDesign.Surface.fill,
                        in: NookDesign.Radius.shape(NookDesign.Radius.md))
            .overlay {
                NookDesign.Radius.shape(NookDesign.Radius.md)
                    .stroke(isOn ? Color.accentColor : Color.clear, lineWidth: NookDesign.Size.hairlineWidth)
            }
        }
        .buttonStyle(.plain)
    }

    private func binding(_ keyPath: WritableKeyPath<FocusMode, Bool>) -> Binding<Bool> {
        Binding(get: { draft[keyPath: keyPath] }, set: { draft[keyPath: keyPath] = $0; commit() })
    }

    private func toggleProfile(_ choice: AttentionChoice) {
        let stored = choice.id.lowercased()
        if draft.allowProfiles.contains(stored) {
            draft.allowProfiles.removeAll { $0 == stored }
        } else {
            draft.allowProfiles = normalizedActivityProfiles(draft.allowProfiles + [stored])
        }
        commit()
    }

    private func toggleKind(_ choice: AttentionChoice) {
        guard let kind = PageKind(rawValue: choice.id.lowercased()) else { return }
        if draft.allowKinds.contains(kind) {
            draft.allowKinds.removeAll { $0 == kind }
        } else {
            draft.allowKinds.append(kind)
        }
        commit()
    }

    /// A name another mode already has, or no name at all, falls back to the saved one.
    private func commitName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let taken = store.modes.enumerated().contains { $0.offset != index && $0.element.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        guard !trimmed.isEmpty, !taken else { nameDraft = draft.name; return }
        draft.name = trimmed
        nameDraft = trimmed
        commit()
    }

    private func commit() {
        guard store.modes.indices.contains(index) else { return }
        var value = draft
        value.allowProfiles = normalizedActivityProfiles(value.allowProfiles)
        draft = value
        store.modes[index] = value
        store.saveModes()
    }

    private func goBack() {
        commitName()
        commit()
        back()
    }
}

// MARK: - Site rules

private func handlingName(_ handling: ActivityHandling) -> String {
    switch handling {
    case .profile: return "Counts as its profiles"
    case .judge: return "Depends on the page"
    case .block: return "Always blocked"
    case .allow: return "Always allowed"
    }
}

private func handlingDetail(_ handling: ActivityHandling) -> String {
    switch handling {
    case .profile: return "Fits any mode that allows these profiles."
    case .judge: return "The AI judge looks at each page address and title. In a session it checks the page against your goal."
    case .block: return "Blocked in every mode, with no way through."
    case .allow: return "Never covered, never checked."
    }
}

private func sourceName(_ source: ActivityRuleSource) -> String {
    switch source {
    case .you: return "You"
    case .learned: return "AI-learned"
    case .seeded: return "Seeded"
    }
}

private func sourceSentence(_ source: ActivityRuleSource) -> String {
    switch source {
    case .you: return "Added by you."
    case .learned: return "Learned from your corrections."
    case .seeded: return "Came with Nook."
    }
}

private struct AttentionRulesPage: View {
    let store: AttentionSettingsStore
    let show: (SettingsAttentionTab.Page) -> Void
    let back: () -> Void

    @State private var query = ""
    @State private var showingAdd = false
    @State private var newHost = ""

    private var matching: [(Int, ActivityRule)] {
        let term = query.trimmingCharacters(in: .whitespaces).lowercased()
        return store.rules.enumerated().compactMap { index, rule in
            term.isEmpty || rule.host.lowercased().contains(term) ? (index, rule) : nil
        }
    }

    private var addableHost: String { SiteRoutingRule.normalizeDomain(query) }

    var body: some View {
        Form {
            AttentionBackRow(parent: "Attention", title: "Site rules", back: back)
            Section {
                SidebarMenuSearchField(prompt: "Search or add a site", text: $query)
            }
            Section {
                if matching.isEmpty {
                    VStack(spacing: NookDesign.Spacing.sm) {
                        Text(query.isEmpty ? "No site rules yet" : "No rule for this search")
                            .font(NookDesign.Font.label)
                        Text("Sites without a rule are treated as Depends on the page.")
                            .font(NookDesign.Font.caption)
                            .foregroundStyle(.secondary)
                        if !addableHost.isEmpty {
                            Button("Add \(addableHost)") { add(host: addableHost) }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, NookDesign.Spacing.lg)
                }
                ForEach(matching, id: \.0) { index, rule in
                    ruleRow(index: index, rule: rule)
                }
                Button {
                    showingAdd = true
                } label: {
                    Label("Add a Site", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } footer: {
                Text("Sites without a rule are treated as Depends on the page. Saved to rules.json.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Site rules")
        .alert("Add a Site", isPresented: $showingAdd) {
            TextField("Site (e.g. example.com)", text: $newHost)
            Button("Add") {
                let host = SiteRoutingRule.normalizeDomain(newHost)
                newHost = ""
                add(host: host)
            }
            .disabled(SiteRoutingRule.normalizeDomain(newHost).isEmpty)
            Button("Cancel", role: .cancel) { newHost = "" }
        }
    }

    private func ruleRow(index: Int, rule: ActivityRule) -> some View {
        Button {
            show(.rule(index))
        } label: {
            HStack(spacing: NookDesign.Spacing.md) {
                Text(String(rule.host.prefix(1)).uppercased())
                    .font(NookDesign.Font.captionStrong)
                    .foregroundStyle(.secondary)
                    .frame(width: NookDesign.Size.settingsChip, height: NookDesign.Size.settingsChip)
                    .background(NookDesign.Surface.fillPressed, in: NookDesign.Radius.shape(NookDesign.Radius.sm))
                VStack(alignment: .leading, spacing: NookDesign.Spacing.xxs) {
                    HStack(spacing: 0) {
                        Text(rule.host)
                            .foregroundStyle(.primary)
                        if let path = rule.pathPrefix, !path.isEmpty {
                            Text(path)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    Text("\(handlingName(rule.handling)) · \(sourceName(rule.source))")
                        .font(NookDesign.Font.caption)
                        .foregroundStyle(rule.handling == .block ? Color.red : Color.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: NookDesign.Spacing.md)
                if rule.handling == .profile {
                    HStack(spacing: NookDesign.Spacing.xs) {
                        ForEach(Array(rule.profiles.prefix(3)), id: \.self) { profile in
                            AttentionPill(text: profileDisplayName(profile, spaces: []))
                        }
                        if rule.profiles.count > 3 {
                            AttentionPill(text: "+\(rule.profiles.count - 3)")
                        }
                    }
                }
                Image(systemName: "chevron.right")
                    .font(NookDesign.Font.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func add(host: String) {
        guard !host.isEmpty else { return }
        if let existing = store.rules.firstIndex(where: { $0.host == host && ($0.pathPrefix ?? "").isEmpty }) {
            show(.rule(existing))
            return
        }
        store.rules.append(ActivityRule(host: host, profiles: [], handling: .judge, source: .you))
        store.saveRules()
        show(.rule(store.rules.count - 1))
    }
}

private struct AttentionRulePage: View {
    let store: AttentionSettingsStore
    let index: Int
    let profileNames: [String]
    let back: () -> Void

    @State private var draft: ActivityRule
    @State private var hostDraft: String
    @State private var pathDraft: String
    @State private var showingDelete = false

    init(store: AttentionSettingsStore, index: Int, profileNames: [String], back: @escaping () -> Void) {
        self.store = store
        self.index = index
        self.profileNames = profileNames
        self.back = back
        let rule = store.rules[index]
        _draft = State(initialValue: rule)
        _hostDraft = State(initialValue: rule.host)
        _pathDraft = State(initialValue: rule.pathPrefix ?? "")
    }

    private var title: String {
        draft.host + (draft.pathPrefix ?? "")
    }

    var body: some View {
        Form {
            AttentionBackRow(parent: "Site rules", title: title, back: goBack)
            Section {
                LabeledContent("Site") {
                    TextField("Site", text: $hostDraft)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commitHost)
                }
                Toggle("Include subdomains", isOn: Binding(
                    get: { draft.includeSubdomains },
                    set: { draft.includeSubdomains = $0; commit() }
                ))
                LabeledContent("Only under this path") {
                    TextField("/", text: $pathDraft)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commitPath)
                }
            } footer: {
                Text("Leave the path empty to cover the whole site.")
            }
            Section("This site is") {
                ForEach(ActivityHandling.allCases, id: \.self) { handling in
                    Button {
                        draft.handling = handling
                        commit()
                    } label: {
                        HStack(spacing: NookDesign.Spacing.md) {
                            Image(systemName: draft.handling == handling ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(draft.handling == handling ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: NookDesign.Spacing.xxs) {
                                Text(handlingName(handling))
                                    .foregroundStyle(.primary)
                                if draft.handling == handling {
                                    Text(handlingDetail(handling))
                                        .font(NookDesign.Font.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if draft.handling == .profile {
                Section("Profiles") {
                    AttentionChipRow(items: knownProfiles(spaces: profileNames, extra: draft.profiles),
                                     isOn: { draft.profiles.contains($0.id.lowercased()) },
                                     toggle: toggleProfile)
                }
            }
            if draft.handling == .profile || draft.handling == .judge {
                Section("Mostly for") {
                    AttentionChipRow(items: [AttentionChoice(id: "Any")] + PageKind.allCases.map { AttentionChoice(id: kindName($0)) },
                                     isOn: isKindPicked,
                                     toggle: pickKind)
                }
            }
            Section {
                Button("Remove Rule", role: .destructive) { showingDelete = true }
            } footer: {
                Text(sourceSentence(draft.source))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(title)
        .confirmationDialog("Remove the rule for \(title)?", isPresented: $showingDelete, titleVisibility: .visible) {
            Button("Remove Rule", role: .destructive) {
                guard store.rules.indices.contains(index) else { back(); return }
                store.rules.remove(at: index)
                store.saveRules()
                back()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Without a rule, this site is treated as Depends on the page.")
        }
    }

    private func isKindPicked(_ choice: AttentionChoice) -> Bool {
        if choice.id == "Any" { return draft.kind == nil }
        return PageKind(rawValue: choice.id.lowercased()).map { draft.kind == $0 } ?? false
    }

    private func pickKind(_ choice: AttentionChoice) {
        draft.kind = choice.id == "Any" ? nil : PageKind(rawValue: choice.id.lowercased())
        commit()
    }

    private func toggleProfile(_ choice: AttentionChoice) {
        let stored = choice.id.lowercased()
        if draft.profiles.contains(stored) {
            draft.profiles.removeAll { $0 == stored }
        } else {
            draft.profiles = normalizedActivityProfiles(draft.profiles + [stored])
        }
        commit()
    }

    private func commitHost() {
        let host = SiteRoutingRule.normalizeDomain(hostDraft)
        guard !host.isEmpty else { hostDraft = draft.host; return }
        draft.host = host
        hostDraft = host
        commit()
    }

    /// Paths read the same with or without the leading slash; the file keeps one shape.
    private func commitPath() {
        var path = pathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if path == "/" { path = "" }
        if !path.isEmpty, !path.hasPrefix("/") { path = "/" + path }
        draft.pathPrefix = path.isEmpty ? nil : path
        pathDraft = path
        commit()
    }

    private func commit() {
        guard store.rules.indices.contains(index) else { return }
        var value = draft
        value.host = value.host.lowercased()
        value.profiles = normalizedActivityProfiles(value.profiles)
        draft = value
        store.rules[index] = value
        store.saveRules()
    }

    private func goBack() {
        commitHost()
        commitPath()
        back()
    }
}

// MARK: - Feeds

/// The feed sites Nook can read, in the order they are listed.
private let feedSites: [(host: String, name: String)] = [
    ("x.com", "X"),
    ("youtube.com", "YouTube"),
    ("reddit.com", "Reddit"),
]

private func feedSiteName(_ host: String) -> String {
    feedSites.first { $0.host == host }?.name ?? host
}

/// Heights for the two free-text boxes, named here as other pages name theirs.
private let neverEditorHeight: CGFloat = 84
private let extraEditorHeight: CGFloat = 52

private struct AttentionFeedsPage: View {
    let store: AttentionSettingsStore
    let show: (SettingsAttentionTab.Page) -> Void
    let back: () -> Void

    @FocusState private var neverFocused: Bool

    private var extraHosts: [String] {
        store.preferences.sites.keys.filter { host in !feedSites.contains { $0.host == host } }.sorted()
    }

    var body: some View {
        @Bindable var store = store
        Form {
            AttentionBackRow(parent: "Attention", title: "Feeds", back: goBack)
            Section {
                Toggle(isOn: Binding(get: { store.preferences.enabled },
                                      set: { store.preferences.enabled = $0; store.savePreferences() })) {
                    VStack(alignment: .leading, spacing: NookDesign.Spacing.xxs) {
                        Text("Filter feeds")
                        Text("Matching posts shrink to a faint line you can open.")
                            .font(NookDesign.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                TextEditor(text: $store.preferences.never)
                    .font(NookDesign.Font.bodyRegular)
                    .frame(height: neverEditorHeight)
                    .focused($neverFocused)
                    .onChange(of: neverFocused) { _, focused in
                        if !focused { store.savePreferences() }
                    }
            } header: {
                Text("Never show me")
            } footer: {
                Text("Applies to every feed Nook can read. Say it in plain words, like you would to a person.")
            }
            Section("Sites") {
                ForEach(feedSites + extraHosts.map { (host: $0, name: $0) }, id: \.host) { site in
                    AttentionNavRow(title: site.name, detail: siteCaption(site.host)) { show(.feedSite(site.host)) }
                }
            }
            Section {
                AttentionNavRow(title: "Site tweaks", detail: "Download buttons, sorting, hidden sections, and the rest of YouTube.") {
                    SettingsNavigation.shared.currentSettingsTab = .tweaks
                }
            } footer: {
                Text("Each site page carries its own tweaks. The full list stays in the Tweaks tab, with the same switches.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Feeds")
    }

    private func siteCaption(_ host: String) -> String {
        guard let site = store.preferences.sites[host] else { return "Nothing set yet" }
        if !site.enabled { return "Off" }
        var parts: [String] = []
        if !site.mutedAccounts.isEmpty { parts.append(site.mutedAccounts.count == 1 ? "1 muted account" : "\(site.mutedAccounts.count) muted accounts") }
        if !site.keywords.isEmpty { parts.append(site.keywords.count == 1 ? "1 word" : "\(site.keywords.count) words") }
        if !site.extra.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append("extra line set") }
        return parts.isEmpty ? "Nothing muted yet" : parts.joined(separator: " · ")
    }

    private func goBack() {
        store.savePreferences()
        back()
    }
}

private struct AttentionFeedSitePage: View {
    let store: AttentionSettingsStore
    let host: String
    let back: () -> Void

    @Environment(\.nookSettings) var nookSettings
    @State private var draft: FeedSitePreferences
    @FocusState private var extraFocused: Bool

    init(store: AttentionSettingsStore, host: String, back: @escaping () -> Void) {
        self.store = store
        self.host = host
        self.back = back
        _draft = State(initialValue: store.preferences.sites[host] ?? FeedSitePreferences())
    }

    private var name: String { feedSiteName(host) }

    var body: some View {
        @Bindable var settings = nookSettings
        Form {
            AttentionBackRow(parent: "Feeds", title: name, back: goBack)
            Section {
                Toggle("Filter \(name)", isOn: Binding(get: { draft.enabled },
                                                       set: { draft.enabled = $0; commit() }))
            }
            Section {
                TextEditor(text: $draft.extra)
                    .font(NookDesign.Font.bodyRegular)
                    .frame(height: extraEditorHeight)
                    .focused($extraFocused)
                    .onChange(of: extraFocused) { _, focused in
                        if !focused { commit() }
                    }
            } header: {
                Text("Also never show me, on \(name)")
            }
            Section {
                Text("Accounts")
                    .font(NookDesign.Font.captionStrong)
                    .foregroundStyle(.secondary)
                AttentionStringList(values: draft.mutedAccounts, addTitle: "Add Account", prompt: "Account",
                                    normalize: { $0.trimmingCharacters(in: .whitespacesAndNewlines) }) { values in
                    draft.mutedAccounts = values
                    commit()
                }
                Text("Words")
                    .font(NookDesign.Font.captionStrong)
                    .foregroundStyle(.secondary)
                AttentionStringList(values: draft.keywords, addTitle: "Add Word or Phrase", prompt: "Word or phrase",
                                    normalize: { $0.trimmingCharacters(in: .whitespacesAndNewlines) }) { values in
                    draft.keywords = values
                    commit()
                }
            } header: {
                Text("Always hide")
            } footer: {
                Text("These are hidden on this Mac without asking the AI judge.")
            }
            tweaksSection(settings: settings)
            Section {} footer: {
                Text("Saved to preferences.json.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(name)
    }

    /// The existing per-site tweaks, on the same switches the Tweaks tab drives.
    @ViewBuilder
    private func tweaksSection(settings: NookSettingsService) -> some View {
        @Bindable var settings = settings
        switch host {
        case "x.com":
            Section {
                Toggle(isOn: downloadButtonBinding(settings: settings)) {
                    VStack(alignment: .leading, spacing: NookDesign.Spacing.xxs) {
                        Text("Download button on photos and videos")
                        Text("Saves the largest size the page offers.")
                            .font(NookDesign.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Tweaks")
            } footer: {
                Text("The same switch as the Tweaks tab.")
            }
        case "youtube.com":
            Section {
                Toggle("Hide Shorts", isOn: $settings.youTubeHideShorts)
                Toggle(isOn: $settings.sponsorBlockEnabled) {
                    VStack(alignment: .leading, spacing: NookDesign.Spacing.xxs) {
                        Text("SponsorBlock")
                        Text("Skips sponsor segments.")
                            .font(NookDesign.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $settings.youTubeFrameThumbnails) {
                    VStack(alignment: .leading, spacing: NookDesign.Spacing.xxs) {
                        Text("Plain thumbnails")
                        Text("Shows a frame from the video instead of the uploader thumbnail.")
                            .font(NookDesign.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Tweaks")
            } footer: {
                Text("The same switches as the Tweaks tab, where the rest of YouTube lives.")
            }
        case "reddit.com":
            Section {
                Toggle(isOn: $settings.redditSortHot) {
                    VStack(alignment: .leading, spacing: NookDesign.Spacing.xxs) {
                        Text("Sort feeds by Hot")
                        Text("Home, subreddits and custom feeds open on Hot instead of Best.")
                            .font(NookDesign.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Tweaks")
            } footer: {
                Text("The same switch as the Tweaks tab.")
            }
        default:
            EmptyView()
        }
    }

    private func downloadButtonBinding(settings: NookSettingsService) -> Binding<Bool> {
        Binding(
            get: { settings.mediaDownloadSites.contains { host == $0 || host.hasSuffix("." + $0) } },
            set: { on in
                if on {
                    if !settings.mediaDownloadSites.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                        settings.mediaDownloadSites.append(host)
                    }
                } else {
                    settings.mediaDownloadSites.removeAll { $0 == host }
                }
            }
        )
    }

    private func commit() {
        store.preferences.sites[host] = draft
        store.savePreferences()
    }

    private func goBack() {
        commit()
        back()
    }
}

// MARK: - AI judge

private struct AttentionJudgePage: View {
    let store: AttentionSettingsStore
    let back: () -> Void

    @State private var modelDraft: String

    init(store: AttentionSettingsStore, back: @escaping () -> Void) {
        self.store = store
        self.back = back
        _modelDraft = State(initialValue: store.preferences.judge.model)
    }

    private var confidencePercent: Int { Int((clampedConfidence * 100).rounded()) }
    private var clampedConfidence: Double { min(0.95, max(0.5, store.preferences.judge.confidenceFloor)) }

    var body: some View {
        Form {
            AttentionBackRow(parent: "Attention", title: "AI judge", back: goBack)
            Section {
                Picker("Provider", selection: Binding(
                    get: { store.preferences.judge.provider },
                    set: { store.preferences.judge.provider = $0; store.savePreferences() }
                )) {
                    ForEach(ActivityJudgeProvider.allCases, id: \.self) { provider in
                        Text(judgeProviderName(provider)).tag(provider)
                    }
                }
                JEVKeySettingRow()
                LabeledContent("Model") {
                    TextField("Model", text: $modelDraft)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .onSubmit(commitModel)
                }
            } footer: {
                Text("Used only for pages and posts your own rules do not decide. Without a key, those pages are let through and feeds only hide your muted accounts and words.")
            }
            Section("How sure it must be") {
                VStack(alignment: .leading, spacing: NookDesign.Spacing.xs) {
                    HStack {
                        Text("Act at \(confidencePercent)% sure or more")
                        Spacer()
                        Text("\(confidencePercent)%")
                            .font(NookDesign.Font.secondary.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(get: { clampedConfidence }, set: { store.preferences.judge.confidenceFloor = $0 }),
                        in: 0.5...0.95,
                        step: 0.05
                    ) { editing in
                        if !editing { store.savePreferences() }
                    }
                    Text("Below that, the page opens and the post stays visible.")
                        .font(NookDesign.Font.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("What it sees") {
                seesRow("A page", "Its address and title.")
                seesRow("A post", "Its text and the author handle.")
                seesRow("Each time", "Your Never show me text and, in a session, the goal.")
                seesRow("Never", "Page contents, cookies, private windows.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("AI judge")
    }

    private func seesRow(_ label: String, _ value: String) -> some View {
        LabeledContent {
            Text(value)
                .foregroundStyle(.secondary)
        } label: {
            Text(label)
        }
    }

    private func commitModel() {
        let trimmed = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = trimmed.isEmpty ? "gpt-6-luna" : trimmed
        modelDraft = model
        store.preferences.judge.model = model
        store.savePreferences()
    }

    private func goBack() {
        commitModel()
        back()
    }
}

// MARK: - General

private struct AttentionGeneralPage: View {
    let store: AttentionSettingsStore
    let browserManager: BrowserManager
    let back: () -> Void

    @Environment(\.nookSettings) var nookSettings

    var body: some View {
        @Bindable var settings = nookSettings
        Form {
            AttentionBackRow(parent: "Attention", title: "General", back: back)
            Section {
                Button(action: openAttention) {
                    Label("Open Attention", systemImage: "arrow.up.right")
                }
                LabeledContent("Address") {
                    Text("nook://attention")
                        .font(NookDesign.Font.mono)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("Open Settings") {
                    Text("\u{2318},")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Attention page")
            } footer: {
                Text("Open Settings with \u{2318}, then pick Attention. The current session and your activity live on the Attention page, at nook://attention.")
            }
            Section {
                Toggle(isOn: Binding(get: { store.preferences.enabled },
                                      set: { store.preferences.enabled = $0; store.savePreferences() })) {
                    VStack(alignment: .leading, spacing: NookDesign.Spacing.xxs) {
                        Text("Filter feeds")
                        Text("Hide posts that match your Never show me text, muted accounts, and words.")
                            .font(NookDesign.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $settings.recordActivity) {
                    VStack(alignment: .leading, spacing: NookDesign.Spacing.xxs) {
                        Text("Record activity")
                        Text("Saves time spent on pages to a local activity log. Private windows are never recorded.")
                            .font(NookDesign.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Focus session") {
                    Text(browserManager.focus.activeMode?.name ?? "Off")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Switches")
            } footer: {
                Text("Record activity is the same switch as Privacy. Modes, rules, and preferences are plain files in the Activity folder, and Nook reads them again whenever they change.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }

    /// Opens the Attention page in a new tab, like the activity report does.
    private func openAttention() {
        guard let url = URL(string: "nook://attention") else { return }
        let tabs = browserManager.tabs
        guard let window = browserManager.windowRegistry?.mostRecentRegularWindow else {
            if let ordinary = tabs.orderedSpaces.first(where: { !$0.isAgent }) {
                tabs.openInBackground(url: url, spaceID: ordinary.id)
            }
            return
        }
        // A window showing the Agent space opens into the first ordinary one, as the report does.
        let inAgent = window.spaceID.flatMap { tabs.space($0) }?.isAgent == true
        let ordinary = tabs.orderedSpaces.first { !$0.isAgent }?.id
        tabs.open(url: url, in: window, placement: .newTab,
                  parent: inAgent ? ordinary.map { .tabs(spaceID: $0) } : nil, title: "Attention")
        window.window?.makeKeyAndOrderFront(nil)
    }
}

#Preview {
    SettingsAttentionTab(browserManager: BrowserManager(settings: NookSettingsService(), windowRegistry: WindowRegistry()))
}
