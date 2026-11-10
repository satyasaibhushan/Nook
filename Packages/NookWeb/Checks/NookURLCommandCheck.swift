// Licensed under GPL-3.0. See LICENSE.
//
//  NookURLCommandCheck.swift
//  Nook
//
//  swiftc Packages/NookWeb/Sources/NookWeb/NookURLCommand.swift \
//         Packages/NookWeb/Checks/NookURLCommandCheck.swift -o /tmp/nookurl-check && /tmp/nookurl-check
//

import Foundation

@main
struct NookURLCommandCheck {
    static func parse(_ s: String) -> NookURLCommand? { NookURLCommand.parse(URL(string: s)!) }

    static func main() {
        let open = parse("nook://open?url=https%3A%2F%2Fexample.com%2Fa%3Fb%3D1%23x&space=Work&reuse=1&junk=2")
        precondition(open?.action == .open(URL(string: "https://example.com/a?b=1#x")!, reuse: true))
        precondition(open?.space == "Work" && open?.ignored == ["junk"])
        precondition(parse("nook://open?url=http://a.com")?.action == .open(URL(string: "http://a.com")!, reuse: false))
        precondition(parse("NOOK://OPEN?url=https://a.com") != nil)
        precondition(parse("nook://search?q=hello%20world&space=a")?.action == .search("hello world"))
        precondition(parse("nook://space?name=Work")?.space == "Work")
        precondition(parse("nook://open?url=https://a.com&space=") == nil && parse("nook://open?url=https://a.com&space=%20") == nil)
        precondition(parse("nook://search?q=a&space=" + String(repeating: "x", count: 9000)) == nil)

        for state in ["pause", "resume", "toggle"] {
            let command = parse("nook://recording?state=\(state)")
            precondition(command?.action == .recording(NookURLCommand.RecordingState(rawValue: state)!))
            precondition(command?.background == false && command?.ignored == [])
        }
        for suffix in ["", "?state=", "?state=stop", "?state=PAUSE", "?mode=pause"] {
            precondition(parse("nook://recording\(suffix)") == nil)
        }

        // Hostile or malformed
        for bad in [
            "nook://open", "nook://open?url=", "nook://open?url=file:///etc/passwd",
            "nook://open?url=javascript:alert(1)", "nook://open?url=data:text/html,hi",
            "nook://open?url=nook://open?url=https://a.com", "nook://open?url=https://",
            "nook://open?url=ftp://a.com", "nook://search", "nook://search?q=%20", "nook://space",
            "nook://quit", "nook://delete?url=https://a.com", "nook:///open?url=https://a.com",
            "https://open?url=https://a.com", "nook://open?url=" + String(repeating: "a", count: 9000),
        ] {
            precondition(parse(bad) == nil, bad)
        }
        // First duplicate wins; reuse only for exactly 1.
        precondition(parse("nook://open?url=https://a.com&url=file:///x")?.action == .open(URL(string: "https://a.com")!, reuse: false))
        precondition(parse("nook://open?url=https://a.com&reuse=true")?.action == .open(URL(string: "https://a.com")!, reuse: false))

        // Item commands: a UUID in any case; anything else rejects the command.
        let id = UUID(), folder = UUID(), space = UUID()
        let lower = id.uuidString.lowercased()
        precondition(parse("nook://close?id=\(id.uuidString)")?.action == .close(id))
        precondition(parse("nook://pin?id=\(lower)")?.action == .pin(id))
        precondition(parse("nook://UNPIN?id=\(lower)")?.action == .unpin(id))
        precondition(parse("nook://reload?id=%20\(lower)%20")?.action == .reload(id))
        precondition(parse("nook://select?id=\(lower)")?.action == .select(id))
        let move = parse("nook://move?id=\(lower)&folder=\(folder.uuidString.lowercased())")
        precondition(move?.action == .move(id, to: .folder(folder)) && move?.space == nil && move?.ignored == [])
        precondition(parse("nook://move?id=\(lower)&space=\(space)")?.action == .move(id, to: .space(space)))
        for command in ["reopen", "favorite", "unfavorite"] {
            let action: NookURLCommand.Action = command == "reopen" ? .reopen(id) : command == "favorite" ? .favorite(id) : .unfavorite(id)
            precondition(parse("nook://\(command)?id=\(lower)")?.action == action)
            for suffix in ["", "?id=", "?id=%20", "?id=bad", "?id=\(lower)x"] {
                precondition(parse("nook://\(command)\(suffix)") == nil)
            }
        }
        precondition(parse("nook://folder?name=%20Reading%20&space=\(space)")?.action == .folder(name: "Reading", space: space, parent: nil))
        precondition(parse("nook://folder?name=Reading&space=\(space)&parent=\(folder)")?.action == .folder(name: "Reading", space: space, parent: folder))
        precondition(parse("nook://rename?id=\(lower)&title=New%20title")?.action == .rename(id, title: "New title"))
        precondition(parse("nook://rename?id=\(lower)&title=")?.action == .rename(id, title: ""))
        precondition(parse("nook://rename?id=\(lower)&title=%20")?.action == .rename(id, title: " "))
        for command in ["open?url=https://a.com", "search?q=hello"] {
            precondition(parse("nook://\(command)")?.background == false)
            precondition(parse("nook://\(command)&background=0")?.background == false)
            let background = parse("nook://\(command)&space=Work&background=1")
            precondition(background?.background == true && background?.space == "Work" && background?.ignored == [])
            for flag in ["", "%20", "true", "2", "-1", String(repeating: "1", count: 9000)] {
                precondition(parse("nook://\(command)&background=\(flag)") == nil)
            }
        }
        for bad in [
            "nook://close", "nook://close?id=", "nook://pin?id=%20", "nook://unpin?id=work",
            "nook://reload?id=\(lower.dropLast())", "nook://select?id=\(lower)x", "nook://select?folder=\(lower)",
            "nook://move?id=\(lower)", "nook://move?id=\(lower)&folder=", "nook://move?id=\(lower)&folder=x",
            "nook://move?folder=\(lower)", "nook://close?id=\(lower)&space=",
            "nook://move?id=\(lower)&space=Work", "nook://move?id=\(lower)&space=",
            "nook://move?id=\(lower)&space=\(space)&folder=\(folder)",
            "nook://move?id=\(lower)&space=\(space)&folder=",
            "nook://move?space=\(space)", "nook://move?id=x&space=\(space)",
            "nook://open?background=1", "nook://open?url=file:///x&background=1", "nook://search?background=1",
            "nook://folder", "nook://folder?space=\(space)", "nook://folder?name=&space=\(space)",
            "nook://folder?name=%20%0A&space=\(space)", "nook://folder?name=F", "nook://folder?name=F&space=Work",
            "nook://folder?name=F&space=", "nook://folder?name=F&space=\(space)&parent=",
            "nook://folder?name=F&space=\(space)&parent=x",
            "nook://folder?space=\(space)&name=" + String(repeating: "x", count: 9000),
            "nook://rename", "nook://rename?title=x", "nook://rename?id=x&title=x", "nook://rename?id=\(lower)",
            "nook://rename?id=\(lower)&title=" + String(repeating: "x", count: 9000),
        ] {
            precondition(parse(bad) == nil, bad)
        }

        // Search URL
        let t = "https://www.google.com/search?q=%@"
        precondition(NookURLCommand.searchURL(for: "a&b c+d", template: t)?.absoluteString == "https://www.google.com/search?q=a%26b%20c%2Bd")
        precondition(NookURLCommand.searchURL(for: "x", template: "javascript:%@") == nil)

        // Space match
        let a = UUID(), b = UUID()
        let spaces = [(id: a, name: "Work"), (id: b, name: "Home")]
        precondition(NookURLCommand.match("work", in: spaces) == a)
        precondition(NookURLCommand.match(b.uuidString.lowercased(), in: spaces) == b)
        precondition(NookURLCommand.match("Wor", in: spaces) == nil)
        precondition(NookURLCommand.match(UUID().uuidString, in: spaces) == nil)

        // Same page
        func same(_ x: String, _ y: String) -> Bool { NookURLCommand.isSamePage(URL(string: x)!, URL(string: y)!) }
        precondition(same("https://A.com/p/#top", "https://a.com/p"))
        precondition(same("https://a.com", "https://a.com/"))
        precondition(!same("https://a.com/p?x=1", "https://a.com/p?x=2"))
        precondition(!same("http://a.com", "https://a.com"))
        print("NookURLCommandCheck passed")
    }
}
