import Cocoa
import ScreenCaptureKit
import CoreMedia
import ApplicationServices
import Darwin
import AVFoundation
import Vision

// All event and frame times use the host monotonic clock, in seconds.
func now() -> Double { CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) }
func emit(_ value: Any) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}
func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
func point(_ value: CFTypeRef?) -> CGPoint? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var result = CGPoint.zero
    guard AXValueGetValue(value as! AXValue, .cgPoint, &result) else { return nil }
    return result
}
func size(_ value: CFTypeRef?) -> CGSize? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var result = CGSize.zero
    guard AXValueGetValue(value as! AXValue, .cgSize, &result) else { return nil }
    return result
}
func tree(_ element: AXUIElement, _ path: [Int], _ depth: Int, _ rows: inout [[String: Any]]) {
    guard depth < 18, rows.count < 1800 else { return }
    var row: [String: Any] = ["path": path]
    for name in ["AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXValue", "AXIdentifier", "AXURL", "AXFocused", "AXMenuItemCmdChar", "AXMenuItemCmdVirtualKey", "AXMenuItemCmdModifiers"] {
        if let value = attr(element, name) {
            if let text = value as? String { row[name] = String(text.prefix(300)) }
            else if let number = value as? NSNumber { row[name] = number }
            else if CFGetTypeID(value) == CFURLGetTypeID() { row[name] = "\(value)" }
        }
    }
    if let p = point(attr(element, "AXPosition")), let s = size(attr(element, "AXSize")) {
        row["rect"] = [p.x, p.y, s.width, s.height]
    }
    rows.append(row)
    for (i, child) in (attr(element, "AXChildren") as? [AXUIElement] ?? []).enumerated() {
        tree(child, path + [i], depth + 1, &rows)
    }
}
func flags(_ names: [String]) -> CGEventFlags {
    var f: CGEventFlags = []
    for name in names {
        if name == "cmd" { f.insert(.maskCommand) }
        if name == "ctrl" { f.insert(.maskControl) }
        if name == "shift" { f.insert(.maskShift) }
        if name == "alt" { f.insert(.maskAlternate) }
    }
    return f
}
/// Keyboard events go to whichever app has focus, so they are posted only while the
/// benchmark's own browser holds it. A dropped event fails the trial instead of typing elsewhere.
func ownsKeyboard(_ action: [String: Any]) -> Bool {
    guard let owner = action["guard"] as? Int32 else { return true }
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == owner { return true }
    FileHandle.standardError.write(Data("keyboard event dropped: pid \(owner) lost focus\n".utf8))
    return false
}
func perform(_ action: [String: Any]) -> [String: Any] {
    let kind = action["kind"] as? String ?? "key"
    let stamp = now()
    var timing: [String: Any] = ["t": stamp, "action_start": stamp, "posted": true]
    if ["key", "text", "click", "move", "scroll"].contains(kind), !ownsKeyboard(action) {
        timing["posted"] = false
        return timing
    }
    if kind == "activate", let pid = action["pid"] as? Int32 {
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
    } else if kind == "key" {
        let key = CGKeyCode(action["code"] as? Int ?? 0)
        let f = flags(action["flags"] as? [String] ?? [])
        let modifiers: [(CGEventFlags, CGKeyCode)] = [(.maskControl,59),(.maskShift,56),(.maskAlternate,58),(.maskCommand,55)]
        var held: CGEventFlags = []
        // System shortcut monitors need complete modifier transitions, including
        // the key between them, rather than isolated modifier-release events.
        for (flag, code) in modifiers where f.contains(flag) {
            held.insert(flag)
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
            event.type = .flagsChanged; event.flags = held; event.post(tap: .cghidEventTap)
        }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)!
            event.flags = f
            // Synthetic events can start at zero. Stamp in the capture host clock.
            event.timestamp = UInt64(now() * 1_000_000_000)
            if down {
                timing["key_event_ns"] = event.timestamp
                timing["key_post_time"] = now()
            }
            event.post(tap: .cghidEventTap)
            if down { timing["key_post_return"] = now() }
        }
        for (flag, code) in modifiers.reversed() where f.contains(flag) {
            held.remove(flag)
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)!
            event.type = .flagsChanged; event.flags = held; event.post(tap: .cghidEventTap)
        }
    } else if kind == "text" {
        let chars = Array((action["text"] as? String ?? "").utf16)
        for offset in stride(from: 0, to: chars.count, by: 16) {
            let chunk = Array(chars[offset..<min(chars.count, offset+16)])
            if offset > 0, !ownsKeyboard(action) { timing["posted"] = false; break }
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)!
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event.post(tap: .cghidEventTap)
            }
            usleep(10000)
        }
    } else if kind == "click" || kind == "move" {
        let p = CGPoint(x: action["x"] as? Double ?? 0, y: action["y"] as? Double ?? 0)
        let right = action["right"] as? Bool ?? false
        let types: [CGEventType] = kind == "move" ? [.mouseMoved] : right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]
        for type in types {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p,
                    mouseButton: right ? .right : .left)?.post(tap: .cghidEventTap)
        }
    } else if kind == "scroll" {
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                wheel1: Int32(action["dy"] as? Int ?? -24), wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
    }
    return timing
}

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "window.capture")
    var frames: [[String: Any]] = []
    var last: [UInt8]?
    var lastFull: [UInt8]?
    var crop = CGRect.zero
    var captureRect = CGRect.zero
    var windowRect = CGRect.zero
    var regionRects: [(String, CGRect)] = []
    var windowID: CGWindowID?
    var attribute = false
    var regionByPixel: [UInt8] = []
    var strips: [CGImage] = []
    var lastStrip = -Double.infinity
    var streamError: String?
    var finalImage: CGImage?
    var firstImage: CGImage?
    var textFrames: [(Double, CGImage)] = []
    var inputCrop: CGRect?
    var inputAfter = Double.infinity
    var inputBefore = Double.infinity
    var previousInput: Data?
    let record: Bool
    let still: Bool
    let signatures: Bool

    init(record: Bool, still: Bool, signatures: Bool) {
        self.record = record
        self.still = still
        self.signatures = signatures
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.streamError = error.localizedDescription }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        let status = (attachments?.first?[.status] as? Int) ?? -1
        let t = CMTimeGetSeconds(sample.presentationTimeStamp)
        guard t.isFinite else { return }
        // Idle buffers can carry no pixels. Retain their timestamps as repeated presentation samples.
        guard status == SCFrameStatus.complete.rawValue else {
            if status == SCFrameStatus.idle.rawValue { frames.append(["t": t, "idle": true]) }
            return
        }
        guard let buffer = sample.imageBuffer else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = Int(crop.width), height = Int(crop.height)
        let bufferBounds = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        guard !crop.isEmpty, bufferBounds.contains(crop) else { return }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self).advanced(by: Int(crop.minY) * stride + Int(crop.minX) * 4)
        var pixels: [UInt8] = []
        var red = 0, blue = 0, green = 0, changed = 0, colorSamples = 0
        for y in 0..<100 {
            for x in 0..<160 {
                let index = min(height - 1, y * height / 100) * stride + min(width - 1, x * width / 160) * 4
                let b = ptr[index], g = ptr[index + 1], r = ptr[index + 2]
                let j = pixels.count
                pixels.append(contentsOf: [r, g, b])
                if let last, abs(Int(r) - Int(last[j])) + abs(Int(g) - Int(last[j+1])) + abs(Int(b) - Int(last[j+2])) > 30 { changed += 1 }
                let screenPoint = CGPoint(x:captureRect.minX+Double(x)*captureRect.width/160,
                                          y:captureRect.minY+Double(y)*captureRect.height/100)
                guard !attribute || windowRect.contains(screenPoint) else { continue }
                colorSamples += 1
                if Double(r) > Double(g)*1.5 && Double(r) > Double(b)*1.3 { red += 1 }
                if Double(b) > Double(r)*1.3 && Double(b) > Double(g)*1.2 { blue += 1 }
                if Double(g) > Double(r)*1.5 && Double(g) > Double(b)*1.2 { green += 1 }
            }
        }
        var frame: [String: Any] = ["t": t, "changed": Double(changed)/16000, "red": Double(red)/Double(max(1,colorSamples)),
                                  "blue": Double(blue)/Double(max(1,colorSamples)), "green": Double(green)/Double(max(1,colorSamples)),
                                  "delivery_lag_ms": (now()-t)*1000]
        if attribute {
            let scaleX = Double(width) / captureRect.width, scaleY = Double(height) / captureRect.height
            let regions = regionRects.map { name, rect in
                (name, rect.offsetBy(dx: -captureRect.minX, dy: -captureRect.minY).applying(CGAffineTransform(scaleX: scaleX, y: scaleY)))
            }
            var current = [UInt8](repeating: 0, count: width * height * 3)
            var counts = [Int](repeating: 0, count: regions.count + 1)
            var minX = [Int](repeating: width, count: counts.count), minY = [Int](repeating: height, count: counts.count)
            var maxX = [Int](repeating: -1, count: counts.count), maxY = [Int](repeating: -1, count: counts.count)
            var windowChanged = 0
            for y in 0..<height { for x in 0..<width {
                let src = y * stride + x * 4, dst = (y * width + x) * 3
                current[dst] = ptr[src + 2]; current[dst+1] = ptr[src+1]; current[dst+2] = ptr[src]
                guard let previous = lastFull,
                      abs(Int(current[dst])-Int(previous[dst])) + abs(Int(current[dst+1])-Int(previous[dst+1])) + abs(Int(current[dst+2])-Int(previous[dst+2])) > 30 else { continue }
                let region = Int(regionByPixel[y*width+x])
                counts[region] += 1
                minX[region] = min(minX[region],x); minY[region] = min(minY[region],y)
                maxX[region] = max(maxX[region],x); maxY[region] = max(maxY[region],y)
                let screenPoint = CGPoint(x: captureRect.minX + Double(x)/scaleX, y: captureRect.minY + Double(y)/scaleY)
                if windowRect.contains(screenPoint) { windowChanged += 1 }
            }}
            let windowPixels = windowRect.width * scaleX * windowRect.height * scaleY
            frame["window_changed_fraction"] = Double(windowChanged) / windowPixels
            frame["regions"] = counts.indices.compactMap { i -> [String: Any]? in
                guard counts[i] > 0 else { return nil }
                let box = CGRect(x:minX[i],y:minY[i],width:maxX[i]-minX[i]+1,height:maxY[i]-minY[i]+1)
                return ["region": i < regions.count ? regions[i].0 : "outside", "pixels": counts[i],
                        "window_pixel_fraction": Double(counts[i])/windowPixels,
                        "rect": [captureRect.minX + box.minX/scaleX, captureRect.minY + box.minY/scaleY, box.width/scaleX, box.height/scaleY]]
            }
            lastFull = current
            if let windowID, let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
               let bounds = rows.first?[kCGWindowBounds as String] {
                frame["window_frame"] = bounds
            }
            frame["analysis_ms"] = (now()-t)*1000 - (frame["delivery_lag_ms"] as! Double)
        }
        if signatures { frame["pixels"] = Data(pixels).base64EncodedString() }
        frames.append(frame)
        last = pixels
        if let inputCrop, bufferBounds.contains(inputCrop), inputAfter <= t, t < inputBefore, textFrames.count < 60,
           let image = copyImage(base, stride: stride, rect: inputCrop),
           let pixels = image.dataProvider?.data as Data?, pixels != previousInput {
            textFrames.append((t, image))
            previousInput = pixels
        }
        if record, let image = copyImage(base, stride: stride, rect: crop) {
            finalImage = image
            if firstImage == nil { firstImage = image }
            guard !still, t - lastStrip >= 0.16, strips.count < 32 else { return }
            let w = 480, h = max(1, Int(Double(height) * 480 / Double(width)))
            let small = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            small.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            strips.append(small.makeImage()!)
            lastStrip = t
        }
    }
    func copyImage(_ base: UnsafeMutableRawPointer, stride: Int, rect: CGRect) -> CGImage? {
        let width = Int(rect.width), height = Int(rect.height)
        let rowBytes = width * 4
        var data = Data(count: rowBytes * height)
        data.withUnsafeMutableBytes { buffer in
            guard let destination = buffer.baseAddress else { return }
            for y in 0..<height {
                let source = base.advanced(by: (Int(rect.minY) + y)*stride + Int(rect.minX)*4)
                memcpy(destination.advanced(by: y * rowBytes), source, rowBytes)
            }
        }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: rowBytes, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
    func png(_ image: CGImage) -> String? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.base64EncodedString()
    }
    func artifacts() -> [String: String] {
        var output: [String: String] = [:]
        if let finalImage { output["last.png"] = png(finalImage) }
        if still { return output }
        if let firstImage { output["first.png"] = png(firstImage) }
        guard let first = strips.first else { return output }
        if let finalImage {
            let tail = CGContext(data: nil, width: first.width, height: first.height, bitsPerComponent: 8,
                                 bytesPerRow: first.width*4, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            tail.draw(finalImage, in: CGRect(x: 0, y: 0, width: first.width, height: first.height))
            strips.append(tail.makeImage()!)
        }
        let columns = 4, rows = (strips.count + columns - 1)/columns
        let context = CGContext(data: nil, width: first.width * columns, height: first.height * rows,
                                bitsPerComponent: 8, bytesPerRow: first.width * columns * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (i, image) in strips.enumerated() {
            context.draw(image, in: CGRect(x: i%columns * first.width, y: (rows-1-i/columns)*first.height,
                                           width: first.width, height: first.height))
        }
        output["strip.png"] = png(context.makeImage()!)
        return output
    }
}

func recognize(_ path: String) throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let spec = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let needle = spec["needle"] as? String, !needle.isEmpty,
          let frames = spec["frames"] as? [[String: Any]] else {
        throw NSError(domain: "invalid input evidence", code: 16)
    }
    for frame in frames {
        guard let timestamp = frame["t"] as? Double, timestamp.isFinite,
              let encoded = frame["png"] as? String,
              let data = Data(base64Encoded: encoded),
              let bitmap = NSBitmapImageRep(data: data), let image = bitmap.cgImage else {
            throw NSError(domain: "cannot decode cropped input frame", code: 16)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        request.customWords = [needle]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined().lowercased().filter { !$0.isWhitespace }
        if text.contains(needle.lowercased()) {
            emit(["first_text_frame": timestamp]); return
        }
    }
    emit(["first_text_frame": NSNull()])
}

func transparentContainer(windowID: CGWindowID, pid: pid_t) async throws -> Bool {
    guard #available(macOS 14.0, *),
          let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
          ["com.apple.dock", "com.apple.notificationcenterui"].contains(bundle) else { return false }
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let window = content.windows.first(where: { $0.windowID == windowID && $0.owningApplication?.processID == pid }),
          window.title?.isEmpty != false,
          content.displays.contains(where: {
              let d = $0.frame, w = window.frame
              return abs(d.minX - w.minX) <= 2 && abs(d.minY - w.minY) <= 2
                  && abs(d.width - w.width) <= 2 && abs(d.height - w.height) <= 2
          }) else { return false }
    let config = SCStreamConfiguration()
    config.width = Int(window.frame.width * 2)
    config.height = Int(window.frame.height * 2)
    config.shouldBeOpaque = false
    config.ignoreShadowsSingleWindow = true
    config.showsCursor = false
    let image = try await SCScreenshotManager.captureImage(
        contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
    // The owner and bounds alone do not establish transparency. Treat any ink
    // or an unavailable alpha channel as a possible prompt.
    guard image.alphaInfo != .none, image.alphaInfo != .noneSkipFirst, image.alphaInfo != .noneSkipLast,
          let alpha = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width*4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
          let bytes = alpha.data else { return false }
    let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    alpha.clear(rect)
    alpha.draw(image, in: rect)
    let rgba = UnsafeRawBufferPointer(start: bytes, count: alpha.bytesPerRow * image.height)
    return stride(from: 3, to: rgba.count, by: 4).allSatisfy { rgba[$0] == 0 }
}

@main struct Main {
    static func specData(_ path: String) throws -> Data {
        if path == "-" { return FileHandle.standardInput.readDataToEndOfFile() }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    static func main() async {
        do {
            let a = Array(CommandLine.arguments.dropFirst())
            guard let command = a.first else { throw NSError(domain: "missing command", code: 1) }
            if command == "permissions" {
                let session = CGSessionCopyCurrentDictionary() as? [String: Any]
                let active = session?[kCGSessionOnConsoleKey as String] as? Bool == true
                    && session?[kCGSessionLoginDoneKey as String] as? Bool == true
                let unlocked = active && session?["CGSSessionScreenIsLocked"] as? Bool != true
                emit(["screen": CGPreflightScreenCaptureAccess(), "accessibility": AXIsProcessTrusted(),
                      "post_events": CGPreflightPostEventAccess(), "unlocked": unlocked,
                      "console_session": active, "capture_protocol": 2]); return
            }
            if command == "ocr" { try recognize(a[1]); return }
            if command == "transparent-container" {
                let transparent = try await transparentContainer(windowID: UInt32(a[1])!, pid: Int32(a[2])!)
                emit(["transparent": transparent]); return
            }
            if command == "front" {
                emit(["pid": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1]); return
            }
            if command == "occlude" {
                let application = NSApplication.shared
                application.setActivationPolicy(.regular)
                let screenHeight = NSScreen.screens[0].frame.height
                let x = Double(a[1])!, y = Double(a[2])!, w = Double(a[3])!, h = Double(a[4])!
                let window = NSWindow(contentRect: CGRect(x: x, y: screenHeight-y-h, width: w, height: h),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.backgroundColor = NSColor(calibratedWhite: 0.4, alpha: 1)
                window.makeKeyAndOrderFront(nil)
                application.activate(ignoringOtherApps: true)
                application.run(); return
            }
            if command == "windows" {
                let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                emit(list); return
            }
            if command == "ax" || command == "ax-focused" {
                var rows: [[String: Any]] = []
                let application = AXUIElementCreateApplication(Int32(a[1])!)
                var root = application
                if command == "ax-focused" {
                    guard let focused = attr(application,"AXFocusedWindow"), CFGetTypeID(focused) == AXUIElementGetTypeID() else {
                        throw NSError(domain:"no focused browser window",code:15)
                    }
                    root = focused as! AXUIElement
                }
                if attr(root, "AXRole") != nil { tree(root, [], 0, &rows) }
                emit(rows); return
            }
            if command == "press" {
                var element = AXUIElementCreateApplication(Int32(a[1])!)
                for index in a[2].split(separator: ",").compactMap({ Int($0) }) {
                    guard let children = attr(element, "AXChildren") as? [AXUIElement], index < children.count else {
                        throw NSError(domain: "AX control no longer exists", code: 10)
                    }
                    element = children[index]
                }
                guard AXUIElementPerformAction(element, "AXPress" as CFString) == .success else {
                    throw NSError(domain: "AX control rejected press", code: 11)
                }
                usleep(100000); emit(["ok":true]); return
            }
            if command == "close-window" {
                let application = AXUIElementCreateApplication(Int32(a[1])!)
                let target = a.dropFirst(2).compactMap(Double.init)
                let windows = attr(application, "AXWindows") as? [AXUIElement] ?? []
                guard let window = windows.first(where: {
                    guard let p = point(attr($0,"AXPosition")), let s = size(attr($0,"AXSize")) else { return false }
                    return zip([p.x,p.y,s.width,s.height],target).allSatisfy { abs($0-$1) < 3 }
                }), let button = attr(window,"AXCloseButton"), CFGetTypeID(button) == AXUIElementGetTypeID(),
                AXUIElementPerformAction(button as! AXUIElement,"AXPress" as CFString) == .success else {
                    throw NSError(domain:"identified window did not accept close",code:14)
                }
                emit(["ok":true]); return
            }
            if command == "resize" {
                let app = AXUIElementCreateApplication(Int32(a[1])!)
                guard let window = (attr(app, "AXWindows") as? [AXUIElement])?.first else { throw NSError(domain: "no AX window", code: 2) }
                var p = CGPoint(x: a.count > 2 ? Double(a[2])! : 40, y: a.count > 3 ? Double(a[3])! : 60)
                var s = CGSize(width: a.count > 4 ? Double(a[4])! : 1200, height: a.count > 5 ? Double(a[5])! : 760)
                AXUIElementSetAttributeValue(window, "AXPosition" as CFString, AXValueCreate(.cgPoint, &p)!)
                AXUIElementSetAttributeValue(window, "AXSize" as CFString, AXValueCreate(.cgSize, &s)!)
                emit(["ok": true]); return
            }
            if command == "action" {
                let actions = try JSONSerialization.jsonObject(with: specData(a[1])) as! [[String: Any]]
                let times = actions.map { action in
                    let t = perform(action)
                    usleep(50000)
                    return t
                }
                emit(times); return
            }
            if command == "launch" {
                let spec = try JSONSerialization.jsonObject(with: specData(a[1])) as! [String: Any]
                let arguments = spec["args"] as! [String]
                let application = spec["app"] as! String
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.arguments = Array(arguments.dropFirst())
                configuration.createsNewApplicationInstance = true
                configuration.activates = true
                let start = now()
                let app = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: application), configuration: configuration)
                emit(["pid":app.processIdentifier,"start":start]); return
            }
            if command == "footprint" {
                var values: [String: Any] = [:]
                var base = mach_timebase_info_data_t()
                mach_timebase_info(&base)
                for id in a.dropFirst() {
                    var info = rusage_info_v4()
                    let result = withUnsafeMutablePointer(to: &info) { pointer in
                        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(Int32(id)!, RUSAGE_INFO_V4, $0) }
                    }
                    values[id] = result == 0 ? ["physical_bytes": info.ri_phys_footprint, "resident_bytes": info.ri_resident_size,
                                              "cpu_ns": Double(info.ri_user_time + info.ri_system_time) * Double(base.numer) / Double(base.denom)] : ["error": errno]
                }
                emit(values); return
            }
            if command == "video" {
                let url = URL(fileURLWithPath: a[1])
                try? FileManager.default.removeItem(at: url)
                let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: 640, AVVideoHeightKey: 360])
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360])
                writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
                for i in 0..<60 {
                    while !input.isReadyForMoreMediaData { usleep(1000) }
                    var pixel: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixel)
                    let buffer = pixel!
                    CVPixelBufferLockBaseAddress(buffer, [])
                    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
                    let stride = CVPixelBufferGetBytesPerRow(buffer)
                    for y in 0..<360 { for x in 0..<640 {
                        let index = y*stride+x*4
                        base[index] = UInt8((x+i*9)%256); base[index+1] = UInt8((y+i*3)%256)
                        base[index+2] = UInt8((x+y+i*7)%256); base[index+3] = 255
                    }}
                    CVPixelBufferUnlockBaseAddress(buffer, [])
                    guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(i), timescale: 30)) else {
                        throw writer.error ?? NSError(domain: "video append failed", code: 8)
                    }
                }
                input.markAsFinished(); await writer.finishWriting()
                guard writer.status == .completed else { throw writer.error ?? NSError(domain: "video writer failed", code: 9) }
                emit(["ok": true]); return
            }
            guard command == "capture" else { throw NSError(domain: "unknown command", code: 3) }
            let spec = try JSONSerialization.jsonObject(with: specData(a[1])) as! [String: Any]
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            let pid = spec["pid"] as? Int32
            let requestedWindow = spec["window_id"] as? UInt32
            let window = content.windows.first(where: { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 300 && $0.frame.height > 300 && (requestedWindow == nil || $0.windowID == requestedWindow) })
            // A background browser can disappear from the shareable window list.
            // Activation captures retain its verified foreground display region.
            let region = spec["region"] as? [Double]
            let frame = region.flatMap { $0.count == 4 ? CGRect(x:$0[0],y:$0[1],width:$0[2],height:$0[3]) : nil } ?? window?.frame
            guard let display = content.displays.first(where: { frame == nil || $0.frame.intersects(frame!) }) else {
                throw NSError(domain: "no display available", code: 4)
            }
            if pid != nil && frame == nil { throw NSError(domain: "no browser window for pid \(pid!)", code: 4) }
            // Capture the visible display region so app activation and occlusion are observable too.
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            let rect = (spec["full_display"] as? Bool ?? false) ? display.frame : (frame?.intersection(display.frame) ?? display.frame)
            // Use a full-display buffer so the crop is explicit in pixel coordinates.
            let backing = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID })?.backingScaleFactor ?? 1
            let scale = (spec["native_resolution"] as? Bool ?? false) ? backing : 1
            config.width = Int(display.frame.width*scale); config.height = Int(display.frame.height*scale)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.queueDepth = 8
            config.showsCursor = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB
            let capture = Capture(record: spec["record"] as? Bool ?? false,
                                  still: spec["still"] as? Bool ?? false,
                                  signatures: spec["signatures"] as? Bool ?? false)
            capture.crop = CGRect(x: (rect.minX-display.frame.minX)*scale, y: (rect.minY-display.frame.minY)*scale,
                                  width: rect.width*scale, height: rect.height*scale).integral
            capture.captureRect = rect
            if let r = spec["input_region"] as? [Double], r.count == 4 {
                let input = CGRect(x:r[0], y:r[1], width:r[2], height:r[3]).intersection(rect)
                if !input.isEmpty {
                    capture.inputCrop = CGRect(x: (input.minX-display.frame.minX)*scale,
                                               y: (input.minY-display.frame.minY)*scale,
                                               width: input.width*scale, height: input.height*scale).integral
                }
            }
            capture.windowID = requestedWindow
            let wr = (spec["window_rect"] as? [Double]) ?? [rect.minX, rect.minY, rect.width, rect.height]
            capture.windowRect = CGRect(x: wr[0], y: wr[1], width: wr[2], height: wr[3])
            capture.attribute = spec["attribute"] as? Bool ?? false
            capture.regionRects = (spec["regions"] as? [[String: Any]] ?? []).compactMap { item in
                guard let name = item["name"] as? String, let r = item["rect"] as? [Double], r.count == 4 else { return nil }
                return (name, CGRect(x:r[0],y:r[1],width:r[2],height:r[3]))
            }
            if capture.attribute {
                let width = Int(capture.crop.width), height = Int(capture.crop.height)
                capture.regionByPixel = [UInt8](repeating: UInt8(capture.regionRects.count), count: width*height)
                for y in 0..<height { for x in 0..<width {
                    let point = CGPoint(x:rect.minX+Double(x)/scale,y:rect.minY+Double(y)/scale)
                    if let index = capture.regionRects.firstIndex(where: { $0.1.contains(point) }) {
                        capture.regionByPixel[y*width+x] = UInt8(index)
                    }
                }}
            }
            let stream = SCStream(filter: filter, configuration: config, delegate: capture)
            try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: capture.queue)
            try await stream.startCapture()
            let start = now()
            let actions = spec["actions"] as? [[String: Any]] ?? []
            if let probe = actions.first(where: { $0["kind"] as? String == "text" }) {
                capture.queue.sync {
                    capture.inputAfter = start + (probe["at"] as? Double ?? 0.55)
                    capture.inputBefore = start + (spec["input_until"] as? Double ?? 1.3)
                }
            }
            if let ready = spec["ready_file"] as? String { try Data("\(start)".utf8).write(to: URL(fileURLWithPath: ready)) }
            var events: [[String: Any]] = []
            for action in actions {
                let due = start + (action["at"] as? Double ?? 0.5)
                let delay = max(0, due - now())
                try await Task.sleep(nanoseconds: UInt64(delay * 1e9))
                var event: [String: Any] = ["action": action]
                if ["activate", "key"].contains(action["kind"] as? String ?? ""), let pointer = CGEvent(source: nil)?.location {
                    event["pointer_before"] = [pointer.x,pointer.y]
                }
                event.merge(perform(action)) { _, new in new }
                events.append(event)
            }
            let end = start + (spec["duration"] as? Double ?? 2.0)
            try await Task.sleep(nanoseconds: UInt64(max(0, end - now()) * 1e9))
            do { try await stream.stopCapture() }
            catch { capture.queue.sync { capture.streamError = error.localizedDescription } }
            capture.queue.sync {}
            let endStamp = now()
            let inputFrames: [[String: Any]] = capture.textFrames.compactMap { t, image in
                guard let png = capture.png(image) else { return nil }
                return ["t": t, "png": png]
            }
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            emit(["clock": ["host_seconds": now(), "wall_seconds": Date().timeIntervalSince1970,
                             "mach_absolute_ticks": mach_absolute_time(), "mach_continuous_ticks": mach_continuous_time(),
                             "mach_timebase_numer": timebase.numer, "mach_timebase_denom": timebase.denom],
                  "window_rect": wr, "window_id": requestedWindow as Any? ?? NSNull(),
                  "display_rect": [display.frame.minX,display.frame.minY,display.frame.width,display.frame.height],
                  "buffer_crop": [capture.crop.minX,capture.crop.minY,capture.crop.width,capture.crop.height],
                  "start": start, "end": endStamp, "events": events, "frames": capture.frames,
                  "capture_end": endStamp, "artifacts": capture.artifacts(), "input_frames": inputFrames,
                  "rect": [rect.minX, rect.minY, rect.width, rect.height],
                  "capture_error": capture.streamError as Any? ?? NSNull()])
        } catch {
            emit(["error": error.localizedDescription]); exit(1)
        }
    }
}
