import XCTest
import SwiftData
@testable import Folio

@MainActor
final class EfficiencyTests: XCTestCase {
    private var root: URL!
    private var container: ModelContainer!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        root = URL.temporaryDirectory.appendingPathComponent("FolioEfficiency-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        container = try ModelContainer(for: LibraryDocument.self, LibraryFolder.self,
            configurations: ModelConfiguration(url: root.appendingPathComponent("Library.store"), cloudKitDatabase: .none))
        store = LibraryStore(context: container.mainContext, root: root)
    }

    override func tearDownWithError() throws {
        store = nil; container = nil
        try FileManager.default.removeItem(at: root)
    }

    private func reader() async throws -> ReaderSession {
        let url = root.appendingPathComponent("Progress.pdf")
        try SamplePDF.create(at: url, pages: 60)
        let imported = await store.importPDF(url)
        let record = try XCTUnwrap(imported)
        let session = ReaderSession(record: record, store: store)
        await session.open(); session.restored()
        return session
    }

    func testLibraryLayoutDefaultsPersistsAndRecoversInvalidValue() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.libraryLayout, .grid)
        preferences.libraryLayout = .list
        XCTAssertEqual(AppPreferences(defaults: defaults).libraryLayout, .list)
        defaults.set("invalid", forKey: "libraryLayout")
        XCTAssertEqual(AppPreferences(defaults: defaults).libraryLayout, .grid)
    }

    func testFiftyPageTurnsCoalesceJournalWritesAndFlushFinalPage() async throws {
        let session = try await reader()
        defer { session.close() }
        let preferences = AppPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let sync = try ReadingSyncService(store: store, preferences: preferences)
        store.sync = sync
        try sync.captureLibrary()
        let before = sync.journal.writeCount
        for index in 1...50 { session.commitPage(index) }
        XCTAssertEqual(session.record.lastPage, 50, "In-memory progress updates immediately")
        XCTAssertEqual(sync.journal.writeCount, before, "Page turns do not write synchronously")
        try await Task.sleep(for: .milliseconds(1150))
        let flushed = await session.flush()
        XCTAssertTrue(flushed)
        XCTAssertLessThanOrEqual(sync.journal.writeCount - before, 2)
        XCTAssertEqual(sync.journal.state.changes["p:\(session.record.fingerprint)"]?.payload.lastPage, 50)
        let fresh = LibraryStore(context: ModelContext(container), root: root)
        XCTAssertEqual(fresh.documents.first?.lastPage, 50)
    }

    func testCloseAndEndScrubSaveWithoutWaitingForDebounce() async throws {
        let session = try await reader()
        session.commitPage(17)
        session.close()
        XCTAssertEqual(LibraryStore(context: ModelContext(container), root: root).documents.first?.lastPage, 17)
        await session.open(); session.restored()
        session.isScrubbing = true
        session.commitPage(31, persist: false)
        session.endScrub()
        XCTAssertEqual(LibraryStore(context: ModelContext(container), root: root).documents.first?.lastPage, 31)
        session.close()
    }

    func testSearchReusesExtractedTextAndKeepsMatchGeometry() async throws {
        let session = try await reader()
        defer { session.close() }
        let index = SearchIndex(files: store.files, source: session.record.source, password: "")
        let first = try await index.search("curiosity")
        let count = await index.textExtractionCount
        let second = try await index.search("curiosity")
        let repeatedCount = await index.textExtractionCount
        XCTAssertEqual(count, 60)
        XCTAssertEqual(repeatedCount, count)
        XCTAssertEqual(first.map(\.page), second.map(\.page))
        XCTAssertTrue(first.contains { !$0.bounds.isEmpty })
    }

    func testThumbnailWorkerReusedAndDeletionRemovesFingerprintCaches() async throws {
        let session = try await reader()
        let record = session.record
        for page in 0..<8 {
            _ = try await store.thumbnails.thumbnail(source: record.source, cacheKey: record.fingerprint, page: page)
        }
        let opened = await store.thumbnails.workerOpenCount
        XCTAssertEqual(opened, 1)
        let cache = await store.thumbnails.thumbnailURL(name: record.fingerprint, page: 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
        session.close()
        await store.delete(record)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }
}
