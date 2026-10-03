import AppKit
import BrowserData
import Combine
import Foundation
import SwiftUI
import WebKit

/// Marks downloaded files as quarantined, so Gatekeeper checks a downloaded app or installer
/// before it first opens, as Safari does.
///
/// iSmith isn't sandboxed, and WebKit's networking process (not the app) writes a `WKDownload`'s
/// file, so nothing quarantines it automatically. `LSFileQuarantineEnabled` isn't used: it
/// quarantines every file the app itself writes (its own settings and databases included) and
/// wouldn't cover files the networking process writes. Instead each finished download gets
/// `com.apple.quarantine` through Launch Services' quarantine properties: agent "iSmith", type
/// web download, the file's URL and the page it came from.
enum Quarantine {
    static func mark(_ file: URL, source: URL?, referrer: URL?) throws {
        var properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "iSmith",
            kLSQuarantineAgentBundleIdentifierKey as String: AppIdentity.bundleID,
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineTimeStampKey as String: Date(),
        ]
        // Only real addresses: a blob: or data: URL means nothing later and can be huge.
        if let source, ["http", "https", "ftp"].contains(source.scheme?.lowercased() ?? "") {
            properties[kLSQuarantineDataURLKey as String] = source
        }
        if let referrer, ["http", "https"].contains(referrer.scheme?.lowercased() ?? "") {
            properties[kLSQuarantineOriginURLKey as String] = referrer
        }
        var url = file
        var values = URLResourceValues()
        values.quarantineProperties = properties
        try url.setResourceValues(values)
    }

    /// The raw `com.apple.quarantine` attribute ("0083;…;iSmith;…"), or nil if there's none.
    static func attribute(_ file: URL) -> String? {
        let name = "com.apple.quarantine"
        let size = getxattr(file.path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(file.path, name, $0.baseAddress, size, 0, 0) }
        guard read > 0 else { return nil }
        return String(data: data.prefix(read), encoding: .utf8)
    }
}

/// Every download: where it goes, its progress, quarantine when it finishes, and the list the
/// downloads panel shows (kept in BrowserData across launches).
@MainActor
final class DownloadManager: NSObject, ObservableObject, WKDownloadDelegate {
    /// Newest first.
    @Published private(set) var items: [DownloadItem] = []
    /// The folder downloads go to.
    var folder: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    /// Asks where to save (Save Image As…): returns the chosen file, or nil to cancel.
    var choosePlace: ((_ suggested: String, _ webView: WKWebView?) async -> URL?)?
    /// Called when a download starts, so the window can show the panel.
    var started: ((DownloadItem) -> Void)?
    private let store: DownloadStore?
    private var active: [ObjectIdentifier: DownloadItem] = [:]

    init(store: DownloadStore?) {
        self.store = store
        super.init()
        try? store?.markInterruptedAsFailed()
        items = ((try? store?.all(limit: 200)) ?? []).map(DownloadItem.init(record:))
    }

    var activeCount: Int { items.filter { $0.state == .inProgress }.count }
    /// Overall progress of the downloads in progress, for the toolbar badge (nil: unknown size).
    var overallProgress: Double? {
        let running = items.filter { $0.state == .inProgress }
        guard !running.isEmpty else { return nil }
        let expected = running.compactMap(\.bytesExpected).reduce(0, +)
        guard expected > 0, running.allSatisfy({ $0.bytesExpected != nil }) else { return nil }
        return Double(running.map(\.bytesReceived).reduce(0, +)) / Double(expected)
    }

