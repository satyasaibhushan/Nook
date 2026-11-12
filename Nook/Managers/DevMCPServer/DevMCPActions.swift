// Licensed under GPL-3.0. See LICENSE.
//
//  DevMCPActions.swift
//  Nook
//
//  What an agent does to a page: click, fill, press. Each answers with what followed the action
//  (a navigation, a new tab, a dialog, console errors, the outline's change), so the agent knows
//  whether it worked without a second call.
//

import Foundation
import NookWeb

extension DevMCPServer {
    static let actionTools: [AIToolDefinition] = [
        AIToolDefinition(
            name: "fill",
            description: "Type value into a text field, text area or contenteditable (ref from snapshot, or selector), replacing what it holds unless append: true. A select gets the option with that value or label. submit: true presses Enter afterwards. Answers with what followed, as clickElement does.",
            parameters: ["type": "object", "properties": [
                "ref": ["type": "string"], "selector": ["type": "string"],
                "value": ["type": "string"], "append": ["type": "boolean"], "submit": ["type": "boolean"],
                "dialogs": dialogsProperty,
            ], "required": ["value"]]
        ),
        AIToolDefinition(
            name: "press",
            description: "Press a key, at the element with ref or selector (focused first) or the focused one: Enter, Tab, Escape, Backspace, Delete, Space, ArrowUp/Down/Left/Right, Home, End, PageUp, PageDown or one character, with Shift+, Control+, Alt+ or Meta+ in front (Meta+a selects all). The page gets keydown, keypress and keyup; unless it prevents the keydown, the key does what it does in a browser (Enter submits a form or follows a link, Tab moves focus). Answers with what followed, as clickElement does.",
            parameters: ["type": "object", "properties": [
                "key": ["type": "string"], "ref": ["type": "string"], "selector": ["type": "string"],
                "dialogs": dialogsProperty,
            ], "required": ["key"]]
        ),
    ]

    static let dialogsProperty: [String: Any] = [
        "type": "string", "enum": ["accept", "dismiss"],
        "description": "How to answer a confirm or prompt the action opens (default dismiss). Alerts are always closed. Either way the report lists them.",
    ]

    /// clickElement's arguments over this server, on top of the chat's selector and text.
    static let clickProperties: [String: Any] = [
        "ref": ["type": "string", "description": "The element's ref from snapshot. Preferred over selector and text."],
        "force": ["type": "boolean", "description": "Click from script even when the element is hidden or covered."],
        "dialogs": dialogsProperty,
    ]
    static let clickDescription = "Click an element (ref from snapshot, a CSS selector, or its visible text) with a real mouse click at its centre, scrolled into view. Refuses when another element covers it there, naming that element. Answers with what followed: navigation and title, new tabs, dialogs, console errors, and the outline's change when the page was snapshotted before."

    /// Runs `name` on `session` and reports what followed.
    func runAction(_ name: String, _ args: [String: Any], session: PageSession, caller: AgentCaller,
                   tabs: TabsController) async throws -> [String: Any] {
        let start = ActionStart(session: session, tabs: tabs.agentTabs(of: caller))
        session.agentAcceptsDialogs = args["dialogs"] as? String == "accept"
        defer { session.agentAcceptsDialogs = false }
        let spec = Self.targetSpec(args)
        let did: String
        switch name {
        case "fill": did = try await fill(session, spec: spec, args)
        case "press": did = try await press(session, spec: spec, key: args["key"] as? String ?? "")
        default: did = try await click(session, spec: spec, force: args["force"] as? Bool == true)
        }
        let report = await actionReport(session, since: start, tabs: tabs, caller: caller)
        return text(([did] + report).joined(separator: "\n"))
    }

    private static func targetSpec(_ args: [String: Any]) -> [String: String] {
        var spec: [String: String] = [:]
        for key in ["ref", "selector", "text"] {
            if let v = args[key] as? String, !v.isEmpty { spec[key] = v }
        }
        return spec
    }

    // MARK: Click

