import AppKit
import WebKit

/// Real input for the agent's browser tools: mouse and key events made as `NSEvent`s and handed
/// straight to one tab's web view. WebKit treats them as the user's own input, so the page sees
/// trusted events (`isTrusted`), menus open and focus moves as for a person. The events never go
/// through the window server: the user's cursor doesn't move, the app isn't activated, and a tab
/// in the background (not on screen in any window) works too, from `AgentStage`'s offscreen
/// window.
@MainActor
enum AgentInput {
    private static var eventNumber = 1_000

    /// A point in the page's viewport (CSS pixels, from the top left) as a point in the web
    /// view's window.
    static func windowPoint(css: CGPoint, in webView: WKWebView) -> NSPoint {
        let scale = webView.pageZoom * webView.magnification
        let x = css.x * scale
        let y = css.y * scale
        let local = NSPoint(x: x, y: webView.isFlipped ? y : webView.bounds.height - y)
        return webView.convert(local, to: nil)
    }

    /// Moves the (page's idea of the) pointer to `css`, then presses and releases the button.
    static func click(css: CGPoint, in webView: WKWebView, clickCount: Int = 1, modifiers: NSEvent.ModifierFlags = []) {
        guard let window = webView.window else { return }
        let browserView = webView as? BrowserWebView
        browserView?.deliveringAgentInput = true
        defer { browserView?.deliveringAgentInput = false }
        let location = windowPoint(css: css, in: webView)
        let now = ProcessInfo.processInfo.systemUptime
        if let move = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: modifiers, timestamp: now,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: next(), clickCount: 0, pressure: 0) {
            webView.mouseMoved(with: move)
        }
        for count in 1...max(1, clickCount) {
            for (type, pressure) in [(NSEvent.EventType.leftMouseDown, Float(1)), (.leftMouseUp, Float(0))] {
                guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers,
                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: next(),
                                                     clickCount: count, pressure: pressure) else { continue }
                if type == .leftMouseDown { webView.mouseDown(with: event) } else { webView.mouseUp(with: event) }
            }
        }
    }

    /// Text into the focused field, as typing (or the input method) inserts it.
    static func insert(_ text: String, in webView: WKWebView) {
        webView.insertText(text)
    }

    /// A named key ("Enter", "Tab", "Escape", "ArrowDown", "a") with modifiers ("cmd", "shift",
    /// "alt", "ctrl"). Returns false for a key it doesn't know.
    @discardableResult
    static func press(_ key: String, modifiers: [String] = [], in webView: WKWebView) -> Bool {
        guard let window = webView.window, let (code, characters) = keyInfo(key) else { return false }
        let browserView = webView as? BrowserWebView
        browserView?.deliveringAgentInput = true
        defer { browserView?.deliveringAgentInput = false }
        var flags: NSEvent.ModifierFlags = []
        for m in modifiers.map({ $0.lowercased() }) {
            switch m {
            case "cmd", "command", "meta": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "alt", "option": flags.insert(.option)
            case "ctrl", "control": flags.insert(.control)
            default: break
            }
        }
        let shifted = flags.contains(.shift) && characters.count == 1 && characters.first?.isLetter == true
        let chars = shifted ? characters.uppercased() : characters
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: chars,
                                               charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { continue }
            if type == .keyDown { webView.keyDown(with: event) } else { webView.keyUp(with: event) }
        }
        return true
    }

    /// The DOM key name a key press produces, for checking what Return would do.
    static func domKey(_ key: String) -> String {
        switch key.lowercased() {
        case "enter", "return": return "Enter"
        case "space": return " "
        default: return key
        }
    }

    private static func next() -> Int {
        eventNumber += 1
        return eventNumber
    }

    /// The macOS virtual key code and the characters for a key name.
    static func keyInfo(_ key: String) -> (UInt16, String)? {
        func scalar(_ value: Int) -> String { String(UnicodeScalar(value).map(Character.init) ?? " ") }
        switch key.lowercased() {
        case "enter", "return": return (36, "\r")
        case "tab": return (48, "\t")
        case "escape", "esc": return (53, "\u{1b}")
        case "backspace": return (51, "\u{7f}")
        case "delete": return (117, scalar(NSDeleteFunctionKey))
        case "space", " ": return (49, " ")
        case "arrowup", "up": return (126, scalar(NSUpArrowFunctionKey))
        case "arrowdown", "down": return (125, scalar(NSDownArrowFunctionKey))
        case "arrowleft", "left": return (123, scalar(NSLeftArrowFunctionKey))
        case "arrowright", "right": return (124, scalar(NSRightArrowFunctionKey))
        case "home": return (115, scalar(NSHomeFunctionKey))
        case "end": return (119, scalar(NSEndFunctionKey))
        case "pageup": return (116, scalar(NSPageUpFunctionKey))
        case "pagedown": return (121, scalar(NSPageDownFunctionKey))
        default: break
        }
        guard key.count == 1, let c = key.lowercased().first else { return nil }
        let letters: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
            "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
            ".": 47, "`": 50,
        ]
        guard let code = letters[c] else { return nil }
        return (code, String(c))
    }

    /// The tab as a PNG data URL, one image pixel per CSS pixel of the viewport (so `click_at`
    /// takes the image's coordinates), at most `maxWidth` wide.
    static func screenshot(_ webView: WKWebView, maxWidth: CGFloat = 1600) async throws -> (dataURL: String, size: CGSize) {
        let configuration = WKSnapshotConfiguration()
        let scale = webView.pageZoom * webView.magnification
        let cssWidth = webView.bounds.width / max(scale, 0.01)
        configuration.snapshotWidth = NSNumber(value: Double(min(cssWidth, maxWidth)))
        let image = try await webView.takeSnapshot(configuration: configuration)
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw AgentToolError("The tab couldn't be captured.")
        }
        let width = Int(image.size.width.rounded()), height = Int(image.size.height.rounded())
        guard width > 0, height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else {
            throw AgentToolError("The tab couldn't be captured.")
        }
        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSGraphicsContext.current?.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw AgentToolError("The tab couldn't be captured.")
        }
        return ("data:image/png;base64," + png.base64EncodedString(), CGSize(width: width, height: height))
    }
}

