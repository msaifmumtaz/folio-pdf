import SwiftUI
import PDFKit
import Observation
import os

enum ReaderTool: String, CaseIterable {
    case read, highlight, underline, strikeOut, pen, note, eraser
    var title: String {
        switch self {
        case .read: "Read"
        case .highlight: "Highlight"
        case .underline: "Underline"
        case .strikeOut: "Strikethrough"
        case .pen: "Pen"
        case .note: "Note"
        case .eraser: "Eraser"
        }
    }
    var symbol: String {
        switch self {
        case .read: "hand.draw"
        case .highlight: "highlighter"
        case .underline: "underline"
        case .strikeOut: "strikethrough"
        case .pen: "pencil.tip"
        case .note: "note.text"
        case .eraser: "eraser"
        }
    }
    var markupKind: MarkupKind? {
        switch self {
        case .highlight: .highlight
        case .underline: .underline
        case .strikeOut: .strikeOut
        default: nil
        }
    }
    var usesColor: Bool { markupKind != nil || self == .pen || self == .note }
}

struct NoteDraft: Identifiable {
    let id = UUID()
    let page: Int
    let point: CGPoint
    var existingID: UUID?
    var text = ""
}

struct SearchHit: Identifiable, Sendable {
    let id = UUID()
    let page: Int
    let excerpt: String
    let bounds: CGRect
}

@MainActor
protocol ReaderNavigating: AnyObject {
    func navigate(to index: Int, completion: @escaping () -> Void)
}

/// Owns a worker copy of the PDF for search and caches each page's text after the first
/// query, so later queries only scan memory. The actor serializes all access, so the
/// worker document is never touched concurrently, and it is never the displayed document.
actor SearchIndex {
    private let files: DocumentFiles
    private let source: DocumentSource
    private let password: String
    private var lease: DocumentAccess?
    private var document: PDFDocument?
    private var texts: [String?] = []
    private var extracted: [Bool] = []
    private(set) var textExtractionCount = 0

    init(files: DocumentFiles, source: DocumentSource, password: String) {
        self.files = files; self.source = source; self.password = password
    }

    func search(_ query: String, limit: Int = 200) throws -> [SearchHit] {
        let document = try openIfNeeded()
        var hits: [SearchHit] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let string = text(at: index, in: document) else { continue }
            let ns = string as NSString
            var range = NSRange(location: 0, length: ns.length)
            while range.length > 0 && hits.count < limit {
                let match = ns.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: range)
                if match.location == NSNotFound { break }
                let start = max(0, match.location - 35), end = min(ns.length, NSMaxRange(match) + 65)
                let page = document.page(at: index)
                hits.append(SearchHit(page: index, excerpt: ns.substring(with: NSRange(location: start, length: end - start)),
                    bounds: page.flatMap { $0.selection(for: match)?.bounds(for: $0) } ?? page?.bounds(for: .cropBox) ?? .zero))
                range = NSRange(location: NSMaxRange(match), length: ns.length - NSMaxRange(match))
            }
            if hits.count >= limit { break }
        }
        return hits
    }

    private func text(at index: Int, in document: PDFDocument) -> String? {
        if extracted[index] { return texts[index] }
        let value = document.page(at: index)?.string
        textExtractionCount += 1
        texts[index] = value; extracted[index] = true
        return value
    }

    private func openIfNeeded() throws -> PDFDocument {
        if let document { return document }
        let lease = try files.access(source)
        let opened = try lease.coordinate { url -> PDFDocument in
            guard let document = PDFDocument(url: url) else { throw FolioError.invalidPDF }
            if document.isLocked && !document.unlock(withPassword: password) { throw FolioError.passwordRequired }
            return document
        }
        self.lease = lease
        document = opened
        texts = Array(repeating: nil, count: opened.pageCount)
        extracted = Array(repeating: false, count: opened.pageCount)
        return opened
    }
}

