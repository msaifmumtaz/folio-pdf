import XCTest
import SwiftData
@testable import Folio

private enum OriginalSchema: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [LibraryDocument.self] }
    @Model final class LibraryDocument {
        @Attribute(.unique) var id: UUID
        @Attribute(.unique) var fingerprint: String
        var title: String
        var fileName: String
        var importedAt: Date
        var lastOpenedAt: Date?
        var pageCount: Int
        var lastPage: Int
        var byteCount: Int64
        var bookmarks: [Int]
        init(id: UUID) {
            self.id = id; fingerprint = "legacy-fingerprint"; title = "Old library"
            fileName = "old.pdf"; importedAt = .now; pageCount = 25
            lastPage = 12; byteCount = 100; bookmarks = [2, 12]
        }
    }
}

@MainActor
final class MigrationTests: XCTestCase {
    func testOriginalSchemaMigratesWithoutLosingIdentityOrHistory() throws {
        let root = URL.temporaryDirectory.appendingPathComponent("Migration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Library.store")
        let identity = UUID()
        do {
            let original = try ModelContainer(for: OriginalSchema.LibraryDocument.self,
                configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
            original.mainContext.insert(OriginalSchema.LibraryDocument(id: identity))
            try original.mainContext.save()
        }
        try LibraryMigration.prepare(root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("BeforeReferenceMigration/Library.store").path))
        let upgraded = try ModelContainer(for: Folio.LibraryDocument.self, LibraryFolder.self,
            configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
        let document = try XCTUnwrap(upgraded.mainContext.fetch(FetchDescriptor<Folio.LibraryDocument>()).first)
        XCTAssertEqual(document.id, identity)
        XCTAssertEqual(document.lastPage, 12)
        XCTAssertEqual(document.bookmarks, [2, 12])
        XCTAssertEqual(document.fileName, "old.pdf")
        XCTAssertNil(document.sourceKind)
        if case .managed(let name) = document.source { XCTAssertEqual(name, "old.pdf") }
        else { XCTFail("Old copies must stay managed") }
    }
}