    private func click(_ session: PageSession, spec: [String: String], force: Bool) async throws -> String {
        guard !spec.isEmpty else { throw ActionError("Pass ref, selector or text.") }
        guard let spot = try await session.agentScript("return __nookAgent.locate(spec)", arguments: ["spec": spec]) as? [String: Any],
              let element = spot["element"] as? String, let ref = spot["ref"] as? String else {
            throw ActionError("Could not find the element.")
        }
        if spot["hidden"] as? Bool == true, !force {
            throw ActionError("\(element) takes no space on the page (hidden). Pass force: true to click it from script.")
        }
        if let cover = spot["covered"] as? String, !force {
            throw ActionError("\(element) is covered by \(cover) at its centre. Close what covers it, or pass force: true to click it from script.")
        }
        if force {
            _ = try await session.agentScript("__nookAgent.scriptClick(ref)", arguments: ["ref": ref])
            return "Clicked \(element) from script (force)."
        }
        let navigation = session.loadingNavigationID
        try session.agentClick(at: CGPoint(x: spot["x"] as? Double ?? 0, y: spot["y"] as? Double ?? 0),
                               cssWidth: spot["width"] as? Double ?? 0)
        // The page answers the click a moment later; a click that navigated leaves no record to read.
        let deadline = ContinuousClock.now + .milliseconds(500)
        while ContinuousClock.now < deadline {
            if session.loadingNavigationID != navigation { return "Clicked \(element)." }
            if let seen = try? await session.agentScript("return __nookAgent.clickResult()") as? [String: Any] {
                return seen["trusted"] as? Bool == true ? "Clicked \(element)." : "Clicked \(element) (the page saw an untrusted click)."
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        _ = try await session.agentScript("__nookAgent.scriptClick(ref)", arguments: ["ref": ref])
        return "Clicked \(element) from script: the mouse click did not reach it."
    }

    // MARK: Fill

    private func fill(_ session: PageSession, spec: [String: String], _ args: [String: Any]) async throws -> String {
        guard spec["ref"] != nil || spec["selector"] != nil else { throw ActionError("Pass ref or selector.") }
        guard let value = args["value"] as? String else { throw ActionError("Pass value.") }
        let append = args["append"] as? Bool == true
        guard let field = try await session.agentScript("return __nookAgent.focusField(spec, append)",
                                                        arguments: ["spec": spec, "append": append]) as? [String: Any],
              let element = field["element"] as? String, let ref = field["ref"] as? String else {
            throw ActionError("Could not focus the field.")
        }
        var did: String
        if field["select"] as? Bool == true {
            let chosen = try await session.agentScript("return __nookAgent.selectOption(ref, value)",
                                                       arguments: ["ref": ref, "value": value]) as? String ?? value
            did = "Chose \"\(chosen)\" in \(element)."
        } else {
            let expected = append ? (field["before"] as? String ?? "") + value : value
            if value.isEmpty {
                if !append { try session.agentEditCommand("deleteBackward:") }
            } else {
                try session.agentInsertText(value)
            }
            let now = try await session.agentScript("return __nookAgent.fieldValue(ref)", arguments: ["ref": ref]) as? String
            if now == expected {
                did = "Filled \(element)."
            } else {
                _ = try await session.agentScript("__nookAgent.setValue(ref, value)", arguments: ["ref": ref, "value": expected])
                did = "Filled \(element) from script: typing did not reach it."
            }
        }
        if args["submit"] as? Bool == true {
            did += " " + (try await press(session, spec: ["ref": ref], key: "Enter"))
        }
        return did
    }

    // MARK: Press

    private func press(_ session: PageSession, spec: [String: String], key combo: String) async throws -> String {
        guard let (key, mods) = Self.parseKey(combo) else {
            throw ActionError("Unknown key \(combo). Use Enter, Tab, Escape, Backspace, Delete, Space, arrows, Home, End, PageUp, PageDown or one character, with Shift+, Control+, Alt+ or Meta+ in front.")
        }
        let down = try await session.agentScript("return __nookAgent.keyDown(spec, key, mods)",
                                                 arguments: ["spec": spec, "key": key, "mods": mods]) as? [String: Any] ?? [:]
        if let command = down["command"] as? String { try session.agentEditCommand(command) }
        if let typed = down["text"] as? String { try session.agentInsertText(typed) }
        // The key may have started a navigation; the old page then has no keyup to see.
        _ = try? await session.agentScript("__nookAgent.keyUp(key, mods)", arguments: ["key": key, "mods": mods])
        var did = "Pressed \(combo) at \(down["target"] as? String ?? "the page")"
        if down["prevented"] as? Bool == true { did += "; the page handled it itself" }
        if let focused = down["focused"] as? String { did += "; focus moved to \(focused)" }
        return did + "."
    }

    /// "Shift+Tab" as the DOM key name and modifier flags; nil for a key it does not know.
    static func parseKey(_ combo: String) -> (String, [String: Bool])? {
        var parts = combo.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "+" itself, alone or after modifiers ("Shift++").
        if parts.count >= 2, parts.last == "", parts[parts.count - 2] == "" { parts.removeLast(2); parts.append("+") }
        guard let last = parts.popLast(), !last.isEmpty else { return nil }
        var mods = ["shift": false, "control": false, "alt": false, "meta": false]
        for part in parts {
            switch part.lowercased() {
            case "shift": mods["shift"] = true
            case "control", "ctrl": mods["control"] = true
            case "alt", "option", "opt": mods["alt"] = true
            case "meta", "cmd", "command": mods["meta"] = true
            default: return nil
            }
        }
        if last.count == 1 { return (last, mods) }
        let names = ["enter": "Enter", "return": "Enter", "tab": "Tab", "escape": "Escape", "esc": "Escape",
                     "backspace": "Backspace", "delete": "Delete", "space": " ", "arrowup": "ArrowUp", "up": "ArrowUp",
                     "arrowdown": "ArrowDown", "down": "ArrowDown", "arrowleft": "ArrowLeft", "left": "ArrowLeft",
                     "arrowright": "ArrowRight", "right": "ArrowRight", "home": "Home", "end": "End",
                     "pageup": "PageUp", "pagedown": "PageDown"]
        return names[last.lowercased()].map { ($0, mods) }
    }

    // MARK: Report

    struct ActionStart {
        let url: String
        let navigation: UUID
        let tabs: [UUID]
        let console: Int
        let dialogs: Int

        @MainActor init(session: PageSession, tabs: [UUID]) {
            url = session.webView?.url?.absoluteString ?? session.url.absoluteString
            navigation = session.loadingNavigationID
            self.tabs = tabs
            console = session.devCapture?.console.lastSeq ?? 0
            dialogs = session.agentDialogCount
        }
    }

    /// What followed an action: waits for a load it started, then lists the changes.
    private func actionReport(_ session: PageSession, since start: ActionStart, tabs: TabsController,
                              caller: AgentCaller) async -> [String] {
        let done = await session.waitForLoad(timeout: .seconds(10), startGrace: .milliseconds(300))
        let navigated = session.loadingNavigationID != start.navigation
        let url = session.webView?.url?.absoluteString ?? session.url.absoluteString
        var lines: [String] = []
        if !done {
            lines.append("Still loading after 10s: \(url). Call wait_for_load.")
        } else if navigated, let failure = Self.failedLoad(session) {
            lines.append(failure)
        } else if navigated || url != start.url {
            lines.append("\(url == start.url ? "Reloaded" : "Navigated to") \(url) | \(session.webView?.title ?? session.title)")
        }
        let order = tabs.agentTabs(of: caller)
        for (index, id) in order.enumerated() where !start.tabs.contains(id) {
            let opened = tabs.session(for: id)?.webView?.url?.absoluteString ?? tabs.session(for: id)?.url.absoluteString ?? ""
            let current = tabs.agentCurrentTab(of: caller) == id ? ", now the current tab" : ""
            lines.append("Opened tab \(index)\(current): \(opened)")
        }
        for dialog in session.agentDialogs where dialog.seq > start.dialogs {
            lines.append("Dialog \(dialog.text)")
        }
        if let capture = session.devCapture {
            let errors = capture.console.since(navigated ? 0 : start.console).filter(\.isError)
            for e in errors.prefix(3) { lines.append("Console \(e.level): \(e.message.prefix(300))") }
            if errors.count > 3 { lines.append("…and \(errors.count - 3) more console errors") }
        }
        // The outline's change, when the agent snapshotted this page before and it stayed.
        let key = "\(session.itemID)|\(url)|"
        if !navigated, url == start.url, let previous = snapshots[key],
           let outline = try? await session.devSnapshot("", maxDepth: 12, maxNodes: 300) {
            snapshots[key] = outline
            let diff = DevHandoff.snapshotDiff(old: previous, new: outline).split(separator: "\n")
            if diff.count > 1 {
                lines += diff.prefix(41).map(String.init)
                if diff.count > 41 { lines.append("…\(diff.count - 41) more changed lines; call snapshot for the rest") }
            }
        }
        if lines.isEmpty { lines.append("No navigation, new tab, dialog or console error followed.") }
        return lines
    }
}

struct ActionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
