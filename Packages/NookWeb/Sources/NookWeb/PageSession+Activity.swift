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
        // Live collections: asking them costs nothing when the document has no media, where a
        // selector query walks the whole page every time.
        const audio = document.getElementsByTagName('audio');
        const video = document.getElementsByTagName('video');
        function elementPlaying(list) {
            for (const element of list) {
                if (!element.paused && !element.ended && element.readyState >= 2) return true;
            }
            return false;
        }
        function report(forceStopped = false) {
            const playing = !forceStopped && (elementPlaying(audio) || elementPlaying(video) ||
                navigator.mediaSession?.playbackState === 'playing');
            // Only a playing frame needs to keep saying so; a silent one is already counted as stopped.
            if (playing !== last || (playing && Date.now() - lastReport >= 10000)) {
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
        // A frame with nothing playing is checked less often, so idle tabs wake less.
        (function poll() {
            report();
            setTimeout(poll, last ? 1000 : 5000);
        })();
    })();
    """
}