/// Offscreen windows for agent tabs that aren't on screen. A web view needs a window to lay out,
/// draw (for screenshots) and take events; a background tab has none, so the agent's tools put
/// it in one of these, far off every screen, before acting. When the user shows the tab, its
/// window takes the web view back. The windows are borderless, never key, and left out of the
/// Window menu and window cycling.
@MainActor
final class AgentStage {
    private var windows: [ObjectIdentifier: NSWindow] = [:]
    /// The page size agent tabs get offscreen (the last browser window's web area, roughly).
    var size = NSSize(width: 1280, height: 800)

    /// Makes sure `webView` is in a window. Returns false if it can't be (no web view).
    func host(_ webView: WKWebView) {
        if webView.window != nil { return }
        let key = ObjectIdentifier(webView)
        let window = windows[key] ?? {
            let w = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                             styleMask: [.borderless], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.isExcludedFromWindowsMenu = true
            w.collectionBehavior = [.ignoresCycle, .transient, .stationary]
            w.ignoresMouseEvents = true
            w.hasShadow = false
            w.animationBehavior = .none
            windows[key] = w
            return w
        }()
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        window.setContentSize(size)
        window.contentView = container
        window.orderBack(nil)
        sweep()
    }

    /// Closes stage windows whose web view went elsewhere (shown in a tab) or away.
    func sweep() {
        for (key, window) in windows {
            let holding = window.contentView?.subviews.contains { $0 is WKWebView } == true
            if !holding {
                window.contentView = nil
                window.orderOut(nil)
                windows[key] = nil
            }
        }
    }

    /// Releases a web view's stage window (its tab closed or was unloaded).
    func release(_ webView: WKWebView) {
        let key = ObjectIdentifier(webView)
        guard let window = windows.removeValue(forKey: key) else { return }
        if webView.window === window { webView.removeFromSuperview() }
        window.contentView = nil
        window.orderOut(nil)
    }

    var count: Int { windows.count }
}

struct AgentToolError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
