// Licensed under GPL-3.0. See LICENSE.
// swiftc Packages/NookTweaks/Sources/NookTweaks/YouTubeShortsURL.swift Packages/NookTweaks/Checks/YouTubeShortsURLCheck.swift -o /tmp/shorts-check && /tmp/shorts-check
import Foundation

@main struct YouTubeShortsURLCheck {
    static func main() {
        for host in ["youtube.com", "www.youtube.com", "m.youtube.com", "WWW.YouTube.com"] {
            let result = youTubeShortsWatchURL(URL(string: "http://\(host)/shorts/Ab_12-?si=share&t=3&v=wrong#time")!)!
            precondition(result.absoluteString == "https://www.youtube.com/watch?v=Ab_12-&si=share&t=3#time")
        }
        precondition(youTubeShortsWatchURL(URL(string: "https://youtube.com/shorts/id/")!)?.path == "/watch")
        for raw in ["https://youtube.com/shorts/", "https://youtube.com/shorts/id/extra", "https://youtube.com/watch?v=id", "https://youtube.com.evil.com/shorts/id", "nook://youtube.com/shorts/id", "https://youtube.com/shorts/a%2Fb"] {
            precondition(youTubeShortsWatchURL(URL(string: raw)!) == nil, raw)
        }
        print("YouTubeShortsURLCheck passed")
    }
}
