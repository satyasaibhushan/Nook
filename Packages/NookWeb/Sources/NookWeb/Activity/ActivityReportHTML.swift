// Licensed under GPL-3.0. See LICENSE.

import Foundation

/// Text safe inside HTML element content and quoted attributes.
public func activityHTMLEscape(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.count)
    for char in text {
        switch char {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "'": out += "&#39;"
        default: out.append(char)
        }
    }
    return out
}

/// "45 s", "12 m", "3 h", "3 h 12 m".
public func activityDuration(_ seconds: Double) -> String {
    let whole = Int(max(seconds, 0).rounded())
    if whole < 60 { return "\(whole) s" }
    let minutes = whole / 60
    if minutes < 60 { return "\(minutes) m" }
    let rest = minutes % 60
    return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) m"
}

extension ActivityReport {
    /// One self-contained page: no scripts, fonts or images, so opening it makes no requests.
    public func html() -> String {
        var body = ""
        body += "<header><p class=\"eyebrow\">Activity</p><h1>\(e(rangeTitle))</h1>"
        body += "<p class=\"total\"><span class=\"big\">\(activityDuration(total))</span> active"
        if backgroundMedia > 0 { body += "<span class=\"aside\">plus \(activityDuration(backgroundMedia)) of media playing in the background, not counted</span>" }
        body += "</p></header>"

        if total == 0 && media.isEmpty {
            body += "<section><p class=\"empty\">Nothing was recorded in this range.</p></section>"
            return page(body)
        }

        body += "<section><h2>Where time went</h2><div class=\"split\">"
        body += "<div><h3>Scope</h3>\(bars(scopes.map { (bucketName($0.name), $0.seconds, "scope-\($0.name)") }))</div>"
        body += "<div><h3>Kind</h3>\(bars(kinds.map { (bucketName($0.name), $0.seconds, "kind") }))</div>"
        body += "</div></section>"

        body += "<section><h2>Focus modes</h2>"
        if modes.isEmpty {
            body += "<p class=\"empty\">No Focus mode was on.</p>"
        } else {
            body += "<table><thead><tr><th>Mode</th><th class=\"num\">Time</th><th class=\"num\">Continued anyway</th></tr></thead><tbody>"
            for mode in modes {
                body += "<tr><td>\(e(mode.name))</td><td class=\"num\">\(activityDuration(mode.seconds))</td><td class=\"num\">\(mode.overrides)</td></tr>"
            }
            body += "<tr class=\"quiet\"><td>Outside a mode</td><td class=\"num\">\(activityDuration(outsideModes))</td><td class=\"num\"></td></tr>"
            body += "</tbody></table>"
            body += "<p class=\"note\">\(overrides == 1 ? "1 page was" : "\(overrides) pages were") opened with Continue anyway.</p>"
        }
        body += "</section>"

        if !sites.isEmpty {
            body += "<section><h2>Top sites</h2>\(bars(sites.map { ($0.name, $0.seconds, "site") }, ofTotal: false))</section>"
        }
        if !pages.isEmpty {
            body += "<section><h2>Top pages</h2><table><thead><tr><th>Page</th><th>Label</th><th class=\"num\">Time</th></tr></thead><tbody>"
            for item in pages {
                body += "<tr><td>\(pageCell(item.url, item.title))</td><td class=\"label\">\(e(labelText(item)))</td><td class=\"num\">\(activityDuration(item.seconds))</td></tr>"
            }
            body += "</tbody></table></section>"
        }
        if !media.isEmpty {
            body += "<section><h2>Media</h2><table><thead><tr><th>Item</th><th class=\"num\">Watching</th><th class=\"num\">Background</th></tr></thead><tbody>"
            for item in media {
                body += "<tr><td>\(pageCell(item.url, item.title))</td><td class=\"num\">\(item.foreground > 0 ? activityDuration(item.foreground) : "")</td><td class=\"num\">\(item.background > 0 ? activityDuration(item.background) : "")</td></tr>"
            }
            body += "</tbody></table></section>"
        }
        if !unlabelled.isEmpty {
            body += "<section><h2>Unsure or unlabelled</h2><p class=\"note\">Add a rule in rules.json or a manual label in labels.json to settle these.</p>"
            body += "<table><thead><tr><th>Page</th><th>Label</th><th class=\"num\">Time</th></tr></thead><tbody>"
            for item in unlabelled {
                body += "<tr><td>\(pageCell(item.url, item.title))</td><td class=\"label\">\(e(labelText(item)))</td><td class=\"num\">\(item.seconds > 0 ? activityDuration(item.seconds) : "")</td></tr>"
            }
            body += "</tbody></table></section>"
        }
        if !machines.isEmpty {
            body += "<section><h2>Machines</h2>\(bars(machines.map { ($0.name, $0.seconds, "site") }))</section>"
        }
        return page(body)
    }

    private var rangeTitle: String {
        let parse = DateFormatter(), show = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX"); parse.dateFormat = "yyyy-MM-dd"
        show.locale = Locale(identifier: "en_US_POSIX")
        guard let start = parse.date(from: from), let end = parse.date(from: to) else { return from == to ? from : "\(from) to \(to)" }
        if from == to { show.dateFormat = "EEEE d MMMM yyyy"; return show.string(from: end) }
        show.dateFormat = "d MMM"
        let first = show.string(from: start)
        show.dateFormat = "d MMM yyyy"
        return "\(first) to \(show.string(from: end))"
    }

    private var generatedText: String {
        guard let date = parseActivityTimestamp(generatedAt) else { return generatedAt }
        let show = DateFormatter()
        show.locale = Locale(identifier: "en_US_POSIX"); show.dateFormat = "d MMM yyyy 'at' HH:mm"
        return show.string(from: date)
    }

