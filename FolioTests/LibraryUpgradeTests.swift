import XCTest
import SwiftData
import PDFKit
import SwiftUI
@testable import Folio

@MainActor
final class LibraryUpgradeTests: XCTestCase {
    var root: URL!
    var container: ModelContainer!
    var store: LibraryStore!

    override func setUpWithError() throws {
        root = URL.temporaryDirectory.appendingPathComponent("FolioUpgrade-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        container = try ModelContainer(for: LibraryDocument.self, LibraryFolder.self,
            configurations: ModelConfiguration(url: root.appendingPathComponent("Library.store"), cloudKitDatabase: .none))
        store = LibraryStore(context: container.mainContext, root: root)
    }
    override func tearDownWithError() throws {
        store = nil; container = nil
        try FileManager.default.removeItem(at: root)
    }
    func source(pages: Int = 5) throws -> URL {
        let url = root.appendingPathComponent("Original-\(UUID().uuidString).pdf")
        try SamplePDF.create(at: url, pages: pages)
        return url
    }
    func enableLocalJournal() throws -> ReadingSyncService {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let sync = try ReadingSyncService(store: store, preferences: AppPreferences(defaults: defaults))
        store.sync = sync
        try sync.captureLibrary()
        return sync
    }

    func testExternalReferenceReopensWithoutCopyingPDF() async throws {
        let url = try source()
        let bytes = try Data(contentsOf: url)
        let opened = await store.openReference(url)
        let record = try XCTUnwrap(opened)
        XCTAssertEqual(record.sourceKind, "external")
        XCTAssertTrue(record.fileName.isEmpty)
        XCTAssertNotNil(record.sourceBookmark)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Documents").path))
        store.savePage(3, for: record)
        let fresh = LibraryStore(context: ModelContext(container), root: root)
        let restored = try XCTUnwrap(fresh.documents.first)
        let loaded = try await fresh.files.load(source: restored.source, id: restored.id)
        XCTAssertEqual(loaded.document.pageCount, 5)
        XCTAssertEqual(restored.lastPage, 3)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let duplicate = await fresh.openReference(url)
        XCTAssertEqual(duplicate?.id, record.id)
        XCTAssertEqual(fresh.documents.count, 1)
    }

