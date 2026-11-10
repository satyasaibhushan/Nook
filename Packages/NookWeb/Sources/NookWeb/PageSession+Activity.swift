// Licensed under GPL-3.0. See LICENSE.

import Foundation
import WebKit

extension PageSession {
    static let activityMediaHandler = "nookActivityMedia"

    /// Separate from the audio indicator: muted video and Media Session playback count too.
    public var activityMediaPlaying: Bool {
        activityMediaFrames.values.contains { $0.playing && Date().timeIntervalSince($0.updated) < 25 }
    }

    func configureActivityMedia(in webView: WKWebView) {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: Self.activityMediaHandler)
        controller.add(self, name: Self.activityMediaHandler)
        guard !controller.userScripts.contains(where: { $0.source.hasPrefix("// Nook Activity Media") }) else { return }
        controller.addUserScript(WKUserScript(source: Self.activityMediaScript,
            injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }

    func receiveActivityMedia(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let token = body["document"] as? String,
              let playing = body["playing"] as? Bool else { return }
        if message.frameInfo.isMainFrame, activityMediaDocument != token {
            activityMediaFrames.removeAll()
            activityMediaDocument = token
        }
        activityMediaFrames = activityMediaFrames.filter { Date().timeIntervalSince($0.value.updated) < 25 }
        activityMediaFrames[token] = (playing, Date())
    }

    private static let activityMediaScript = """
    // Nook Activity Media
    (() => {
        if (window.__nookActivityMedia) return;
        window.__nookActivityMedia = true;
        const token = crypto.randomUUID();
        let last = null;
        let lastReport = 0;
        function report(forceStopped = false) {
            const playing = !forceStopped && (
                Array.from(document.querySelectorAll('audio, video')).some(element =>
                    !element.paused && !element.ended && element.readyState >= 2) ||
                navigator.mediaSession?.playbackState === 'playing');
            if (playing !== last || Date.now() - lastReport >= 10000) {
                last = playing;
                lastReport = Date.now();
                window.webkit?.messageHandlers?.nookActivityMedia?.postMessage({document: token, playing});
            }
        }
        ['playing', 'pause', 'ended', 'emptied', 'waiting', 'loadeddata'].forEach(type =>
            document.addEventListener(type, () => report(), true));
        window.addEventListener('pagehide', () => report(true));
        window.addEventListener('pageshow', () => report());
        // Media Session has no playbackstatechange event; also expire removed frames natively.
        setInterval(report, 1000);
        report();
    })();
    """
}