@MainActor @Observable
final class ReaderSession {
    let record: LibraryDocument
    let store: LibraryStore
    let readingMode: AppPreferences.ReadingMode
    private let soundEnabled: Bool
    private let soundVolume: Double
    @ObservationIgnored private let pageTurnSound: any PageTurnSoundPlaying
    @ObservationIgnored weak var navigation: (any ReaderNavigating)?
    @ObservationIgnored private var sceneActive = true
    @ObservationIgnored private var pendingNavigationID: UUID?
    @ObservationIgnored private var persistPendingNavigation = false
    var pdf: PDFDocument?
    weak var pdfView: PDFView?
    var marks: [Markup] = []
    var currentPage = 0
    var ready = false
    var loading = false
    var requiresPassword = false
    var password = ""
    var error: String?
    var saveError: String?
    var tool: ReaderTool = .read
    var color: InkColor = .gold
    var lineWidth: Double = 3
    var chromeVisible = true {
        didSet {
            if readingMode == .flip && !chromeVisible { chromeVisible = true; return }
            guard oldValue != chromeVisible else { return }
            if chromeVisible { scrollActivity() }
            else { handleTask?.cancel(); scrollHandleVisible = false }
        }
    }
    var markupVisible = false
    var noteDraft: NoteDraft?
    var selectedMarkID: UUID?
    var selectionAvailable = false
    var searchResults: [SearchHit] = []
    var searching = false
    var sourceChanged = false
    var isScrubbing = false {
        didSet { if oldValue != isScrubbing { lastReaderInteraction = ProcessInfo.processInfo.systemUptime } }
    }
    var readerInteractionActive = false
    @ObservationIgnored private(set) var lastReaderInteraction = -Double.infinity
    var pageMarkerVisible: Bool { readingMode == .verticalScroll && chromeVisible && (scrollHandleVisible || isScrubbing || readerInteractionActive) }

    var scrollHandleVisible = false
    var drawingStroke = false
    @ObservationIgnored private var handleTask: Task<Void, Never>?
    @ObservationIgnored private var accessLease: DocumentAccess?
    private var persistedMarks: [Markup] = []
    @ObservationIgnored private var sourcePresenter: DocumentPresenter?
    @ObservationIgnored private var sourceCheck: Task<Void, Never>?
    var exporting = false
    var isSaving = false
    var undoStack: [[Markup]] = []
    var redoStack: [[Markup]] = []
    private var revision = 0
    private var savedRevision = 0
    private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchIndex: SearchIndex?
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    private var openedAt = ContinuousClock.now
    private let logger = Logger(subsystem: "com.folio.pdf", category: "Reader")

    init(record: LibraryDocument, store: LibraryStore, preferences: AppPreferences? = nil,
         soundPlayer: (any PageTurnSoundPlaying)? = nil) {
        self.record = record
        self.store = store
        readingMode = preferences?.readingMode ?? .verticalScroll
        soundEnabled = preferences?.pageTurnSoundEnabled ?? false
        soundVolume = preferences?.pageTurnSoundVolume ?? 0.5
        pageTurnSound = soundPlayer ?? PageTurnSound()
        currentPage = record.lastPage
    }

    deinit { sourcePresenter?.invalidate(); sourceCheck?.cancel(); handleTask?.cancel(); progressTask?.cancel(); searchTask?.cancel() }

    var allowsMarkup: Bool { pdf?.allowsCommenting == true }
    var isBookmarked: Bool { record.bookmarks.contains(currentPage) }
    var selectedMark: Markup? { marks.first { $0.id == selectedMarkID } }
    var hasUnsavedChanges: Bool { revision != savedRevision }

    func open() async {
        guard !loading else { return }
        loading = true
        closeSearch(); searchIndex = nil
        sourceChanged = false
        store.activeSession = self
        error = nil
        openedAt = .now
        defer { loading = false }
        do {
            let loaded = try await store.files.load(source: record.source, id: record.id,
                                                   password: password.isEmpty ? nil : password)
            try Task.checkCancellation()
            accessLease = loaded.access
            if case .external = record.source, let url = loaded.access?.url {
                sourcePresenter?.invalidate()
                sourcePresenter = DocumentPresenter(url: url) { [weak self] url in
                    Task { @MainActor [weak self] in self?.sourceDidChange(url) }
                }
            }
            if let bookmark = loaded.access?.refreshedBookmark { record.sourceBookmark = bookmark }
            marks = loaded.marks
            persistedMarks = loaded.marks
            pdf = loaded.document
            requiresPassword = false
            store.opened(record, pageCount: loaded.document.pageCount)
            currentPage = record.lastPage
        } catch FolioError.passwordRequired {
            requiresPassword = true
        } catch FolioError.wrongPassword {
            requiresPassword = true
            error = FolioError.wrongPassword.localizedDescription
        } catch FolioError.sourceChanged {
            sourceChanged = true
            error = FolioError.sourceChanged.localizedDescription
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription }
    }

