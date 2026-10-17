import XCTest
import PDFKit
import AVFAudio
@testable import Folio

@MainActor
private final class PageSoundSpy: PageTurnSoundPlaying {
    var volumes: [Double] = []
    var stopCount = 0
    func play(volume: Double) { volumes.append(volume) }
    func stop() { stopCount += 1 }
}

private actor DelayedAudioEngine: PageTurnAudioHandling {
    private let started: XCTestExpectation
    private let stopped: XCTestExpectation
    private let played: XCTestExpectation?
    private var activation: CheckedContinuation<Void, Never>?
    private var firstActivation = true
    private var reportedStop = false
    private var executing = 0
    private(set) var maximumConcurrentCalls = 0
    private(set) var volumes: [Double] = []
    private(set) var executedOnMainThread = false

    init(started: XCTestExpectation, stopped: XCTestExpectation, played: XCTestExpectation? = nil) {
        self.started = started
        self.stopped = stopped
        self.played = played
    }

    func play(volume: Double) async {
        executedOnMainThread = executedOnMainThread || Thread.isMainThread
        executing += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, executing)
        defer { executing -= 1 }
        if firstActivation {
            firstActivation = false
            await withCheckedContinuation { continuation in
                activation = continuation
                started.fulfill()
            }
        }
        guard !Task.isCancelled else { return }
        volumes.append(volume)
        played?.fulfill()
    }

    func releaseActivation() { activation?.resume(); activation = nil }
    func stop() {
        executedOnMainThread = executedOnMainThread || Thread.isMainThread
        if !reportedStop { reportedStop = true; stopped.fulfill() }
    }
}

extension FolioTests {
    func testPageSoundStopCancelsPendingActivationWithoutLatePlayback() async {
        let started = expectation(description: "Activation started")
        let stopped = expectation(description: "Audio cleanup finished")
        let engine = DelayedAudioEngine(started: started, stopped: stopped)
        let sound = PageTurnSound(engine: engine)
        sound.play(volume: 0.5)
        await fulfillment(of: [started], timeout: 2)
        sound.stop()
        await engine.releaseActivation()
        await fulfillment(of: [stopped], timeout: 2)
        let volumes = await engine.volumes
        XCTAssertTrue(volumes.isEmpty)
        let mainThread = await engine.executedOnMainThread
        XCTAssertFalse(mainThread)
    }

    func testRapidPageSoundsSerializeAndOnlyLatestPendingTurnPlays() async {
        let started = expectation(description: "Activation started")
        let stopped = expectation(description: "Audio cleanup finished")
        let played = expectation(description: "Latest turn played")
        let engine = DelayedAudioEngine(started: started, stopped: stopped, played: played)
        let sound = PageTurnSound(engine: engine)
        sound.play(volume: 0.2)
        await fulfillment(of: [started], timeout: 2)
        sound.play(volume: 0.4)
        sound.play(volume: 0.8)
        await engine.releaseActivation()
        await fulfillment(of: [played], timeout: 2)
        sound.stop()
        await fulfillment(of: [stopped], timeout: 2)
        let volumes = await engine.volumes
        let concurrency = await engine.maximumConcurrentCalls
        XCTAssertEqual(volumes, [0.8])
        XCTAssertEqual(concurrency, 1)
        let mainThread = await engine.executedOnMainThread
        XCTAssertFalse(mainThread)
    }

    private func readingPreferences() -> (AppPreferences, UserDefaults) {
        let suite = "ReadingPreferences-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (AppPreferences(defaults: defaults), defaults)
    }

    private func bookReader(savedPage: Int = 0, reduceMotion: Bool = true) async throws
        -> (ReaderSession, BookPDFController, PageSoundSpy) {
        let (preferences, _) = readingPreferences()
        preferences.readingMode = .flip
        preferences.pageTurnSoundEnabled = true
        preferences.pageTurnSoundVolume = 0.65
        let record = try await imported(fixture(pages: 25))
        store.savePage(savedPage, for: record)
        let sound = PageSoundSpy()
        let session = ReaderSession(record: record, store: store, preferences: preferences, soundPlayer: sound)
        await session.open()
        let book = BookPDFController(session: session, reduceMotion: reduceMotion)
        book.loadViewIfNeeded()
        book.view.frame = CGRect(x: 0, y: 0, width: 390, height: 650)
        book.view.setNeedsLayout()
        book.view.layoutIfNeeded()
        XCTAssertTrue(session.ready)
        return (session, book, sound)
    }

