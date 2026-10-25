import AppKit
import os

/// Where the user put a window: its frame and the display it was on. When that display goes away
/// (a monitor turned off or unplugged), macOS moves the window to a remaining display; when the
/// display comes back, the window goes back to where the user left it.
@MainActor
final class WindowHome {
    private weak var window: NSWindow?
    /// The window's frame relative to its display's origin, so it survives the displays being
    /// rearranged or the display coming back at another position.
    private var offset: NSRect?
    private var screenID: String?
    /// A saved session's display, before its ID is known (the session stores only
    /// `NSWindow.frameDescriptor`): matched by position and width when it comes back.
    private var savedScreen: NSRect?
    /// `NSWindow.frameDescriptor` at home, saved with the session while the display is away.
    private var descriptor: String?
    /// When the display arrangement last changed. Moves macOS makes around that time are its own,
    /// not the user's.
    private var screensChangedAt = Date.distantPast
    /// The displays as of the last change notice. macOS moves windows onto a display that came
    /// back before it sends the notice, so a move while these differ is part of the change.
    private var knownScreens = WindowHome.currentScreens()
    private var pendingMove: DispatchWorkItem?
    private var observer: NSObjectProtocol?

    /// How long after a display change a move that isn't the user's is treated as macOS's.
    private static let settleTime: TimeInterval = 2
    private static let log = Logger(subsystem: "com.scottsmith.ismith", category: "windows")

    private func trace(_ event: String) {
        guard let window else { return }
        Self.log.info("\(event, privacy: .public): frame \(NSStringFromRect(window.frame), privacy: .public) screen \(Self.id(of: window.screen) ?? "-", privacy: .public) visible \(window.isVisible) onActiveSpace \(window.isOnActiveSpace) home \(self.offset.map(NSStringFromRect) ?? "-", privacy: .public) on \(self.screenID ?? "-", privacy: .public) away \(self.isAway)")
    }

    /// `saved` is the session's frame descriptor the window was opened with, if any.
    init(window: NSWindow, saved: String?) {
        self.window = window
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        guard let saved, let (frame, screen) = Self.parse(saved) else {
            remember()
            return
        }
        offset = frame.offsetBy(dx: -screen.minX, dy: -screen.minY)
        savedScreen = screen
        descriptor = saved
        // Opened while the saved display is away: keep it as home instead of where macOS put it.
        // When it's here, `setFrame(from:)` can still land on the main display; put it on its own.
        if Self.match(screen) != nil { returnHome() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// The window's display, as a stable ID that survives the display being turned off and on.
    static func id(of screen: NSScreen?) -> String? {
        guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// A frame descriptor's window frame and screen rect ("x y w h  sx sy sw sh").
    private static func parse(_ descriptor: String) -> (NSRect, NSRect)? {
        let n = descriptor.split(separator: " ").compactMap { Double($0) }
        guard n.count >= 8 else { return nil }
        return (NSRect(x: n[0], y: n[1], width: n[2], height: n[3]), NSRect(x: n[4], y: n[5], width: n[6], height: n[7]))
    }

    /// The display a descriptor's screen rect describes. AppKit writes the display's frame less
    /// the menu bar, so the origin and width identify it.
    private static func match(_ rect: NSRect) -> NSScreen? {
        NSScreen.screens.first { abs($0.frame.minX - rect.minX) < 1 && abs($0.frame.minY - rect.minY) < 1
            && abs($0.frame.width - rect.width) < 1 }
    }

    private var homeScreen: NSScreen? {
        if let screenID { return NSScreen.screens.first { Self.id(of: $0) == screenID } }
        return savedScreen.flatMap(Self.match)
    }

    private var hasHome: Bool { offset != nil }
    private var isAway: Bool { hasHome && homeScreen == nil }

    /// The user placed the window (dragged it, resized it, or it just opened): this is home.
    func remember() {
        trace("remember")
        pendingMove?.cancel()
        guard let window, !window.styleMask.contains(.fullScreen), !window.isMiniaturized,
              let screen = window.screen else { return }
        offset = window.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        screenID = Self.id(of: screen)
        savedScreen = nil
        descriptor = window.frameDescriptor
    }

    /// The window moved or resized without the user dragging it: tiling, the Window menu, or macOS
    /// rehoming it because its display went away.
    func windowMoved() {
        trace("moved")
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        guard hasHome else { return remember() }
        // On the same display it's the user's (tiling, zoom), unless the displays are changing.
        if let screenID, Self.id(of: window.screen) == screenID, !settling {
            return remember()
        }
        // Onto another display: decide once things settle, so macOS moving the window off a
        // display that just went away doesn't become its new home.
        pendingMove?.cancel()
        let check = DispatchWorkItem { [weak self] in
            guard let self, !self.settling, !self.isAway else { return }
            self.remember()
        }
        pendingMove = check
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleTime, execute: check)
    }

    private var settling: Bool {
        Date().timeIntervalSince(screensChangedAt) < Self.settleTime || Self.currentScreens() != knownScreens
    }

    private static func currentScreens() -> Set<String> { Set(NSScreen.screens.compactMap { id(of: $0) }) }

    private func screensChanged() {
        trace("screens changed: \(NSScreen.screens.count) displays")
        screensChangedAt = Date()
        knownScreens = Self.currentScreens()
        pendingMove?.cancel()
        // macOS finishes arranging windows after the notification; put the window back after it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.knownScreens = Self.currentScreens()
            self.returnHome()
        }
    }

    /// Puts the window back on its home display, if that display is here and the window isn't.
    /// Also called when the window comes back from the Dock, in case the display returned meanwhile.
    func returnHome() {
        trace("return home")
        guard let window, let offset, let screen = homeScreen, !window.styleMask.contains(.fullScreen),
              !window.isMiniaturized else { return }
        var target = offset.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        if window.frame == target { return remember() }
        // The display may have come back at a smaller size.
        let visible = screen.visibleFrame
        target.size.width = min(target.width, visible.width)
        target.size.height = min(target.height, visible.height)
        target.origin.x = min(max(target.minX, visible.minX), visible.maxX - target.width)
        target.origin.y = min(max(target.minY, visible.minY), visible.maxY - target.height)
        if window.frame != target {
            window.setFrame(target, display: true)
            trace("returned")
        }
        if screenID == nil { remember() }
    }

    /// The session's saved frame while the home display is away, so quitting with the monitor off
    /// still reopens the window on it. Nil when the window is home (its own frame is right).
    var awayDescriptor: String? { isAway ? descriptor : nil }
}