    /// Starts tracking a download WebKit has begun (a link, a response it can't show, the context
    /// menu). `askWhere` shows a save panel instead of saving to the downloads folder.
    func track(_ download: WKDownload, space: String, referrer: URL?, askWhere: Bool = false) {
        let item = DownloadItem(id: UUID(), space: space, source: download.originalRequest?.url, referrer: referrer)
        item.askWhere = askWhere
        item.download = download
        active[ObjectIdentifier(download)] = item
        download.delegate = self
        items.insert(item, at: 0)
        item.observe(download.progress) { [weak self] in self?.progressed(item) }
        save(item)
        started?(item)
    }

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        guard let item = active[ObjectIdentifier(download)] else { return nil }
        let name = Self.safeName(suggestedFilename)
        item.fileName = name
        if response.expectedContentLength > 0 { item.bytesExpected = response.expectedContentLength }
        let destination: URL?
        if item.askWhere, let choosePlace {
            destination = await choosePlace(name, download.webView)
            // The panel confirmed replacing it; the old one goes to the Trash, not away for good.
            if let destination, FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.trashItem(at: destination, resultingItemURL: nil)
            }
        } else {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            destination = Self.uniqueURL(in: folder, name: name)
        }
        guard let destination else {
            finish(item, state: .cancelled, error: nil)
            return nil
        }
        item.fileURL = destination
        item.fileName = destination.lastPathComponent
        save(item)
        return destination
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest) async -> WKDownload.RedirectPolicy {
        .allow
    }

    func download(_ download: WKDownload, respondTo challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        (.performDefaultHandling, nil)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = active.removeValue(forKey: ObjectIdentifier(download)) else { return }
        if let file = item.fileURL {
            do {
                try Quarantine.mark(file, source: item.source, referrer: item.referrer)
            } catch {
                NSLog("iSmith: couldn't quarantine \(file.lastPathComponent): \(error)")
            }
            // The Downloads stack in the Dock bounces, as for Safari.
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: file.path)
        }
        item.bytesReceived = max(item.bytesReceived, item.bytesExpected ?? 0)
        finish(item, state: .finished, error: nil)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = active.removeValue(forKey: ObjectIdentifier(download)) else { return }
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        // A partial file left behind is quarantined like a finished one.
        if let file = item.fileURL, FileManager.default.fileExists(atPath: file.path) {
            try? Quarantine.mark(file, source: item.source, referrer: item.referrer)
        }
        finish(item, state: cancelled ? .cancelled : .failed, error: cancelled ? nil : error.localizedDescription)
    }

    // MARK: - Actions

    func cancel(_ item: DownloadItem) {
        guard let download = item.download else { return }
        download.cancel { _ in }
    }

    func remove(_ item: DownloadItem) {
        guard item.state != .inProgress else { return }
        items.removeAll { $0 === item }
        try? store?.remove(item.id)
    }

    func clearFinished() {
        items.removeAll { $0.state != .inProgress }
        try? store?.clearFinished()
    }

    func reveal(_ item: DownloadItem) {
        guard let file = item.fileURL else { return }
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.open(file.deletingLastPathComponent())
        }
    }

    func open(_ item: DownloadItem) {
        guard let file = item.fileURL, item.state == .finished else { return }
        NSWorkspace.shared.open(file)
    }

    // MARK: - Private

    private func progressed(_ item: DownloadItem) {
        guard let progress = item.download?.progress else { return }
        item.bytesReceived = progress.completedUnitCount
        if progress.totalUnitCount > 0 { item.bytesExpected = progress.totalUnitCount }
        objectWillChange.send()
    }

    private func finish(_ item: DownloadItem, state: DownloadState, error: String?) {
        active = active.filter { $0.value !== item }
        item.state = state
        item.error = error
        item.finishedAt = Date()
        item.download = nil
        item.stopObserving()
        save(item)
        objectWillChange.send()
    }

    private func save(_ item: DownloadItem) {
        try? store?.upsert(item.record)
        // The Dock icon shows how many downloads are running.
        let running = activeCount
        NSApp?.dockTile.badgeLabel = running > 0 ? "\(running)" : nil
    }

    /// A file name that's safe to create: no path separators or leading dots.
    static func safeName(_ suggested: String) -> String {
        var name = suggested.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "download" }
        // File names are limited to 255 bytes; keep the extension and leave room for " (2)".
        let ext = (name as NSString).pathExtension
        var base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let limit = 230 - ext.utf8.count
        while base.utf8.count > max(limit, 1) { base.removeLast() }
        return ext.isEmpty ? base : base + "." + ext
    }

    /// `name`, or `name (2).ext`, `name (3).ext`… whichever doesn't exist yet.
    static func uniqueURL(in folder: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            candidate = folder.appendingPathComponent(numbered)
            n += 1
        }
        return candidate
    }
}

/// One row of the downloads panel.
@MainActor
final class DownloadItem: ObservableObject, Identifiable {
    let id: UUID
    let space: String
    let source: URL?
    let referrer: URL?
    let startedAt: Date
    @Published var fileName: String
    @Published var fileURL: URL?
    @Published var state: DownloadState = .inProgress
    @Published var bytesReceived: Int64 = 0
    @Published var bytesExpected: Int64?
    @Published var error: String?
    var finishedAt: Date?
    var askWhere = false
    fileprivate var download: WKDownload?
    private var observations: [NSKeyValueObservation] = []

    init(id: UUID, space: String, source: URL?, referrer: URL?) {
        self.id = id
        self.space = space
        self.source = source
        self.referrer = referrer
        startedAt = Date()
        fileName = source?.lastPathComponent.isEmpty == false ? source!.lastPathComponent : "download"
    }