    func restored() {
        guard !ready else { return }
        ready = true
        scrollActivity()
        logger.info("Reader ready in \(String(describing: self.openedAt.duration(to: .now)), privacy: .public), \(self.record.pageCount) pages")
    }

    func pageChanged() {
        guard ready, let pdf, let page = pdfView?.currentPage else { return }
        let index = pdf.index(for: page)
        guard index != NSNotFound, index != currentPage else { return }
        commitPage(index)
    }

    func commitPage(_ index: Int, persist: Bool = true) {
        guard let pdf, (0..<pdf.pageCount).contains(index) else { return }
        currentPage = index
        selectedMarkID = nil
        if persist && !isScrubbing {
            record.lastPage = index
            record.lastOpenedAt = .now
            progressTask?.cancel()
            progressTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.saveProgressImmediately()
            }
        }
        scrollActivity()
    }

    private func saveProgressImmediately() {
        progressTask?.cancel(); progressTask = nil
        store.saveProgress(record)
    }

    func go(to index: Int, persist: Bool = true, completion: (() -> Void)? = nil) {
        guard let page = pdf?.page(at: index) else { return }
        let requestID = UUID()
        pendingNavigationID = requestID
        let finished = { [weak self] in
            guard let self, self.pendingNavigationID == requestID else { return }
            self.commitPage(index, persist: persist || self.persistPendingNavigation)
            if self.persistPendingNavigation { self.saveProgressImmediately() }
            self.pendingNavigationID = nil
            self.persistPendingNavigation = false
            completion?()
        }
        if let navigation { navigation.navigate(to: index, completion: finished) }
        else { pdfView?.go(to: page); finished() }
    }

    func completedPageTurn(to index: Int) {
        guard ready, readingMode == .flip, index != currentPage,
              let pdf, (0..<pdf.pageCount).contains(index) else { return }
        clearTextSelection()
        commitPage(index)
        if soundEnabled && sceneActive { pageTurnSound.play(volume: soundVolume) }
    }

    func setSceneActive(_ active: Bool) {
        sceneActive = active
        if !active { pageTurnSound.stop() }
    }

    func acceptsPageTap(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        ready && !isScrubbing && !readerInteractionActive && time - lastReaderInteraction >= 0.25
    }

    func setReaderInteraction(active: Bool) {
        if active { lastReaderInteraction = ProcessInfo.processInfo.systemUptime }
        guard readerInteractionActive != active else { return }
        readerInteractionActive = active
        if active {
            handleTask?.cancel()
            scrollHandleVisible = true
        } else {
            lastReaderInteraction = ProcessInfo.processInfo.systemUptime
            scrollActivity()
        }
    }

    func scrollActivity() {
        guard ready, chromeVisible else { return }
        scrollHandleVisible = true
        handleTask?.cancel()
        guard !readerInteractionActive, !isScrubbing else { return }
        handleTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
            if self?.isScrubbing == false && self?.readerInteractionActive == false { self?.scrollHandleVisible = false }
        }
    }

    func endScrub() {
        isScrubbing = false
        if pendingNavigationID != nil { persistPendingNavigation = true }
        record.lastPage = currentPage
        record.lastOpenedAt = .now
        saveProgressImmediately()
        scrollActivity()
    }

    func close() {
        if ready { saveProgressImmediately() }
        pageTurnSound.stop()
        pendingNavigationID = nil
        persistPendingNavigation = false
        navigation = nil
        closeSearch(); handleTask?.cancel()
        searchIndex = nil
        let thumbnails = store.thumbnails
        Task { await thumbnails.releaseWorkerDocument() }
        pdfView?.document = nil
        pdf = nil
        accessLease = nil
        sourceCheck?.cancel(); sourcePresenter?.invalidate(); sourcePresenter = nil
    }

    private func sourceDidChange(_ url: URL) {
        sourceCheck?.cancel()
        sourceCheck = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                guard let self else { return }
                let reference = try await self.store.files.referencePDF(from: url)
                try Task.checkCancellation()
                if reference.fingerprint != self.record.fingerprint {
                    _ = await self.flush()
                    self.sourceChanged = true
                    self.error = FolioError.sourceChanged.localizedDescription
                    self.ready = false; self.pdf = nil; self.chromeVisible = true
                } else {
                    self.record.sourceBookmark = reference.bookmark
                    self.record.sourcePath = reference.path
                    self.store.persist()
                }
            } catch is CancellationError {
            } catch {
                self?.error = "The original is temporarily unavailable. Your reading data is saved; retry or locate the PDF in Files."
                self?.chromeVisible = true
            }
        }
    }

    func mergeRemoteAnnotations() async {
        guard ready, !drawingStroke, !isScrubbing, noteDraft == nil, !hasUnsavedChanges,
              let sync = store.sync, sync.hasAnnotationHistory(record.fingerprint) else { return }
        let remote = sync.remoteMarks(for: record.fingerprint)
        guard remote != marks.sorted(by: { $0.id.uuidString < $1.id.uuidString }) else { return }
        apply(remote, save: false)
        undoStack = []; redoStack = []
        do {
            try await store.files.saveMarks(remote, id: record.id)
            persistedMarks = remote
        } catch { saveError = error.localizedDescription }
    }

    func choose(_ newTool: ReaderTool) {
        tool = newTool
        selectedMarkID = nil
        if let kind = newTool.markupKind, pdfView?.currentSelection?.string?.isEmpty == false {
            applySelection(kind)
        }
    }

    func clearTextSelection() {
        pdfView?.clearSelection()
        selectionAvailable = false
    }

    func finishMarkup() {
        clearTextSelection()
        choose(.read)
        markupVisible = false
    }

    func applySelection(_ kind: MarkupKind? = nil) {
        guard allowsMarkup, let pdf, let selection = pdfView?.currentSelection,
              let kind = kind ?? tool.markupKind else { return }
        var additions: [Markup] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let index = pdf.index(for: page)
                let bounds = line.bounds(for: page)
                if index != NSNotFound && !bounds.isEmpty && !bounds.isInfinite {
                    additions.append(Markup(page: index, kind: kind, bounds: bounds, color: color))
                }
            }
        }
        guard !additions.isEmpty else { return }
        edit(marks + additions)
        clearTextSelection()
    }

    func addStroke(points: [CGPoint], page: Int) {
        guard allowsMarkup, let first = points.first else { return }
        var bounds = CGRect(origin: first, size: .zero)
        for point in points { bounds = bounds.union(CGRect(origin: point, size: CGSize(width: 0.01, height: 0.01))) }
        bounds = bounds.insetBy(dx: -lineWidth, dy: -lineWidth)
        edit(marks + [Markup(page: page, kind: .ink, bounds: bounds, points: points, color: color, width: lineWidth)])
    }

    func saveNote(_ draft: NoteDraft, text: String) {
        guard allowsMarkup else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var updated = marks
        if let id = draft.existingID, let index = updated.firstIndex(where: { $0.id == id }) {
            updated[index].text = text
        } else {
            updated.append(Markup(page: draft.page, kind: .note,
                bounds: CGRect(x: draft.point.x, y: draft.point.y, width: 28, height: 28), color: color, text: text))
        }
        edit(updated)
    }

    func deleteSelected() {
        guard allowsMarkup, let selectedMarkID else { return }
        edit(marks.filter { $0.id != selectedMarkID })
        self.selectedMarkID = nil
    }

    func erase(at point: CGPoint, page: Int, tolerance: CGFloat) {
        guard allowsMarkup else { return }
        if let mark = marks.last(where: { $0.page == page && $0.kind == .ink && Self.hits($0, point: point, tolerance: tolerance) }) {
            edit(marks.filter { $0.id != mark.id })
        }
    }

    static func hits(_ mark: Markup, point: CGPoint, tolerance: CGFloat) -> Bool {
        guard mark.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return false }
        guard mark.kind == .ink else { return true }
        if mark.points.count == 1, let first = mark.points.first {
            return hypot(first.x - point.x, first.y - point.y) <= tolerance + mark.width
        }
        for (a, b) in zip(mark.points, mark.points.dropFirst()) {
            let dx = b.x - a.x, dy = b.y - a.y
            let length = dx * dx + dy * dy
            let t = length == 0 ? 0 : min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length))
            if hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy)) <= tolerance + mark.width / 2 { return true }
        }
        return false
    }

    func tap(at point: CGPoint, page: Int) -> Bool {
        if tool == .note && allowsMarkup {
            noteDraft = NoteDraft(page: page, point: point)
            return true
        }
        if tool == .eraser { erase(at: point, page: page, tolerance: 10 / (pdfView?.scaleFactor ?? 1)); return true }
        if let mark = marks.last(where: { $0.page == page && Self.hits($0, point: point, tolerance: 6 / (pdfView?.scaleFactor ?? 1)) }) {
            selectedMarkID = mark.id
            chromeVisible = true
            if mark.kind == .note {
                noteDraft = NoteDraft(page: page, point: mark.bounds.origin, existingID: mark.id, text: mark.text)
            }
            return true
        }
        selectedMarkID = nil
        return false
    }

    func undo() {
        guard allowsMarkup, let previous = undoStack.popLast() else { return }
        redoStack.append(marks)
        apply(previous)
    }

    func redo() {
        guard allowsMarkup, let next = redoStack.popLast() else { return }
        undoStack.append(marks)
        apply(next)
    }

    private func edit(_ updated: [Markup]) {
        guard allowsMarkup else { return }
        undoStack.append(marks)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
        apply(updated)
    }

    private func apply(_ updated: [Markup], save: Bool = true) {
        guard let pdf else { return }
        let old = Dictionary(uniqueKeysWithValues: marks.map { ($0.id, $0) })
        let new = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) })
        for mark in marks where new[mark.id] != mark {
            guard let page = pdf.page(at: mark.page) else { continue }
            for annotation in page.annotations where annotation.value(forAnnotationKey: .name) as? String == mark.id.uuidString {
                if let popup = annotation.popup { page.removeAnnotation(popup) }
                page.removeAnnotation(annotation)
            }
        }
        for mark in updated where old[mark.id] != mark {
            pdf.page(at: mark.page)?.addAnnotation(mark.annotation())
        }
        marks = updated
        if save { revision += 1; queueSave() }
    }

    private func queueSave() {
        let snapshot = marks
        let version = revision
        let previous = saveTask
        let store = store
        let record = record
        isSaving = true
        // Serialize snapshots so an older save can never overwrite a newer edit.
        saveTask = Task { [weak self] in
            await previous?.value
            do {
                let previousMarks = self?.persistedMarks ?? []
                try await store.saveMarks(snapshot, for: record, previous: previousMarks)
                guard let self else { return }
                self.persistedMarks = snapshot
                self.savedRevision = version
                if self.revision == version { self.saveError = nil; self.isSaving = false }
            } catch {
                guard let self else { return }
                self.saveError = "Your latest markup hasn’t saved. \(error.localizedDescription)"
                self.isSaving = false
            }
        }
    }

    func flush() async -> Bool {
        if hasUnsavedChanges { queueSave() }
        await saveTask?.value
        if ready {
            record.lastPage = currentPage
            saveProgressImmediately()
        }
        else { store.persist() }
        return !hasUnsavedChanges && store.error == nil
    }

    func retrySave() { queueSave() }

    func export() async -> URL? {
        guard !exporting else { return nil }
        exporting = true
        defer { exporting = false }
        guard await flush() else { return nil }
        do {
            return try await store.files.export(source: record.source, title: record.title,
                                               marks: marks, password: password.isEmpty ? nil : password)
        } catch { self.error = error.localizedDescription; return nil }
    }

    func search(_ text: String) {
        searchTask?.cancel()
        searchResults = []
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { searching = false; return }
        searching = true
        let index = searchIndex ?? SearchIndex(files: store.files, source: record.source, password: password)
        searchIndex = index
        searchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                let results = try await index.search(query)
                try Task.checkCancellation()
                searchResults = results
                searching = false
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription; searching = false }
        }
    }

    func show(_ hit: SearchHit) {
        go(to: hit.page) { [weak self] in
            guard let self, let page = self.pdf?.page(at: hit.page), let selection = page.selection(for: hit.bounds) else { return }
            self.pdfView?.setCurrentSelection(selection, animate: false)
            self.pdfView?.go(to: selection)
        }
    }

    func closeSearch() { searchTask?.cancel(); searching = false }
}