    func testReferenceDeletionKeepsOriginalAndOtherManagedPDFs() async throws {
        let original = try source()
        let external = await store.openReference(original)
        let managed = await store.importPDF(try source(pages: 2))
        let managedRecord = try XCTUnwrap(managed)
        await store.delete(try XCTUnwrap(external))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.files.pdfURL(managedRecord.fileName).path))
        XCTAssertEqual(store.documents.count, 1)
    }

    func testLinkOriginalVerifiesContentsBeforeRemovingManagedCopy() async throws {
        let original = try source()
        let imported = await store.importPDF(original)
        let record = try XCTUnwrap(imported)
        let copy = store.files.pdfURL(record.fileName)
        store.savePage(2, for: record); store.toggleBookmark(record, page: 1)
        let mark = Markup(page: 1, kind: .note, bounds: CGRect(x: 10, y: 10, width: 20, height: 20), text: "Keep me")
        try await store.files.saveMarks([mark], id: record.id)
        let mismatch = await store.openReference(try source(pages: 2), linking: record)
        XCTAssertNil(mismatch)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        store.error = nil
        let linked = await store.openReference(original, linking: record)
        XCTAssertEqual(linked?.id, record.id)
        XCTAssertEqual(record.lastPage, 2); XCTAssertEqual(record.bookmarks, [1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        let marks = try await store.files.readMarks(record.id)
        XCTAssertEqual(marks, [mark])
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testChangedSourceCreatesNewVersionAndRetainsOldHistory() async throws {
        let url = try source()
        let opened = await store.openReference(url)
        let old = try XCTUnwrap(opened)
        store.savePage(3, for: old)
        try SamplePDF.create(at: url, pages: 2)
        do { _ = try await store.files.load(source: old.source, id: old.id); XCTFail("Changed bytes accepted") }
        catch { XCTAssertEqual(error.localizedDescription, FolioError.sourceChanged.localizedDescription) }
        let updated = await store.openReference(url)
        XCTAssertNotEqual(updated?.id, old.id)
        XCTAssertTrue(old.needsLocation)
        XCTAssertEqual(old.lastPage, 3)
        XCTAssertEqual(store.documents.count, 2)
        XCTAssertEqual(updated?.pageCount, 2)
    }

    func testNestedFoldersMoveDeleteAndRejectCycles() async throws {
        let parent = try XCTUnwrap(store.createFolder("Work", parentID: nil))
        let child = try XCTUnwrap(store.createFolder("Notes", parentID: parent.id))
        let grandchild = try XCTUnwrap(store.createFolder("2026", parentID: child.id))
        let opened = await store.openReference(try source(), folderID: child.id)
        let document = try XCTUnwrap(opened)
        XCTAssertEqual(store.folderPath(grandchild.id), "Work / Notes / 2026")
        store.moveFolder(parent, to: grandchild.id)
        XCTAssertNil(parent.parentID)
        store.error = nil
        store.deleteFolder(child)
        XCTAssertEqual(document.folderID, parent.id)
        XCTAssertEqual(grandchild.parentID, parent.id)
        store.moveDocuments([document.id], to: grandchild.id)
        let fresh = LibraryStore(context: ModelContext(container), root: root)
        XCTAssertEqual(fresh.documents.first?.folderID, grandchild.id)
        XCTAssertEqual(fresh.folders.count, 2)
    }

    func testJournalPersistsPendingChangesAndExcludesFileAccessData() async throws {
        let sourceURL = try source()
        let opened = await store.openReference(sourceURL)
        let document = try XCTUnwrap(opened)
        let sync = try enableLocalJournal()
        store.savePage(3, for: document)
        store.toggleBookmark(document, page: 2)
        XCTAssertFalse(sync.preferences.syncEnabled)
        XCTAssertEqual(sync.status, "Off")
        let saved = try SyncJournal(url: sync.journal.url)
        XCTAssertEqual(saved.state.pending, sync.journal.state.pending)
        XCTAssertEqual(saved.state.changes["p:\(document.fingerprint)"]?.payload.lastPage, 3)
        let raw = try String(contentsOf: sync.journal.url, encoding: .utf8)
        for excluded in [sourceURL.path, "sourceBookmark", "sourcePath", "password", "fileName", "Thumbnails"] {
            XCTAssertFalse(raw.contains(excluded), excluded)
        }
        XCTAssertFalse(raw.contains(document.sourceBookmark!.base64EncodedString()))
    }

    func testConcurrentAnnotationAdditionsSurviveLocalSnapshotSave() async throws {
        let opened = await store.openReference(try source())
        let document = try XCTUnwrap(opened)
        let sync = try enableLocalJournal()
        let local = Markup(page: 0, kind: .note, bounds: CGRect(x: 0, y: 0, width: 20, height: 20), text: "Local")
        let remote = Markup(page: 1, kind: .note, bounds: CGRect(x: 0, y: 0, width: 20, height: 20), text: "Remote")
        let remoteChange = ReadingChange(id: "a:\(document.fingerprint):\(remote.id)", kind: .annotation,
            fingerprint: document.fingerprint, payload: ReadingPayload(markup: remote), modifiedAt: .now, writer: "other-device")
        try sync.journal.merge([remoteChange])
        try sync.captureAnnotations([local], fingerprint: document.fingerprint, previous: [])
        XCTAssertEqual(Set(sync.remoteMarks(for: document.fingerprint).map(\.id)), [local.id, remote.id])
        try sync.captureAnnotations([], fingerprint: document.fingerprint, previous: [local])
        XCTAssertEqual(sync.remoteMarks(for: document.fingerprint), [remote])
        try await sync.applyJournal()
    }

    func testLatestProgressMayMoveBackwardsAndTombstonesDoNotResurrect() throws {
        let journal = try SyncJournal(url: root.appendingPathComponent("journal.json"))
        let older = ReadingChange(id: "p:pdf", kind: .progress, fingerprint: "pdf",
            payload: ReadingPayload(lastPage: 20), modifiedAt: Date(timeIntervalSince1970: 100), writer: "a")
        var newer = older; newer.payload.lastPage = 4; newer.modifiedAt = Date(timeIntervalSince1970: 200)
        try journal.merge([older, newer, older])
        XCTAssertEqual(journal.state.changes[older.id]?.payload.lastPage, 4)
        var deleted = newer; deleted.deleted = true
        try journal.merge([deleted, newer])
        XCTAssertEqual(journal.state.changes[older.id]?.deleted, true)
        let reloaded = try SyncJournal(url: journal.url)
        XCTAssertEqual(reloaded.state.changes, journal.state.changes)
    }

    func testSyncedEntryNeedsLocationAndFolderTombstoneStaysDeleted() async throws {
        let sync = try enableLocalJournal()
        let fingerprint = "remote-pdf"
        let change = ReadingChange(id: "d:\(fingerprint)", kind: .document, fingerprint: fingerprint,
            payload: ReadingPayload(title: "Remote", pageCount: 10, byteCount: 100), modifiedAt: .now, writer: "other")
        try sync.journal.merge([change])
        try await sync.applyJournal()
        XCTAssertTrue(try XCTUnwrap(store.documents.first).needsLocation)
        let folder = try XCTUnwrap(store.createFolder("Synced", parentID: nil))
        XCTAssertNotNil(sync.journal.state.changes["f:\(folder.id)"])
        store.deleteFolder(folder)
        XCTAssertEqual(sync.journal.state.changes["f:\(folder.id)"]?.deleted, true)
    }

    func testScrubberBoundsAndOnePageDocuments() {
        XCTAssertEqual(PageScrubber.page(at: -1, count: 500), 0)
        XCTAssertEqual(PageScrubber.page(at: 1.2, count: 500), 499)
        XCTAssertEqual(PageScrubber.page(at: 0.5, count: 1), 0)
        XCTAssertEqual(PageScrubber.page(at: 0.5, count: 5), 2)
    }

    func testAppearancePersistsAndDefaultsToSystem() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = AppPreferences(defaults: defaults)
        XCTAssertEqual(settings.appearance, .system)
        XCTAssertFalse(settings.syncEnabled)
        settings.appearance = .dark
        XCTAssertEqual(AppPreferences(defaults: defaults).appearance, .dark)
        XCTAssertFalse(AppPreferences(defaults: defaults).syncEnabled)
    }
    func testOldAnnotationsAreNotErasedByAnEmptySyncJournal() async throws {
        let opened = await store.importPDF(try source())
        let document = try XCTUnwrap(opened)
        let mark = Markup(page: 0, kind: .note, bounds: .zero, text: "Before upgrade")
        try await store.files.saveMarks([mark], id: document.id)
        let sync = try enableLocalJournal()
        try await sync.applyJournal()
        let retained = try await store.files.readMarks(document.id)
        XCTAssertEqual(retained, [mark])
        try await sync.recover()
        XCTAssertEqual(sync.remoteMarks(for: document.fingerprint), [mark])
    }

    func testRecoveryReplaysMergedChangesAfterRelaunch() async throws {
        let sync = try enableLocalJournal()
        let change = ReadingChange(id: "d:recover", kind: .document, fingerprint: "recover",
            payload: ReadingPayload(title: "Recovered", pageCount: 5), modifiedAt: .now, writer: "remote")
        try sync.journal.merge([change])
        XCTAssertEqual(sync.journal.state.needsProjection, true)
        let fresh = try ReadingSyncService(store: store, preferences: sync.preferences)
        store.sync = fresh
        try await fresh.recover()
        XCTAssertEqual(store.documents.first?.title, "Recovered")
        XCTAssertTrue(store.documents.first?.needsLocation == true)
        XCTAssertEqual(fresh.journal.state.needsProjection, false)
    }

    func testRemoteProgressDoesNotJumpActiveReaderOrReviveDeletedDocument() async throws {
        let opened = await store.importPDF(try source())
        let document = try XCTUnwrap(opened)
        let sync = try enableLocalJournal()
        let session = ReaderSession(record: document, store: store)
        await session.open()
        session.ready = true; session.currentPage = 3
        var progress = try XCTUnwrap(sync.journal.state.changes["p:\(document.fingerprint)"])
        progress.payload.lastPage = 1; progress.modifiedAt = Date.now.addingTimeInterval(10); progress.writer = "remote"
        try sync.journal.merge([progress]); try await sync.applyJournal()
        XCTAssertEqual(document.lastPage, 1)
        XCTAssertEqual(session.currentPage, 3)
        var deletion = try XCTUnwrap(sync.journal.state.changes["d:\(document.fingerprint)"])
        deletion.deleted = true; deletion.modifiedAt = Date.now.addingTimeInterval(20)
        try sync.journal.merge([deletion]); try await sync.applyJournal()
        _ = await session.flush()
        XCTAssertEqual(sync.journal.state.changes[deletion.id]?.deleted, true)
        session.close(); store.activeSession = nil
        try await sync.applyJournal()
        XCTAssertTrue(store.documents.isEmpty)
    }

    func testUnavailableOriginalKeepsReadingHistory() async throws {
        let url = try source()
        let opened = await store.openReference(url)
        let document = try XCTUnwrap(opened)
        store.savePage(3, for: document)
        try FileManager.default.removeItem(at: url)
        do { _ = try await store.files.load(source: document.source, id: document.id); XCTFail("Missing file loaded") }
        catch { }
        XCTAssertEqual(store.documents.first?.lastPage, 3)
        XCTAssertEqual(store.documents.first?.id, document.id)
    }

    func testVersionOneAnnotationsStillLoadAndSaveAsVersionTwo() async throws {
        let id = UUID()
        let mark = Markup(page: 0, kind: .note, bounds: .zero, text: "Legacy")
        var envelope = MarkupEnvelope(marks: [mark]); envelope.version = 1
        try await store.files.prepare()
        try JSONEncoder().encode(envelope).write(to: store.files.markupURL(id))
        let loaded = try await store.files.readMarks(id)
        XCTAssertEqual(loaded, [mark])
        try await store.files.saveMarks(loaded, id: id)
        let migrated = try JSONDecoder().decode(MarkupEnvelope.self, from: Data(contentsOf: store.files.markupURL(id)))
        XCTAssertEqual(migrated.version, 2)
        XCTAssertEqual(migrated.marks, [mark])
    }

    func testJournalWriteFailureRollsBackPendingChanges() throws {
        let parent = root.appendingPathComponent("not-a-directory")
        let journal = try SyncJournal(url: parent.appendingPathComponent("journal.json"))
        try Data("blocked".utf8).write(to: parent)
        XCTAssertThrowsError(try journal.transaction { state in
            SyncJournal.put("d:test", kind: .document, payload: ReadingPayload(title: "Unwritten"), into: &state)
        })
        XCTAssertTrue(journal.state.changes.isEmpty)
        XCTAssertTrue(journal.state.pending.isEmpty)
    }

    func testDisablingSyncKeepsLocalReadingDataAndPendingChanges() async throws {
        let opened = await store.importPDF(try source())
        let document = try XCTUnwrap(opened)
        let sync = try enableLocalJournal()
        store.savePage(2, for: document)
        let pending = sync.journal.state.pending
        await sync.setEnabled(false)
        XCTAssertEqual(document.lastPage, 2)
        XCTAssertEqual(sync.journal.state.pending, pending)
        XCTAssertFalse(sync.preferences.syncEnabled)
        XCTAssertEqual(sync.status, "Off")
    }

    func testReleaseBlocksPreviouslyEnabledCloudSyncAndKeepsLocalJournal() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(true, forKey: "syncEnabled")
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.syncEnabled)
        XCTAssertFalse(defaults.bool(forKey: "syncEnabled"))
        let opened = await store.importPDF(try source())
        let document = try XCTUnwrap(opened)
        let sync = try ReadingSyncService(store: store, preferences: preferences)
        store.sync = sync
        try await sync.recover()
        store.savePage(2, for: document)
        store.toggleBookmark(document, page: 1)
        let pending = sync.journal.state.pending
        await sync.setEnabled(true)
        XCTAssertFalse(preferences.syncEnabled)
        // Even a stale in-memory flag cannot bypass the release switch.
        preferences.syncEnabled = true
        await sync.start()
        await sync.syncNow()
        XCTAssertEqual(sync.status, "Off")
        XCTAssertFalse(sync.isSyncing)
        XCTAssertNil(sync.failure)
        XCTAssertEqual(sync.journal.state.pending, pending)
        XCTAssertEqual(document.lastPage, 2)
        XCTAssertEqual(document.bookmarks, [1])
        XCTAssertFalse(AppPreferences(defaults: defaults).syncEnabled)
    }

    func testTapTravelDurationAndTouchDownEligibility() {
        var tap = ReaderTapSample(origin: .zero, startedAt: 0, eligible: true)
        tap.move(to: CGPoint(x: 8, y: 0))
        XCTAssertTrue(tap.acceptsEnd(at: 0.35, eligibleNow: true))
        XCTAssertFalse(tap.acceptsEnd(at: 0.351, eligibleNow: true))
        XCTAssertFalse(tap.acceptsEnd(at: 0.1, eligibleNow: false))
        tap.move(to: CGPoint(x: 8.1, y: 0))
        tap.move(to: .zero)
        XCTAssertFalse(tap.acceptsEnd(at: 0.1, eligibleNow: true))
        let stoppingTap = ReaderTapSample(origin: .zero, startedAt: 0, eligible: false)
        XCTAssertFalse(stoppingTap.acceptsEnd(at: 0.1, eligibleNow: true))
    }

    func testReaderTapCooldownAndScrubbing() async throws {
        let opened = await store.importPDF(try source())
        let session = ReaderSession(record: try XCTUnwrap(opened), store: store)
        defer { session.close() }
        XCTAssertFalse(session.acceptsPageTap())
        session.ready = true
        XCTAssertTrue(session.acceptsPageTap())
        session.setReaderInteraction(active: true)
        XCTAssertFalse(session.acceptsPageTap())
        session.setReaderInteraction(active: false)
        let ended = session.lastReaderInteraction
        XCTAssertFalse(session.acceptsPageTap(at: ended + 0.249))
        XCTAssertTrue(session.acceptsPageTap(at: ended + 0.251))
        session.isScrubbing = true
        XCTAssertFalse(session.acceptsPageTap(at: ended + 10))
        session.endScrub()
        XCTAssertFalse(session.acceptsPageTap())
    }

    func testPageMarkerNeverAppearsInFullscreenAndAutoHidesWithControls() async throws {
        let opened = await store.importPDF(try source())
        let session = ReaderSession(record: try XCTUnwrap(opened), store: store)
        defer { session.close() }
        session.restored()
        XCTAssertTrue(session.pageMarkerVisible)
        session.chromeVisible = false
        XCTAssertFalse(session.pageMarkerVisible)
        session.scrollActivity()
        session.setReaderInteraction(active: true)
        XCTAssertFalse(session.pageMarkerVisible)
        session.isScrubbing = true
        XCTAssertFalse(session.pageMarkerVisible)
        session.setReaderInteraction(active: false)
        session.endScrub()
        XCTAssertFalse(session.pageMarkerVisible)
        session.chromeVisible = true
        XCTAssertTrue(session.pageMarkerVisible, "Restoring controls reveals the marker")
        try await Task.sleep(for: .milliseconds(1650))
        XCTAssertFalse(session.pageMarkerVisible)
        session.setReaderInteraction(active: true)
        try await Task.sleep(for: .milliseconds(1650))
        XCTAssertTrue(session.pageMarkerVisible)
        session.setReaderInteraction(active: false)
        session.isScrubbing = true
        try await Task.sleep(for: .milliseconds(1650))
        XCTAssertTrue(session.pageMarkerVisible)
        session.endScrub()
        try await Task.sleep(for: .milliseconds(900))
        session.scrollActivity()
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertTrue(session.pageMarkerVisible, "New activity restarts the timer")
        try await Task.sleep(for: .milliseconds(750))
        XCTAssertFalse(session.pageMarkerVisible)
    }

    func testPageJumpValidation() {
        XCTAssertEqual(PageJumpInput.page(from: "1", count: 25), 0)
        XCTAssertEqual(PageJumpInput.page(from: " 25\n", count: 25), 24)
        XCTAssertEqual(PageJumpInput.page(from: "1234", count: 1234), 1233)
        for input in ["", " ", "0", "26", "-1", "+1", "1.5", "abc", String(repeating: "9", count: 30)] {
            XCTAssertNil(PageJumpInput.page(from: input, count: 25), input)
        }
        XCTAssertNil(PageJumpInput.page(from: "1", count: 0))
    }

    private func readerForSelection() async throws -> PDFHostController {
        let opened = await store.importPDF(try source())
        let session = ReaderSession(record: try XCTUnwrap(opened), store: store)
        await session.open()
        let host = PDFHostController(session: session)
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 650)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        XCTAssertTrue(session.ready)
        return host
    }

    func testOutsideTextSelectionTapIsConsumedBeforeNoteOrFullscreen() async throws {
        let host = try await readerForSelection()
        defer { host.tearDown(); host.session.close() }
        let session = host.session
        let selection = try XCTUnwrap(session.pdf?.findString("good document", withOptions: .caseInsensitive).first)
        let page = try XCTUnwrap(session.pdf?.page(at: 0))
        let margin = host.pdfView.convert(CGPoint(x: 10, y: 400), from: page)
        let gap = host.pdfView.convert(CGPoint(x: 10, y: page.bounds(for: .cropBox).minY - 2), from: page)
        for tool in [ReaderTool.read, .note, .highlight] {
            session.tool = tool
            for location in [margin, gap] {
                for pdfKitClearedFirst in [false, true] {
                    host.pdfView.setCurrentSelection(selection, animate: false)
                    let snapshot = try XCTUnwrap(ReaderTextSelection(in: host.pdfView))
                    XCTAssertFalse(snapshot.contains(location))
                    if pdfKitClearedFirst { host.pdfView.clearSelection() }
                    host.handlePageTap(at: location, selectionAtStart: snapshot)
                    XCTAssertNil(host.pdfView.currentSelection)
                    XCTAssertFalse(session.selectionAvailable)
                    XCTAssertTrue(session.chromeVisible)
                    XCTAssertNil(session.noteDraft)
                    XCTAssertTrue(session.marks.isEmpty)
                }
            }
        }
        session.tool = .read
        host.handlePageTap(at: margin, selectionAtStart: nil)
        XCTAssertFalse(session.chromeVisible, "The next stationary page tap can enter fullscreen")
    }

    func testInsideMultilineSelectionAndMotionPreserveSelection() async throws {
        let host = try await readerForSelection()
        defer { host.tearDown(); host.session.close() }
        let page = try XCTUnwrap(host.session.pdf?.page(at: 0))
        let text = try XCTUnwrap(page.string) as NSString
        let start = text.range(of: "A good document").location
        XCTAssertNotEqual(start, NSNotFound)
        let selection = try XCTUnwrap(page.selection(for: NSRange(location: start, length: 150)))
        host.pdfView.setCurrentSelection(selection, animate: false)
        let snapshot = try XCTUnwrap(ReaderTextSelection(in: host.pdfView))
        XCTAssertGreaterThan(snapshot.lineRects.count, 1)
        for rect in snapshot.lineRects {
            let inside = CGPoint(x: rect.midX, y: rect.midY)
            XCTAssertTrue(snapshot.contains(inside))
            host.pdfView.clearSelection() // Simulate PDFKit handling its tap first.
            host.handlePageTap(at: inside, selectionAtStart: snapshot)
            XCTAssertNotNil(host.pdfView.currentSelection)
            XCTAssertTrue(host.session.selectionAvailable)
            XCTAssertTrue(host.session.chromeVisible)
        }
        let union = snapshot.lineRects.reduce(CGRect.null) { $0.union($1) }
        let shortLine = try XCTUnwrap(snapshot.lineRects.min(by: { $0.maxX < $1.maxX }))
        let besideShortLine = CGPoint(x: union.maxX - 1, y: shortLine.midY)
        XCTAssertGreaterThan(besideShortLine.x, shortLine.maxX)
        XCTAssertFalse(snapshot.contains(besideShortLine), "Do not use one bounding box for multiple lines")
        host.session.setReaderInteraction(active: true)
        host.handlePageTap(at: .zero, selectionAtStart: snapshot)
        XCTAssertNotNil(host.pdfView.currentSelection)
        host.session.setReaderInteraction(active: false)
        host.handlePageTap(at: .zero, selectionAtStart: snapshot)
        XCTAssertNotNil(host.pdfView.currentSelection, "A tap during the settling interval must not deselect")
        host.session.markupVisible = true
        host.session.tool = .pen
        host.session.finishMarkup()
        XCTAssertNil(host.pdfView.currentSelection)
        XCTAssertFalse(host.session.selectionAvailable)
        XCTAssertFalse(host.session.markupVisible)
        XCTAssertEqual(host.session.tool, .read)
    }

    func testPageMarkerLayoutSnapshots() async throws {
        for (page, typeSize, size) in [
            (1, DynamicTypeSize.large, CGSize(width: 390, height: 660)),
            (12, .large, CGSize(width: 390, height: 660)),
            (123, .large, CGSize(width: 390, height: 660)),
            (1234, .large, CGSize(width: 390, height: 660)),
            (1234, .accessibility5, CGSize(width: 390, height: 660)),
            (1234, .accessibility5, CGSize(width: 844, height: 250))
        ] {
            let document = LibraryDocument(fingerprint: "layout", title: "Layout", fileName: "", pageCount: page, byteCount: 0)
            let session = ReaderSession(record: document, store: store)
            session.ready = true
            session.currentPage = page - 1
            session.scrollActivity()
            let host = UIHostingController(rootView: PageScrubber(session: session, jump: {})
                .frame(width: size.width, height: size.height)
                .background(.white).environment(\.dynamicTypeSize, typeSize)
                .transaction { $0.disablesAnimations = true }.ignoresSafeArea())
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            let container = UIViewController()
            window.rootViewController = container
            container.addChild(host)
            host.view.frame = CGRect(origin: .zero, size: size)
            host.view.backgroundColor = .white
            container.view.addSubview(host.view)
            host.didMove(toParent: container)
            window.makeKeyAndVisible()
            defer { window.isHidden = true; previousKeyWindow?.makeKeyAndVisible() }
            try await Task.sleep(for: .milliseconds(100))
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
            }
            XCTAssertEqual(image.size, size)
            // Normalize to RGBA so unused alpha/padding bytes cannot make a blank image pass.
            let width = Int(size.width), height = Int(size.height)
            let bitmap = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            bitmap.draw(try XCTUnwrap(image.cgImage), in: CGRect(origin: .zero, size: size))
            let bytes = try XCTUnwrap(bitmap.data).assumingMemoryBound(to: UInt8.self)
            let darkPixels = (0..<(width * height)).filter { bytes[$0 * 4] < 128 && bytes[$0 * 4 + 1] < 128 && bytes[$0 * 4 + 2] < 128 }.count
            XCTAssertGreaterThan(darkPixels, 100, "Marker must render, not a blank white snapshot")
            let attachment = XCTAttachment(image: image)
            attachment.name = "Page marker \(page) \(typeSize) \(Int(size.width))"
            attachment.lifetime = .keepAlways
            add(attachment)
            session.close()
        }
    }

}
