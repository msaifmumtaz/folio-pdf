import XCTest
import SwiftData
import PDFKit
@testable import Folio

@MainActor
final class FolioTests: XCTestCase {
    var root: URL!
    var container: ModelContainer!
    var store: LibraryStore!

    override func setUpWithError() throws {
        root = URL.temporaryDirectory.appendingPathComponent("FolioTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        container = try ModelContainer(for: LibraryDocument.self, LibraryFolder.self,
            configurations: ModelConfiguration(url: root.appendingPathComponent("test.store"), cloudKitDatabase: .none))
        store = LibraryStore(context: container.mainContext, root: root)
    }

    override func tearDownWithError() throws {
        store = nil; container = nil
        try FileManager.default.removeItem(at: root)
    }

    func fixture(pages: Int = 4, scanned: Bool = false, rotated: Bool = false) async throws -> URL {
        let url = root.appendingPathComponent("Fixture-\(UUID().uuidString).pdf")
        try await Task.detached { try SamplePDF.create(at: url, pages: pages, scanned: scanned, rotated: rotated) }.value
        return url
    }

    func imported(_ url: URL) async throws -> LibraryDocument {
        let document = await store.importPDF(url)
        return try XCTUnwrap(document, store.error ?? "Import failed")
    }

    func testImportDeduplicatesAndPreservesOriginalBytes() async throws {
        let source = try await fixture()
        let original = try Data(contentsOf: source)
        let first = try await imported(source)
        store.savePage(2, for: first)
        let second = try await imported(source)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.documents.count, 1)
        XCTAssertEqual(second.lastPage, 2)
        XCTAssertEqual(try Data(contentsOf: store.files.pdfURL(first.fileName)), original)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testIndependentProgressSurvivesNewContextAndRename() async throws {
        let first = try await imported(fixture())
        let second = try await imported(fixture(pages: 7))
        store.opened(first, pageCount: 4); store.savePage(2, for: first)
        store.opened(second, pageCount: 7); store.savePage(5, for: second)
        store.rename(first, to: "  Research notes  ")
        let fresh = LibraryStore(context: ModelContext(container), root: root)
        XCTAssertEqual(fresh.documents.first { $0.id == first.id }?.lastPage, 2)
        XCTAssertEqual(fresh.documents.first { $0.id == second.id }?.lastPage, 5)
        XCTAssertEqual(fresh.documents.first { $0.id == first.id }?.title, "Research notes")
        store.savePage(99, for: first)
        XCTAssertEqual(first.lastPage, 2)
    }

    func testBookmarkAndDeleteArePersistentAndDoNotDeleteOriginal() async throws {
        let source = try await fixture()
        let document = try await imported(source)
        store.toggleBookmark(document, page: 2)
        store.toggleBookmark(document, page: 0)
        store.toggleBookmark(document, page: 0)
        let fresh = LibraryStore(context: ModelContext(container), root: root)
        XCTAssertEqual(fresh.documents.first?.bookmarks, [2])
        let path = store.files.pdfURL(document.fileName)
        await store.delete(document)
        XCTAssertTrue(store.documents.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testMissingOriginalCanBeRepairedByReimport() async throws {
        let source = try await fixture()
        let document = try await imported(source)
        store.savePage(2, for: document)
        try FileManager.default.removeItem(at: store.files.pdfURL(document.fileName))
        let repaired = try await imported(source)
        XCTAssertEqual(repaired.id, document.id)
        XCTAssertEqual(repaired.lastPage, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.files.pdfURL(repaired.fileName).path))
    }

    func testInvalidEmptyAndMissingPDFsProduceErrors() async throws {
        let invalid = root.appendingPathComponent("broken.pdf")
        try Data("not a PDF".utf8).write(to: invalid)
        let result = await store.importPDF(invalid)
        XCTAssertNil(result)
        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.documents.isEmpty)
        let empty = root.appendingPathComponent("empty.pdf")
        // PDFKit adds a blank page when serializing PDFDocument(); construct a true zero-page fixture.
        var content = "%PDF-1.4\n"
        let firstOffset = content.utf8.count
        content += "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
        let secondOffset = content.utf8.count
        content += "2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n"
        let xref = content.utf8.count
        content += String(format: "xref\n0 3\n0000000000 65535 f \n%010d 00000 n \n%010d 00000 n \n", firstOffset, secondOffset)
        content += "trailer\n<< /Size 3 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF"
        try Data(content.utf8).write(to: empty)
        do { _ = try await store.files.importPDF(from: empty); XCTFail("Empty PDF accepted") }
        catch {}
        do { _ = try await store.files.load(name: "missing.pdf", id: UUID()); XCTFail("Missing PDF accepted") }
        catch { XCTAssertEqual(error.localizedDescription, FolioError.missingFile.localizedDescription) }
    }