    init(record: DownloadRecord) {
        id = record.id
        space = record.space
        source = record.sourceURL.flatMap(URL.init(string:))
        referrer = nil
        startedAt = record.startedAt
        fileName = record.fileName
        fileURL = record.filePath.map { URL(fileURLWithPath: $0) }
        state = record.state
        bytesReceived = record.bytesReceived
        bytesExpected = record.bytesExpected
        error = record.error
        finishedAt = record.finishedAt
    }

    var record: DownloadRecord {
        DownloadRecord(id: id, space: space, sourceURL: source?.absoluteString, filePath: fileURL?.path,
                       fileName: fileName, state: state, bytesReceived: bytesReceived, bytesExpected: bytesExpected,
                       startedAt: startedAt, finishedAt: finishedAt, error: error)
    }

    var fraction: Double? {
        guard let expected = bytesExpected, expected > 0 else { return nil }
        return min(1, Double(bytesReceived) / Double(expected))
    }

    fileprivate func observe(_ progress: Progress, changed: @escaping () -> Void) {
        observations = [
            progress.observe(\.completedUnitCount) { _, _ in
                DispatchQueue.main.async { changed() }
            },
        ]
    }

    fileprivate func stopObserving() {
        observations.forEach { $0.invalidate() }
        observations = []
    }
}

// MARK: - The panel

/// The toolbar button: shows overall progress while something downloads; opens the panel.
struct DownloadsButton: View {
    @ObservedObject var downloads: DownloadManager
    @Binding var shown: Bool

    var body: some View {
        Button { shown.toggle() } label: {
            ZStack {
                Image(systemName: "arrow.down.circle")
                if downloads.activeCount > 0 {
                    Circle()
                        .trim(from: 0, to: downloads.overallProgress ?? 0.15)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 18, height: 18)
                }
            }
            .frame(width: 20, height: 20)
        }
        .help("Downloads")
        .accessibilityLabel(downloads.activeCount > 0 ? "Downloads, \(downloads.activeCount) in progress" : "Downloads")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            DownloadsPanel(downloads: downloads)
        }
    }
}

struct DownloadsPanel: View {
    @ObservedObject var downloads: DownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                Button("Clear") { downloads.clearFinished() }
                    .disabled(!downloads.items.contains { $0.state != .inProgress })
            }
            .padding(12)
            Divider()
            if downloads.items.isEmpty {
                Text("No downloads").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(downloads.items) { item in
                            DownloadRow(item: item, downloads: downloads)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 360)
    }
}

private struct DownloadRow: View {
    @ObservedObject var item: DownloadItem
    let downloads: DownloadManager

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.fileName).lineLimit(1).truncationMode(.middle)
                if item.state == .inProgress {
                    ProgressView(value: item.fraction ?? 0).progressViewStyle(.linear)
                        .opacity(item.fraction == nil ? 0.4 : 1)
                }
                Text(status).font(.caption).foregroundStyle(item.state == .failed ? .red : .secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if item.state == .inProgress {
                Button { downloads.cancel(item) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).help("Cancel")
            } else if item.fileURL != nil {
                Button { downloads.reveal(item) } label: { Image(systemName: "magnifyingglass.circle") }
                    .buttonStyle(.borderless).help("Show in Finder")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { downloads.open(item) }
        .contextMenu {
            Button("Open") { downloads.open(item) }.disabled(item.state != .finished)
            Button("Show in Finder") { downloads.reveal(item) }.disabled(item.fileURL == nil)
            if let source = item.source {
                Button("Copy Address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(source.absoluteString, forType: .string)
                }
            }
            Divider()
            Button("Remove from List") { downloads.remove(item) }.disabled(item.state == .inProgress)
        }
    }

    private var icon: NSImage {
        if let file = item.fileURL, FileManager.default.fileExists(atPath: file.path) {
            return NSWorkspace.shared.icon(forFile: file.path)
        }
        return NSWorkspace.shared.icon(for: .data)
    }

    private var status: String {
        let size = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
        switch item.state {
        case .inProgress:
            if let expected = item.bytesExpected { return "\(size(item.bytesReceived)) of \(size(expected))" }
            return size(item.bytesReceived)
        case .finished: return size(item.bytesReceived) + (item.source?.host.map { " — \($0)" } ?? "")
        case .cancelled: return "Cancelled"
        case .failed: return item.error ?? "Failed"
        }
    }
}
