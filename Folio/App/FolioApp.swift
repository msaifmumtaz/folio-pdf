import SwiftUI
import SwiftData

@main
struct FolioApp: App {
    @State private var store: LibraryStore?
    @State private var startupError: String?
    @State private var container: ModelContainer?
    @State private var router = FileOpenRouter()
    @State private var preferences: AppPreferences

    init() {
        let testing = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        let defaults = testing ? UserDefaults(suiteName: "FolioUITests")! : .standard
        if testing && ProcessInfo.processInfo.arguments.contains("--reset-library") {
            defaults.removePersistentDomain(forName: "FolioUITests")
        }
        _preferences = State(initialValue: AppPreferences(defaults: defaults))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let store {
                    LibraryView(store: store, preferences: preferences)
                } else if let startupError {
                    ContentUnavailableView {
                        Label("Your library couldn’t open", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text(startupError)
                    } actions: {
                        Button("Try again") { Task { await start() } }.buttonStyle(.borderedProminent)
                    }
                } else {
                    ProgressView("Opening Folio").task { await start() }
                }
            }
            .tint(Palette.accent)
            .preferredColorScheme(preferences.appearance.colorScheme)
            .onOpenURL { router.receive($0) }
        }
    }

    @MainActor private func start() async {
        do {
            let testing = ProcessInfo.processInfo.arguments.contains("--ui-testing")
            let root = URL.applicationSupportDirectory.appendingPathComponent(testing ? "FolioUITests" : "Folio", isDirectory: true)
            if testing && ProcessInfo.processInfo.arguments.contains("--reset-library") {
                if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try LibraryMigration.prepare(root: root)
            let configuration = ModelConfiguration(url: root.appendingPathComponent("Library.store"), cloudKitDatabase: .none)
            let container = try ModelContainer(for: LibraryDocument.self, LibraryFolder.self, configurations: configuration)
            self.container = container
            let store = LibraryStore(context: container.mainContext, root: root)
            do {
                let sync = try ReadingSyncService(store: store, preferences: preferences)
                store.sync = sync
                try await sync.recover()
            } catch {
                // A damaged/unavailable sync journal must never prevent local reading.
                preferences.syncEnabled = false
                store.error = "Reading data recovery needs attention. Local reading is available. \(error.localizedDescription)"
            }
            #if DEBUG
            if testing && ProcessInfo.processInfo.arguments.contains("--seed-library") {
                try await UITestFixtures.seed(store)
            }
            #endif
            self.store = store
            try Data("2".utf8).write(to: root.appendingPathComponent("SchemaVersion"), options: .atomic)
            router.attach(store)
            startupError = nil
        } catch { startupError = error.localizedDescription; store = nil }
    }
}

enum LibraryMigration {
    static func prepare(root: URL) throws {
        let marker = root.appendingPathComponent("SchemaVersion")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        let backup = root.appendingPathComponent("BeforeReferenceMigration", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Library.store") }
        guard !files.isEmpty else { return }
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        for file in files { try FileManager.default.copyItem(at: file, to: backup.appendingPathComponent(file.lastPathComponent)) }
    }
}