    private func e(_ text: String) -> String { activityHTMLEscape(text) }

    private func pageCell(_ url: String, _ title: String) -> String {
        let shown = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = "<a href=\"\(e(url))\">\(e(shown.isEmpty ? url : shown))</a>"
        return shown.isEmpty ? link : "\(link)<span class=\"url\">\(e(url))</span>"
    }

    private func labelText(_ item: Page) -> String {
        switch item.scope {
        case "unlabelled": return "unlabelled"
        case "internal": return "local"
        default:
            let words = [item.scope, item.kind].compactMap { $0 }.joined(separator: ", ")
            return item.unsure ? "unsure: \(words)" : words
        }
    }

    private func bucketName(_ name: String) -> String { name == "internal" ? "local pages" : name }

    /// Rows of label, bar and time. A bar is the share of the total, or of the largest row.
    private func bars(_ rows: [(String, Double, String)], ofTotal: Bool = true) -> String {
        let scale = ofTotal ? total : rows.map(\.1).max() ?? 0
        var out = "<table class=\"bars\"><tbody>"
        for (name, seconds, style) in rows {
            let fraction = scale > 0 ? min(seconds / scale, 1) : 0
            let percent = ofTotal ? (fraction > 0 && fraction < 0.005 ? "&lt;1%" : "\(Int((fraction * 100).rounded()))%") : ""
            out += "<tr><td class=\"name\">\(e(name))</td>"
            out += "<td class=\"bar\"><span class=\"\(style)\" style=\"width:\(String(format: "%.1f", fraction * 100))%\"></span></td>"
            out += "<td class=\"num\">\(activityDuration(seconds))</td>"
            if ofTotal { out += "<td class=\"num pct\">\(percent)</td>" }
            out += "</tr>"
        }
        return out + "</tbody></table>"
    }

    private func page(_ body: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <title>Activity \(e(from == to ? from : "\(from) to \(to)"))</title>
        <style>
        :root {
          --bg: #fbfbfa; --text: #1d1d1f; --muted: #6e6e73; --rule: #e6e6e3;
          --bar: #5b6b7f; --work: #3d6f9e; --personal: #b0714a; --either: #7a7f86; --none: #c7c7c2; --link: inherit;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg: #1c1c1e; --text: #ececec; --muted: #98989d; --rule: #2f2f32;
            --bar: #8a9bb0; --work: #6d9bc8; --personal: #d39a74; --either: #9a9fa6; --none: #4a4a4e;
          }
        }
        * { box-sizing: border-box; }
        body { margin: 0; background: var(--bg); color: var(--text);
          font: 14px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
          -webkit-font-smoothing: antialiased; }
        main { max-width: 820px; margin: 0 auto; padding: 48px 24px 64px; }
        header { margin-bottom: 40px; }
        .eyebrow { margin: 0; color: var(--muted); font-size: 12px; letter-spacing: .06em; text-transform: uppercase; }
        h1 { margin: 4px 0 16px; font-size: 26px; font-weight: 600; letter-spacing: -.01em; }
        .total { margin: 0; color: var(--muted); }
        .big { color: var(--text); font-size: 32px; font-weight: 600; margin-right: 6px; font-variant-numeric: tabular-nums; }
        .aside { display: block; font-size: 13px; }
        section { margin-top: 40px; }
        h2 { font-size: 15px; font-weight: 600; margin: 0 0 12px; padding-bottom: 8px; border-bottom: 1px solid var(--rule); }
        h3 { font-size: 12px; font-weight: 500; color: var(--muted); margin: 0 0 6px; text-transform: uppercase; letter-spacing: .05em; }
        .split { display: grid; grid-template-columns: 1fr 1fr; gap: 32px; }
        @media (max-width: 640px) { .split { grid-template-columns: 1fr; } }
        table { width: 100%; border-collapse: collapse; }
        th { text-align: left; font-weight: 500; color: var(--muted); font-size: 12px; padding: 6px 8px 6px 0; border-bottom: 1px solid var(--rule); }
        td { padding: 7px 8px 7px 0; border-bottom: 1px solid var(--rule); vertical-align: top; }
        tr:last-child td { border-bottom: 0; }
        .num { text-align: right; white-space: nowrap; font-variant-numeric: tabular-nums; padding-right: 0; padding-left: 12px; }
        .pct { color: var(--muted); width: 3.5em; }
        .bars { table-layout: fixed; }
        .bars td { border-bottom: 0; padding-top: 4px; padding-bottom: 4px; }
        .bars .name { width: 36%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .bars .bar { vertical-align: middle; }
        .bars .num { width: 6em; }
        .bars .bar span { display: block; height: 6px; min-width: 2px; border-radius: 3px; background: var(--bar); }
        .bars .bar .scope-work { background: var(--work); }
        .bars .bar .scope-personal { background: var(--personal); }
        .bars .bar .scope-either { background: var(--either); }
        .bars .bar .scope-unlabelled, .bars .bar .scope-internal { background: var(--none); }
        a { color: var(--link); text-decoration: none; word-break: break-word; }
        a:hover { text-decoration: underline; }
        .url { display: block; color: var(--muted); font-size: 12px; word-break: break-all; }
        .label { color: var(--muted); white-space: nowrap; }
        .quiet td { color: var(--muted); }
        .note, .empty { color: var(--muted); font-size: 13px; margin: 8px 0 0; }
        footer { margin-top: 48px; color: var(--muted); font-size: 12px; }
        </style>
        </head>
        <body><main>
        \(body)
        <footer>Times are active seconds. Media playing in a background tab is listed apart and not added to the total. Generated \(e(generatedText)).</footer>
        </main></body>
        </html>

        """
    }
}
