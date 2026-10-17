import SwiftUI

enum ReleaseFeatures {
    static let iCloudSync = false
}

@MainActor @Observable
final class AppPreferences {
    enum LibraryLayout: String, CaseIterable, Identifiable {
        case grid, list
        var id: String { rawValue }
    }

    enum ReadingMode: String, CaseIterable, Identifiable {
        case verticalScroll, flip
        var id: String { rawValue }
        var title: String { self == .flip ? "Flip" : "Vertical scroll" }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var colorScheme: ColorScheme? {
            switch self { case .system: nil; case .light: .light; case .dark: .dark }
        }
    }
    private let defaults: UserDefaults
    var libraryLayout: LibraryLayout { didSet { defaults.set(libraryLayout.rawValue, forKey: "libraryLayout") } }
    var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    var syncEnabled: Bool { didSet { defaults.set(syncEnabled, forKey: "syncEnabled") } }
    var readingMode: ReadingMode { didSet { defaults.set(readingMode.rawValue, forKey: "readingMode") } }
    var pageTurnSoundEnabled: Bool { didSet { defaults.set(pageTurnSoundEnabled, forKey: "pageTurnSoundEnabled") } }
    var pageTurnSoundVolume: Double {
        didSet {
            let value = Self.validVolume(pageTurnSoundVolume)
            if value != pageTurnSoundVolume { pageTurnSoundVolume = value }
            defaults.set(value, forKey: "pageTurnSoundVolume")
        }
    }

    private static func validVolume(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0.5
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        libraryLayout = LibraryLayout(rawValue: defaults.string(forKey: "libraryLayout") ?? "") ?? .grid
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        readingMode = ReadingMode(rawValue: defaults.string(forKey: "readingMode") ?? "") ?? .verticalScroll
        pageTurnSoundEnabled = defaults.bool(forKey: "pageTurnSoundEnabled")
        pageTurnSoundVolume = Self.validVolume((defaults.object(forKey: "pageTurnSoundVolume") as? NSNumber)?.doubleValue ?? 0.5)
        syncEnabled = ReleaseFeatures.iCloudSync && defaults.bool(forKey: "syncEnabled")
        if !ReleaseFeatures.iCloudSync { defaults.set(false, forKey: "syncEnabled") }
    }
}

@MainActor @Observable
final class FileOpenRouter {
    private var queue: [DocumentAccess] = []
    private weak var store: LibraryStore?
    private var draining = false

    func attach(_ store: LibraryStore) { self.store = store; drain() }
    func receive(_ url: URL) {
        guard url.isFileURL else { return }
        queue.append(DocumentAccess(url: url))
        drain()
    }
    private func drain() {
        guard let store, !draining else { return }
        draining = true
        Task {
            defer { draining = false }
            while !queue.isEmpty {
                let lease = queue.removeFirst()
                // Inbox/temp URLs are deliveries, not durable references to originals.
                if lease.url.path.contains("/Inbox/") || lease.url.path.contains("/tmp/") {
                    store.fileRequest = FileRequest(documentID: nil, requiresOriginal: true)
                } else if let document = await store.openReference(lease.url) {
                    await store.present(document)
                }
                withExtendedLifetime(lease) {}
            }
        }
    }
}

struct FileRequest: Identifiable {
    let id = UUID()
    var documentID: UUID?
    var requiresOriginal = false
}