    func testAllMarkupKindsRoundTripAndExportWithoutChangingOriginal() async throws {
        let source = try await fixture(rotated: true)
        let document = try await imported(source)
        let original = try Data(contentsOf: store.files.pdfURL(document.fileName))
        var marks = MarkupKind.allCases.map {
            Markup(page: 0, kind: $0, bounds: CGRect(x: 55, y: 300, width: 150, height: 24),
                   points: [CGPoint(x: 60, y: 310), CGPoint(x: 100, y: 315)], color: .teal, text: "A saved thought")
        }
        marks[1].page = 1
        try await store.files.saveMarks(marks, id: document.id)
        let saved = try await store.files.readMarks(document.id)
        XCTAssertEqual(saved, marks)
        let loaded = try await store.files.load(name: document.fileName, id: document.id)
        XCTAssertEqual(loaded.document.page(at: 0)?.annotations.filter { $0.type != "Popup" }.count, 4)
        XCTAssertEqual(loaded.document.page(at: 1)?.annotations.count, 1)
        let url = try await store.files.export(name: document.fileName, title: "Portable", marks: marks, password: nil)
        let exported = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(exported.page(at: 0)?.annotations.filter { $0.type != "Popup" }.count, 4)
        XCTAssertEqual(exported.page(at: 1)?.annotations.count, 1)
        XCTAssertEqual(exported.page(at: 0)?.rotation, 90)
        let note = try XCTUnwrap(exported.page(at: 0)?.annotations.first { $0.type == "Text" })
        XCTAssertEqual(note.contents, "A saved thought")
        XCTAssertEqual(try Data(contentsOf: store.files.pdfURL(document.fileName)), original)
        let attachment = XCTAttachment(data: try Data(contentsOf: url), uniformTypeIdentifier: "com.adobe.pdf")
        attachment.name = "Folio-annotated-export.pdf"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testOriginalAnnotationsArePreserved() async throws {
        let source = try await fixture()
        let original = try XCTUnwrap(PDFDocument(url: source))
        let note = PDFAnnotation(bounds: CGRect(x: 50, y: 50, width: 28, height: 28), forType: .text, withProperties: nil)
        note.contents = "Original author"
        original.page(at: 0)?.addAnnotation(note)
        XCTAssertTrue(original.write(to: source))
        let record = try await imported(source)
        let session = ReaderSession(record: record, store: store)
        await session.open()
        session.addStroke(points: [.init(x: 80, y: 120), .init(x: 150, y: 130)], page: 0)
        session.undo()
        XCTAssertEqual(session.pdf?.page(at: 0)?.annotations.first?.contents, "Original author")
        XCTAssertEqual(session.pdf?.page(at: 0)?.annotations.filter { $0.type != "Popup" }.count, 1)
        _ = await session.flush()
    }

    func testUndoRedoEraseAndNoteEditingAutosaveLatestSnapshot() async throws {
        let record = try await imported(fixture())
        let session = ReaderSession(record: record, store: store)
        await session.open()
        session.addStroke(points: [.init(x: 50, y: 50), .init(x: 150, y: 150)], page: 0)
        session.saveNote(NoteDraft(page: 1, point: .init(x: 90, y: 90)), text: "First note")
        XCTAssertEqual(session.marks.count, 2)
        session.undo(); XCTAssertEqual(session.marks.count, 1)
        session.redo(); XCTAssertEqual(session.marks.count, 2)
        session.erase(at: .init(x: 100, y: 100), page: 0, tolerance: 4)
        XCTAssertEqual(session.marks.count, 1)
        let note = try XCTUnwrap(session.marks.first)
        session.saveNote(NoteDraft(page: 1, point: note.bounds.origin, existingID: note.id), text: "Edited note")
        let saved = await session.flush()
        XCTAssertTrue(saved)
        let disk = try await store.files.readMarks(record.id)
        XCTAssertEqual(disk.count, 1)
        XCTAssertEqual(disk.first?.text, "Edited note")
        let fresh = ReaderSession(record: record, store: store)
        await fresh.open()
        XCTAssertEqual(fresh.marks, disk)
    }

    func testTextSelectionCreatesEachMarkupType() async throws {
        let record = try await imported(fixture())
        let session = ReaderSession(record: record, store: store)
        await session.open()
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        view.document = session.pdf
        session.pdfView = view
        for kind in [MarkupKind.highlight, .underline, .strikeOut] {
            let selection = try XCTUnwrap(session.pdf?.findString("good document", withOptions: .caseInsensitive).first)
            view.setCurrentSelection(selection, animate: false)
            session.applySelection(kind)
        }
        XCTAssertEqual(Set(session.marks.map(\.kind)), Set([.highlight, .underline, .strikeOut]))
        XCTAssertTrue(session.marks.allSatisfy { !$0.bounds.isEmpty })
        _ = await session.flush()
    }

    func testFailedSaveKeepsEditsAndRetryRecovers() async throws {
        let record = try await imported(fixture())
        let session = ReaderSession(record: record, store: store)
        await session.open()
        let annotationDirectory = root.appendingPathComponent("Annotations")
        try FileManager.default.removeItem(at: annotationDirectory)
        try Data("blocks directory creation".utf8).write(to: annotationDirectory)
        session.addStroke(points: [.init(x: 50, y: 60), .init(x: 90, y: 100)], page: 0)
        let failed = await session.flush()
        XCTAssertFalse(failed)
        XCTAssertNotNil(session.saveError)
        XCTAssertEqual(session.marks.count, 1)
        try FileManager.default.removeItem(at: annotationDirectory)
        let recovered = await session.flush()
        XCTAssertTrue(recovered)
        XCTAssertNil(session.saveError)
        let disk = try await store.files.readMarks(record.id)
        XCTAssertEqual(disk.count, 1)
    }

    func testMalformedMarkupIsNotSilentlyDiscarded() async throws {
        let record = try await imported(fixture())
        try Data("broken json".utf8).write(to: store.files.markupURL(record.id))
        do { _ = try await store.files.load(name: record.fileName, id: record.id); XCTFail("Corrupt markup ignored") }
        catch {}
    }

    func testPasswordsAndRestrictedAnnotations() async throws {
        let source = try await fixture()
        let pdf = try XCTUnwrap(PDFDocument(url: source))
        let encrypted = root.appendingPathComponent("Private.pdf")
        XCTAssertTrue(pdf.write(to: encrypted, withOptions: [.userPasswordOption: "reader", .ownerPasswordOption: "owner",
                                                           .accessPermissionsOption: 0]))
        let record = try await imported(encrypted)
        XCTAssertEqual(record.pageCount, 0)
        let session = ReaderSession(record: record, store: store)
        await session.open()
        XCTAssertTrue(session.requiresPassword)
        session.password = "wrong"; await session.open()
        XCTAssertTrue(session.requiresPassword)
        session.password = "reader"; await session.open()
        XCTAssertNotNil(session.pdf)
        XCTAssertFalse(session.requiresPassword)
        XCTAssertFalse(session.allowsMarkup)
        session.addStroke(points: [.zero, .init(x: 10, y: 10)], page: 0)
        XCTAssertTrue(session.marks.isEmpty)
        let thumb = try await store.thumbnails.thumbnail(name: record.fileName, password: "reader")
        XCTAssertNotNil(thumb)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Thumbnails/\(record.fileName)-0.jpg").path))
    }

    func testScansSupportInkAndNotesWithoutTextSelection() async throws {
        let record = try await imported(fixture(pages: 2, scanned: true))
        let session = ReaderSession(record: record, store: store)
        await session.open()
        XCTAssertTrue(session.pdf?.page(at: 0)?.string?.isEmpty ?? true)
        session.addStroke(points: [.init(x: 50, y: 50), .init(x: 100, y: 80)], page: 0)
        session.saveNote(NoteDraft(page: 0, point: .init(x: 100, y: 100)), text: "Scanned note")
        let saved = await session.flush()
        XCTAssertTrue(saved)
        XCTAssertEqual(session.marks.count, 2)
    }

    func testDeletingNoteRemovesItsPopupAndPersistsDeletion() async throws {
        let record = try await imported(fixture())
        let session = ReaderSession(record: record, store: store)
        await session.open()
        session.saveNote(NoteDraft(page: 0, point: .init(x: 100, y: 100)), text: "Delete me")
        session.selectedMarkID = session.marks.first?.id
        session.deleteSelected()
        XCTAssertTrue(session.marks.isEmpty)
        XCTAssertTrue(session.pdf?.page(at: 0)?.annotations.isEmpty == true)
        _ = await session.flush()
        let disk = try await store.files.readMarks(record.id)
        XCTAssertTrue(disk.isEmpty)
    }

    func testProtectedExportRetainsPasswordAndAccessPermissions() async throws {
        let source = try await fixture()
        let pdf = try XCTUnwrap(PDFDocument(url: source))
        let protected = root.appendingPathComponent("Protected.pdf")
        XCTAssertTrue(pdf.write(to: protected, withOptions: [
            .userPasswordOption: "reader", .ownerPasswordOption: "owner",
            .accessPermissionsOption: PDFAccessPermissions.allowsCommenting.rawValue
        ]))
        let record = try await imported(protected)
        let marks = [Markup(page: 0, kind: .note, bounds: CGRect(x: 80, y: 80, width: 28, height: 28), text: "Protected note")]
        let result = try await store.files.export(name: record.fileName, title: "Shared", marks: marks, password: "reader")
        let exported = try XCTUnwrap(PDFDocument(url: result))
        XCTAssertTrue(exported.isLocked)
        XCTAssertFalse(exported.unlock(withPassword: "wrong"))
        XCTAssertTrue(exported.unlock(withPassword: "reader"))
        XCTAssertTrue(exported.allowsCommenting)
        XCTAssertFalse(exported.allowsCopying)
        XCTAssertTrue(exported.page(at: 0)?.annotations.contains { $0.contents == "Protected note" } == true)
    }

    func testRestorationDoesNotOverwriteSavedPageDuringLayout() async throws {
        let record = try await imported(fixture(pages: 25))
        store.savePage(13, for: record)
        let session = ReaderSession(record: record, store: store)
        await session.open()
        let host = PDFHostController(session: session)
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 650)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        XCTAssertTrue(session.ready)
        XCTAssertEqual(record.lastPage, 13)
        XCTAssertEqual(session.currentPage, 13)
        XCTAssertEqual(session.pdf?.index(for: try XCTUnwrap(host.pdfView.currentPage)), 13)
        host.view.frame = CGRect(x: 0, y: 0, width: 650, height: 390)
        host.view.layoutIfNeeded()
        XCTAssertEqual(record.lastPage, 13)
        host.tearDown()
    }

    func testStrokeHitTestingDoesNotEraseEmptyBoundingBoxSpace() {
        let mark = Markup(page: 0, kind: .ink, bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                          points: [.zero, .init(x: 100, y: 100)])
        XCTAssertTrue(ReaderSession.hits(mark, point: .init(x: 50, y: 50), tolerance: 3))
        XCTAssertFalse(ReaderSession.hits(mark, point: .init(x: 10, y: 90), tolerance: 3))
    }

    func testOpeningBenchmarks() async throws {
        for count in [25, 500] {
            let source = try await fixture(pages: count)
            let record = try await imported(source)
            let start = ContinuousClock.now
            let session = ReaderSession(record: record, store: store)
            await session.open()
            let page = try XCTUnwrap(session.pdf?.page(at: 0))
            _ = page.thumbnail(of: CGSize(width: 390, height: 600), for: .cropBox)
            let duration = start.duration(to: .now)
            let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            print("FOLIO_BENCHMARK pages=\(count) bytes=\(record.byteCount) load_and_first_render_seconds=\(seconds)")
            XCTAssertEqual(session.pdf?.pageCount, count)
            XCTAssertLessThan(seconds, count == 25 ? 1 : 3)
        }
    }
}