    func testReadingPreferencesDefaultAndPersistAcrossModeChanges() {
        let (preferences, defaults) = readingPreferences()
        XCTAssertEqual(preferences.readingMode, .verticalScroll)
        XCTAssertFalse(preferences.pageTurnSoundEnabled)
        XCTAssertEqual(preferences.pageTurnSoundVolume, 0.5)
        preferences.readingMode = .flip
        preferences.pageTurnSoundEnabled = true
        preferences.pageTurnSoundVolume = 0.75
        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.readingMode, .flip)
        XCTAssertTrue(restored.pageTurnSoundEnabled)
        XCTAssertEqual(restored.pageTurnSoundVolume, 0.75)
        restored.readingMode = .verticalScroll
        let scroll = AppPreferences(defaults: defaults)
        XCTAssertEqual(scroll.readingMode, .verticalScroll)
        XCTAssertTrue(scroll.pageTurnSoundEnabled)
        XCTAssertEqual(scroll.pageTurnSoundVolume, 0.75)
    }

    func testInvalidReadingPreferencesHaveSafeFallbacks() {
        let (preferences, defaults) = readingPreferences()
        defaults.set("unknown-mode", forKey: "readingMode")
        defaults.set("broken", forKey: "pageTurnSoundVolume")
        XCTAssertEqual(AppPreferences(defaults: defaults).readingMode, .verticalScroll)
        XCTAssertEqual(AppPreferences(defaults: defaults).pageTurnSoundVolume, 0.5)
        defaults.set(1.8, forKey: "pageTurnSoundVolume")
        XCTAssertEqual(AppPreferences(defaults: defaults).pageTurnSoundVolume, 1)
        defaults.set(-0.4, forKey: "pageTurnSoundVolume")
        XCTAssertEqual(AppPreferences(defaults: defaults).pageTurnSoundVolume, 0)
        preferences.pageTurnSoundVolume = .nan
        XCTAssertEqual(preferences.pageTurnSoundVolume, 0.5)
        XCTAssertEqual(AppPreferences(defaults: defaults).pageTurnSoundVolume, 0.5)
    }

    func testBookRestoresSavedPageAndPreloadingDoesNotOwnSession() async throws {
        let (session, book, sound) = try await bookReader(savedPage: 13, reduceMotion: false)
        defer { book.tearDown(); session.close() }
        let active = try XCTUnwrap(book.currentCanvas)
        let neighbor = try XCTUnwrap(book.canvas(at: 14))
        neighbor.loadViewIfNeeded()
        neighbor.view.frame = active.view.frame
        neighbor.view.layoutIfNeeded()
        XCTAssertTrue(session.pdfView === active.pdfView)
        XCTAssertEqual(session.currentPage, 13)
        XCTAssertEqual(session.record.lastPage, 13)
        neighbor.tearDown()
        XCTAssertTrue(session.pdfView === active.pdfView)
        XCTAssertTrue(sound.volumes.isEmpty)
        book.view.frame = CGRect(x: 0, y: 0, width: 650, height: 390)
        book.view.layoutIfNeeded()
        XCTAssertEqual(session.currentPage, 13)
        XCTAssertEqual(session.record.lastPage, 13)
        XCTAssertEqual(book.pager.spineLocation, .min)
        XCTAssertFalse(book.pager.isDoubleSided)
        book.view.frame = CGRect(x: 0, y: 0, width: 390, height: 650)
        book.view.layoutIfNeeded()
        XCTAssertEqual(active.pdfView.scaleFactor, active.pdfView.scaleFactorForSizeToFit, accuracy: 0.02)
    }

    func testBookCurlFitsCropBoxAndRotatedPagesInBothOrientations() async throws {
        let (session, book, sound) = try await bookReader()
        defer { book.tearDown(); session.close() }
        let page = try XCTUnwrap(session.pdf?.page(at: 0))
        let canvas = try XCTUnwrap(book.currentCanvas)
        for size in [CGSize(width: 390, height: 650), CGSize(width: 650, height: 390)] {
            book.view.frame.size = size
            book.view.setNeedsLayout()
            book.view.layoutIfNeeded()
            let paper = canvas.pdfView.convert(page.bounds(for: .cropBox), from: page)
            XCTAssertEqual(paper.width, book.pager.view.bounds.width, accuracy: 1)
            XCTAssertEqual(paper.height, book.pager.view.bounds.height, accuracy: 1)
            XCTAssertEqual(paper.minX, 0, accuracy: 1)
            XCTAssertEqual(paper.minY, 0, accuracy: 1)
            XCTAssertEqual(book.pager.view.frame.midX, book.view.bounds.midX, accuracy: 0.01)
            XCTAssertEqual(book.pager.view.frame.midY, book.view.bounds.midY, accuracy: 0.01)
            XCTAssertLessThan(book.pager.view.frame.width * book.pager.view.frame.height, size.width * size.height)
        }
        let cropped = PDFPage()
        cropped.setBounds(CGRect(x: 0, y: 0, width: 600, height: 800), for: .mediaBox)
        cropped.setBounds(CGRect(x: 50, y: 90, width: 300, height: 500), for: .cropBox)
        let bounds = CGRect(x: 0, y: 0, width: 650, height: 390)
        let portrait = BookPDFController.pageFrame(for: cropped, in: bounds)
        XCTAssertEqual(portrait.width / portrait.height, 300.0 / 500, accuracy: 0.001)
        cropped.rotation = 90
        let rotated = BookPDFController.pageFrame(for: cropped, in: bounds)
        XCTAssertEqual(rotated.width / rotated.height, 500.0 / 300, accuracy: 0.001)
        XCTAssertEqual(rotated.midX, bounds.midX, accuracy: 0.01)
        XCTAssertEqual(rotated.midY, bounds.midY, accuracy: 0.01)
        XCTAssertTrue(sound.volumes.isEmpty)
    }

    func testCurlOffersOnlyOneNeighborPerDirectionAndRefreshesAfterTurn() async throws {
        let (session, book, sound) = try await bookReader(savedPage: 5, reduceMotion: false)
        defer { book.tearDown(); session.close() }
        let active = try XCTUnwrap(book.currentCanvas)
        let next = try XCTUnwrap(book.pageViewController(book.pager, viewControllerAfter: active))
        let previous = try XCTUnwrap(book.pageViewController(book.pager, viewControllerBefore: active))
        XCTAssertNil(book.pageViewController(book.pager, viewControllerAfter: next))
        XCTAssertNil(book.pageViewController(book.pager, viewControllerBefore: previous))
        book.pageViewController(book.pager, willTransitionTo: [next])
        XCTAssertFalse(book.turnPage(forward: true))
        XCTAssertNil(book.pageViewController(book.pager, viewControllerAfter: next))
        book.pager.setViewControllers([next], direction: .forward, animated: false)
        book.pageViewController(book.pager, didFinishAnimating: true, previousViewControllers: [active], transitionCompleted: true)
        XCTAssertEqual(session.currentPage, 6)
        XCTAssertEqual(sound.volumes, [0.65])
        let following = try XCTUnwrap(book.pageViewController(book.pager, viewControllerAfter: next) as? PDFHostController)
        XCTAssertEqual(following.fixedPage, 7)
        XCTAssertNil(book.pageViewController(book.pager, viewControllerAfter: following))
    }

    func testCanceledCurlDoesNotSaveOrPlaySound() async throws {
        let (session, book, sound) = try await bookReader(reduceMotion: false)
        defer { book.tearDown(); session.close() }
        let active = try XCTUnwrap(book.currentCanvas)
        let next = try XCTUnwrap(book.pageViewController(book.pager, viewControllerAfter: active))
        book.pageViewController(book.pager, willTransitionTo: [next])
        XCTAssertTrue(session.readerInteractionActive)
        XCTAssertLessThan(book.pager.view.alpha, 1)
        book.pageViewController(book.pager, didFinishAnimating: true, previousViewControllers: [active], transitionCompleted: false)
        XCTAssertEqual(session.currentPage, 0)
        XCTAssertEqual(session.record.lastPage, 0)
        XCTAssertTrue(session.pdfView === active.pdfView)
        XCTAssertFalse(session.readerInteractionActive)
        XCTAssertEqual(book.pager.view.alpha, 1)
        XCTAssertTrue(sound.volumes.isEmpty)
    }

    func testCompletedCurlCommitsOnceAndSearchUsesDestinationCanvas() async throws {
        let (session, book, sound) = try await bookReader(reduceMotion: false)
        defer { book.tearDown(); session.close() }
        let old = try XCTUnwrap(book.currentCanvas)
        let next = try XCTUnwrap(book.canvas(at: 1))
        book.pageViewController(book.pager, willTransitionTo: [next])
        book.pager.setViewControllers([next], direction: .forward, animated: false)
        book.pageViewController(book.pager, didFinishAnimating: true, previousViewControllers: [old], transitionCompleted: true)
        XCTAssertEqual(session.currentPage, 1)
        XCTAssertEqual(session.record.lastPage, 1)
        XCTAssertTrue(session.pdfView === next.pdfView)
        XCTAssertEqual(sound.volumes, [0.65])
        XCTAssertEqual(book.pager.view.alpha, 1)
        session.completedPageTurn(to: 1)
        XCTAssertEqual(sound.volumes.count, 1)
        let page = try XCTUnwrap(session.pdf?.page(at: 13))
        let selection = try XCTUnwrap(page.selection(for: page.bounds(for: .cropBox)))
        session.show(SearchHit(page: 13, excerpt: "", bounds: selection.bounds(for: page)))
        XCTAssertEqual(session.currentPage, 13)
        XCTAssertEqual(book.currentCanvas?.fixedPage, 13)
        XCTAssertNotNil(session.pdfView?.currentSelection)
        XCTAssertEqual(sound.volumes.count, 1)
    }

    func testBookPageBoundariesAndReducedMotionTurns() async throws {
        let (session, book, sound) = try await bookReader()
        defer { book.tearDown(); session.close() }
        XCTAssertNil(book.pager.dataSource)
        XCTAssertFalse(book.turnPage(forward: false))
        XCTAssertTrue(book.turnPage(forward: true))
        XCTAssertEqual(session.currentPage, 1)
        XCTAssertTrue(book.turnPage(forward: false))
        XCTAssertEqual(session.currentPage, 0)
        session.go(to: 24)
        XCTAssertFalse(book.turnPage(forward: true))
        session.go(to: -1)
        session.go(to: 25)
        XCTAssertEqual(session.currentPage, 24)
        XCTAssertEqual(sound.volumes.count, 2)
        XCTAssertEqual(book.pager.view.alpha, 1)
    }

    func testScrubbingAndInternalLinksStaySilentInBookMode() async throws {
        let (session, book, sound) = try await bookReader()
        defer { book.tearDown(); session.close() }
        session.isScrubbing = true
        session.go(to: 8, persist: false)
        XCTAssertEqual(book.currentCanvas?.fixedPage, 8)
        XCTAssertEqual(session.record.lastPage, 0)
        session.endScrub()
        XCTAssertEqual(session.record.lastPage, 8)
        let page = try XCTUnwrap(session.pdf?.page(at: 17))
        session.pdfView?.go(to: PDFDestination(page: page, at: CGPoint(x: 50, y: 600)))
        XCTAssertEqual(book.currentCanvas?.fixedPage, 17)
        XCTAssertEqual(session.currentPage, 17)
        XCTAssertTrue(sound.volumes.isEmpty)
    }

    func testScrubQueuedDuringCurlPersistsFinalDestination() async throws {
        let (session, book, sound) = try await bookReader(reduceMotion: false)
        defer { book.tearDown(); session.close() }
        let active = try XCTUnwrap(book.currentCanvas)
        let next = try XCTUnwrap(book.canvas(at: 1))
        book.pageViewController(book.pager, willTransitionTo: [next])
        session.isScrubbing = true
        session.go(to: 6, persist: false)
        session.go(to: 12, persist: false)
        session.endScrub()
        book.pageViewController(book.pager, didFinishAnimating: true, previousViewControllers: [active], transitionCompleted: false)
        XCTAssertEqual(session.currentPage, 12)
        XCTAssertEqual(session.record.lastPage, 12)
        XCTAssertEqual(book.currentCanvas?.fixedPage, 12)
        XCTAssertTrue(sound.volumes.isEmpty)
    }

    func testBookKeepsControlsVisibleAndHidesEdgeMarkerWhileSelectionDismisses() async throws {
        let (session, book, _) = try await bookReader()
        defer { book.tearDown(); session.close() }
        book.view.frame = CGRect(x: 0, y: 0, width: 650, height: 390)
        book.view.layoutIfNeeded()
        let canvas = try XCTUnwrap(book.currentCanvas)
        let margin = CGPoint(x: -5, y: canvas.pdfView.bounds.midY)
        XCTAssertNil(canvas.pdfView.page(for: margin, nearest: false))
        canvas.handlePageTap(at: margin, selectionAtStart: nil)
        XCTAssertTrue(session.chromeVisible)
        session.chromeVisible = false
        XCTAssertTrue(session.chromeVisible)
        XCTAssertFalse(session.pageMarkerVisible)
        let page = try XCTUnwrap(session.pdf?.page(at: 0))
        let bounds = page.bounds(for: .cropBox)
        canvas.handlePageTap(at: canvas.pdfView.convert(CGPoint(x: bounds.midX, y: bounds.midY), from: page), selectionAtStart: nil)
        XCTAssertTrue(session.chromeVisible)
        let selection = try XCTUnwrap(page.selection(for: page.bounds(for: .cropBox)))
        canvas.pdfView.setCurrentSelection(selection, animate: false)
        canvas.handlePageTap(at: margin, selectionAtStart: ReaderTextSelection(in: canvas.pdfView))
        XCTAssertNil(canvas.pdfView.currentSelection)
        XCTAssertTrue(session.chromeVisible)
        XCTAssertFalse(session.pageMarkerVisible)
    }

    func testSoundIsOffByDefaultAndOnlyEnabledForActiveFlipReader() async throws {
        let record = try await imported(fixture())
        let (preferences, _) = readingPreferences()
        let sound = PageSoundSpy()
        preferences.pageTurnSoundEnabled = true
        let scroll = ReaderSession(record: record, store: store, preferences: preferences, soundPlayer: sound)
        await scroll.open()
        scroll.restored()
        scroll.completedPageTurn(to: 1)
        XCTAssertTrue(sound.volumes.isEmpty)
        scroll.close()
        preferences.readingMode = .flip
        let flip = ReaderSession(record: record, store: store, preferences: preferences, soundPlayer: sound)
        await flip.open()
        flip.restored()
        flip.setSceneActive(false)
        flip.completedPageTurn(to: 1)
        XCTAssertTrue(sound.volumes.isEmpty)
        flip.setSceneActive(true)
        flip.completedPageTurn(to: 2)
        XCTAssertEqual(sound.volumes, [0.5])
        flip.go(to: 3)
        XCTAssertEqual(sound.volumes.count, 1)
        let stops = sound.stopCount
        flip.close()
        XCTAssertEqual(sound.stopCount, stops + 1)
        preferences.pageTurnSoundEnabled = false
        let silent = ReaderSession(record: record, store: store, preferences: preferences, soundPlayer: sound)
        await silent.open()
        silent.restored()
        silent.completedPageTurn(to: 0)
        XCTAssertEqual(sound.volumes.count, 1)
        silent.close()
    }

    func testBundledPaperSoundDecodes() throws {
        let url = try XCTUnwrap(PageTurnSound.resourceURL)
        XCTAssertEqual(url.lastPathComponent, "book-turn-page-sound.mp3")
        let player = try AVAudioPlayer(contentsOf: url)
        XCTAssertGreaterThan(player.duration, 0.8)
        XCTAssertLessThan(player.duration, 1.2)
        XCTAssertEqual(player.numberOfChannels, 2)
    }
}
