import SwiftData
import SwiftUI

@MainActor @Observable
final class LibraryStore {
    let context: ModelContext
    let files: DocumentFiles
    let thumbnails: DocumentFiles
    let root: URL
    var documents: [LibraryDocument] = []
    var folders: [LibraryFolder] = [] {
        didSet { foldersByID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
    }
    /// O(1) folder lookup for paths and graph checks; rebuilt whenever `folders` changes.
    @ObservationIgnored private(set) var foldersByID: [UUID: LibraryFolder] = [:]
    var error: String?
    var isImporting = false
    var selected: LibraryDocument?
    var fileRequest: FileRequest?
    var sync: ReadingSyncService?
    @ObservationIgnored weak var activeSession: ReaderSession?
    private var nextDocument: LibraryDocument?

    init(context: ModelContext, root: URL) {
        self.context = context
        self.root = root
        files = DocumentFiles(root: root)
        thumbnails = DocumentFiles(root: root)
        refresh()
    }

    func refresh() {
        do {
            documents = try context.fetch(FetchDescriptor<LibraryDocument>())
                .sorted { ($0.lastOpenedAt ?? $0.importedAt) > ($1.lastOpenedAt ?? $1.importedAt) }
            folders = try context.fetch(FetchDescriptor<LibraryFolder>())
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult func persist(capture: Bool = true) -> Bool {
        do {
            try context.save()
            if activeSession == nil { refresh() }
            if capture { try sync?.captureLibrary() }
            return true
        } catch { self.error = "Changes couldn’t be saved. \(error.localizedDescription)"; return false }
    }

    func present(_ document: LibraryDocument) async {
        if let session = activeSession {
            guard session.record.id != document.id else { return }
            session.pageChanged()
            guard await session.flush() else { return }
            nextDocument = document
            selected = nil
        } else { selected = document }
    }

    func readerDismissed() {
        activeSession = nil
        // Page saves skip the refetch while reading; re-sort "recent first" once here.
        refresh()
        Task {
            do { try await sync?.applyJournal() } catch { self.error = error.localizedDescription }
            if let nextDocument { self.nextDocument = nil; selected = nextDocument }
        }
    }

    // Kept for the generated sample and backwards-compatible managed documents only.
    func importPDF(_ url: URL) async -> LibraryDocument? {
        guard !isImporting else { return nil }
        isImporting = true
        defer { isImporting = false }
        do {
            let result = try await files.importPDF(from: url)
            if let existing = documents.first(where: { $0.fingerprint == result.fingerprint }) {
                if case .managed = existing.source,
                   !FileManager.default.fileExists(atPath: files.pdfURL(existing.fileName).path) {
                    existing.fileName = result.fileName
                    try context.save()
                } else { try await files.discardImport(result) }
                return existing
            }
            let document = LibraryDocument(id: result.id, fingerprint: result.fingerprint,
                title: result.title, fileName: result.fileName, pageCount: result.pageCount, byteCount: result.byteCount)
            context.insert(document)
            do { try context.save() }
            catch { context.rollback(); try? await files.discardImport(result); throw error }
            refresh()
            try sync?.restoreDocument(document)
            try sync?.captureLibrary()
            return document
        } catch { self.error = error.localizedDescription; return nil }
    }

    func openReference(_ url: URL, linking target: LibraryDocument? = nil, folderID: UUID? = nil) async -> LibraryDocument? {
        while isImporting {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return nil }
        }
        isImporting = true
        defer { isImporting = false }
        do {
            let result = try await files.referencePDF(from: url)
            if let target, result.fingerprint != target.fingerprint { throw FolioError.differentPDF }
            let existing = target ?? documents.first { $0.fingerprint == result.fingerprint }
            let document = existing ?? LibraryDocument(fingerprint: result.fingerprint,
                title: result.title, fileName: "", pageCount: result.pageCount, byteCount: result.byteCount)
            let managedName: String? = if case .managed(let name) = document.source { name } else { nil }
            // When a provider replaces a file, retain the old entry as an unlinked version.
            for old in documents where old.sourcePath == result.path && old.fingerprint != result.fingerprint {
                old.sourceKind = "unlinked"; old.sourceBookmark = nil; old.sourcePath = nil
            }
            document.sourceKind = "external"
            document.sourceBookmark = result.bookmark
            document.sourcePath = result.path
            if existing == nil { document.folderID = folderID; context.insert(document) }
            do { try context.save() } catch { context.rollback(); throw error }
            // The durable bookmark is committed before the legacy copy can be removed.
            if let managedName, !managedName.isEmpty { try await files.removeManagedCopy(managedName) }
            refresh()
            try sync?.restoreDocument(document)
            try sync?.captureLibrary()
            return document
        } catch { self.error = error.localizedDescription; return nil }
    }

    func openUpdatedVersion(_ document: LibraryDocument) async {
        do {
            let lease = try files.access(document.source)
            if let updated = await openReference(lease.url) { await present(updated) }
            withExtendedLifetime(lease) {}
        } catch { self.error = error.localizedDescription }
    }

    func opened(_ document: LibraryDocument, pageCount: Int) {
        document.pageCount = pageCount
        document.lastOpenedAt = .now
        document.lastPage = min(max(0, document.lastPage), max(0, pageCount - 1))
        persist()
    }

    /// Hot path while reading: commits the changed row and that document's progress entry
    /// only. It deliberately skips `refresh()` (refetch + sort) and the full library capture;
    /// the library re-sorts once when the reader is dismissed.
    func savePage(_ index: Int, for document: LibraryDocument) {
        guard index >= 0, index < document.pageCount else { return }
        document.lastPage = index
        document.lastOpenedAt = .now
        saveProgress(document)
    }

    @discardableResult func saveProgress(_ document: LibraryDocument) -> Bool {
        do {
            try context.save()
            try sync?.captureProgress(document)
            return true
        } catch { self.error = "Changes couldn’t be saved. \(error.localizedDescription)"; return false }
    }

    func rename(_ document: LibraryDocument, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        document.title = trimmed
        persist()
    }

    func toggleBookmark(_ document: LibraryDocument, page: Int) {
        if document.bookmarks.contains(page) { document.bookmarks.removeAll { $0 == page } }
        else { document.bookmarks.append(page); document.bookmarks.sort() }
        persist()
    }

    func saveMarks(_ marks: [Markup], for document: LibraryDocument, previous: [Markup]) async throws {
        try await files.saveMarks(marks, id: document.id)
        try sync?.captureAnnotations(marks, fingerprint: document.fingerprint, previous: previous)
    }

    func delete(_ document: LibraryDocument) async {
        let name: String = if case .managed(let name) = document.source { name } else { "" }
        let id = document.id
        let fingerprint = document.fingerprint
        do {
            try sync?.deleteDocument(document.fingerprint)
            context.delete(document)
            try context.save()
            refresh()
            try await files.remove(name: name, id: id, thumbnailKey: fingerprint)
            await thumbnails.forgetThumbnails(for: fingerprint)
            await ThumbnailCache.shared.removeAll()
        } catch { context.rollback(); refresh(); self.error = error.localizedDescription }
    }

    @discardableResult func createFolder(_ name: String, parentID: UUID?) -> LibraryFolder? {
        guard let clean = validFolderName(name, parentID: parentID) else { return nil }
        let folder = LibraryFolder(name: clean, parentID: parentID)
        context.insert(folder)
        guard persist() else { context.rollback(); refresh(); return nil }
        return folder
    }

    func renameFolder(_ folder: LibraryFolder, to name: String) {
        guard let clean = validFolderName(name, parentID: folder.parentID, excluding: folder.id) else { return }
        folder.name = clean; persist()
    }

    private func validFolderName(_ name: String, parentID: UUID?, excluding: UUID? = nil) -> String? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { error = "Enter a folder name."; return nil }
        guard !folders.contains(where: { $0.parentID == parentID && $0.id != excluding && $0.name.localizedCaseInsensitiveCompare(clean) == .orderedSame }) else {
            error = "A folder with that name already exists here."; return nil
        }
        return clean
    }

    func moveDocuments(_ ids: Set<UUID>, to folderID: UUID?) {
        guard folderID == nil || foldersByID[folderID!] != nil else { return }
        for document in documents where ids.contains(document.id) { document.folderID = folderID }
        persist()
    }

    func canMoveFolder(_ id: UUID, to parent: UUID?) -> Bool {
        var cursor = parent
        var visited: Set<UUID> = []
        while let value = cursor {
            guard value != id, visited.insert(value).inserted else { return false }
            cursor = foldersByID[value]?.parentID
        }
        return true
    }

    func moveFolder(_ folder: LibraryFolder, to parent: UUID?) {
        guard canMoveFolder(folder.id, to: parent) else { error = "A folder cannot be moved inside itself."; return }
        folder.parentID = parent; persist()
    }

    func deleteFolder(_ folder: LibraryFolder) {
        for document in documents where document.folderID == folder.id { document.folderID = folder.parentID }
        for child in folders where child.parentID == folder.id { child.parentID = folder.parentID }
        do { try sync?.deleteFolder(folder.id) }
        catch { self.error = error.localizedDescription; return }
        context.delete(folder); persist()
    }

    func folderPath(_ id: UUID?) -> String {
        var names: [String] = []
        var current = id
        var visited: Set<UUID> = []
        while let value = current, visited.insert(value).inserted, let folder = foldersByID[value] {
            names.append(folder.name); current = folder.parentID
        }
        return names.isEmpty ? "Library" : names.reversed().joined(separator: " / ")
    }

    func repairFolderGraph() {
        for folder in folders.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            if !canMoveFolder(folder.id, to: folder.parentID) ||
                (folder.parentID != nil && foldersByID[folder.parentID!] == nil) {
                folder.parentID = nil
            }
        }
        for document in documents where document.folderID != nil && foldersByID[document.folderID!] == nil {
            document.folderID = nil
        }
    }
}
