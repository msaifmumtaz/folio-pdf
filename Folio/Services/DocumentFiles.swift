import Foundation
import PDFKit
import CryptoKit
import UIKit

struct ImportResult: Sendable {
    let id: UUID
    let fingerprint: String
    let title: String
    let fileName: String
    let pageCount: Int
    let byteCount: Int64
}

// A one-way ownership transfer: the worker never touches a document after returning it.
final class LoadedPDF: @unchecked Sendable {
    let document: PDFDocument
    let marks: [Markup]
    let access: DocumentAccess?
    init(document: PDFDocument, marks: [Markup], access: DocumentAccess? = nil) {
        self.access = access
        self.document = document
        self.marks = marks
    }
}

actor DocumentFiles {
    let root: URL

    init(root: URL) { self.root = root }

    nonisolated func pdfURL(_ name: String) -> URL {
        root.appendingPathComponent("Documents", isDirectory: true).appendingPathComponent(name)
    }

    nonisolated func markupURL(_ id: UUID) -> URL {
        root.appendingPathComponent("Annotations", isDirectory: true).appendingPathComponent("\(id.uuidString).json")
    }

    func prepare() throws {
        for folder in ["Documents", "Annotations", "Thumbnails", "Exports"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder),
                                                    withIntermediateDirectories: true)
        }
    }

    func importPDF(from source: URL) throws -> ImportResult {
        try prepare()
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<ImportResult, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinated in
            result = Result { try copyAndInspect(coordinated) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw FolioError.missingFile }
        return try result.get()
    }

    private func copyAndInspect(_ source: URL) throws -> ImportResult {
        let id = UUID()
        let name = "\(id.uuidString).pdf"
        let destination = pdfURL(name)
        let partial = destination.appendingPathExtension("partial")
        defer { try? FileManager.default.removeItem(at: partial) }
        guard FileManager.default.fileExists(atPath: source.path) else { throw FolioError.missingFile }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let output = try FileHandle(forWritingTo: partial)
        defer { try? output.close() }
        var hash = SHA256()
        var bytes: Int64 = 0
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
            try output.write(contentsOf: chunk)
            bytes += Int64(chunk.count)
        }
        try output.synchronize()
        guard let pdf = PDFDocument(url: partial) else { throw FolioError.invalidPDF }
        guard pdf.isLocked || pdf.pageCount > 0 else { throw FolioError.emptyPDF }
        let count = pdf.isLocked ? 0 : pdf.pageCount
        try FileManager.default.moveItem(at: partial, to: destination)
        return ImportResult(id: id, fingerprint: hash.finalize().map { String(format: "%02x", $0) }.joined(),
                            title: source.deletingPathExtension().lastPathComponent,
                            fileName: name, pageCount: count, byteCount: bytes)
    }

    func load(name: String, id: UUID, password: String? = nil) throws -> LoadedPDF {
        let url = pdfURL(name)
        guard FileManager.default.fileExists(atPath: url.path) else { throw FolioError.missingFile }
        guard let pdf = PDFDocument(url: url) else { throw FolioError.invalidPDF }
        if pdf.isLocked {
            guard let password else { throw FolioError.passwordRequired }
            guard pdf.unlock(withPassword: password) else { throw FolioError.wrongPassword }
        }
        guard pdf.pageCount > 0 else { throw FolioError.emptyPDF }
        let marks = try readMarks(id)
        for mark in marks { pdf.page(at: mark.page)?.addAnnotation(mark.annotation()) }
        return LoadedPDF(document: pdf, marks: marks)
    }

    func readMarks(_ id: UUID) throws -> [Markup] {
        let url = markupURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let envelope = try JSONDecoder().decode(MarkupEnvelope.self, from: Data(contentsOf: url))
        guard (1...2).contains(envelope.version) else { throw FolioError.newerMarkup }
        return envelope.marks
    }

    func saveMarks(_ marks: [Markup], id: UUID) throws {
        try prepare()
        let data = try JSONEncoder().encode(MarkupEnvelope(marks: marks))
        try data.write(to: markupURL(id), options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    func remove(name: String, id: UUID, thumbnailKey: String? = nil) throws {
        let cached = (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Thumbnails"), includingPropertiesForKeys: nil)) ?? []
        // Thumbnails are keyed by fingerprint (legacy entries by file name); remove both.
        let prefixes = [thumbnailKey, name.isEmpty ? nil : name].compactMap { $0 }.map { "\($0)-" }
        let thumbs = cached.filter { url in prefixes.contains { url.lastPathComponent.hasPrefix($0) } }
        for url in (name.isEmpty ? [markupURL(id)] : [pdfURL(name), markupURL(id)]) + thumbs {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        thumbnailBytes = nil
    }

    func discardImport(_ result: ImportResult) throws {
        try FileManager.default.removeItem(at: pdfURL(result.fileName))
    }

    // MARK: Thumbnails

    /// Default render box for page tiles and list rows.
    static let pageThumbnailSize = CGSize(width: 260, height: 340)
    /// Sharper render box for library grid covers.
    static let coverThumbnailSize = CGSize(width: 480, height: 640)
    private static let thumbnailBudget = 24 * 1024 * 1024

    /// Running size of the on-disk thumbnail cache; `nil` until first measured.
    private var thumbnailBytes: Int?
    /// One parsed worker document reused across a burst of thumbnail requests (for example
    /// the page grid), so a 500-page PDF is parsed once instead of once per tile. This is
    /// never the displayed reader document. The lease keeps security-scoped access open
    /// for as long as PDFKit may read lazily.
    private var worker: (key: String, lease: DocumentAccess?, pdf: PDFDocument)?
    private var workerRelease: Task<Void, Never>?
    private(set) var workerOpenCount = 0

    func thumbnailURL(name: String, page: Int, size: CGSize = DocumentFiles.pageThumbnailSize) -> URL {
        let suffix = size == Self.pageThumbnailSize ? "" : "@\(Int(size.width))x\(Int(size.height))"
        return root.appendingPathComponent("Thumbnails").appendingPathComponent("\(name)-\(page)\(suffix).jpg")
    }

    func thumbnail(name: String, page: Int = 0, password: String? = nil) throws -> Data? {
        try thumbnail(url: pdfURL(name), cacheKey: name, page: page, password: password)
    }

    func thumbnail(url: URL, cacheKey: String, page: Int, password: String?,
                   size: CGSize = DocumentFiles.pageThumbnailSize) throws -> Data? {
        try Task.checkCancellation()
        if let cached = try? Data(contentsOf: thumbnailURL(name: cacheKey, page: page, size: size)) { return cached }
        guard let pdf = try workerDocument(key: "\(cacheKey)|\(url.path)", password: password, open: {
            (nil, PDFDocument(url: url))
        }) else { return nil }
        return try render(pdf, cacheKey: cacheKey, page: page, size: size)
    }

    /// Resolves and opens `source` only on a disk-cache miss; cached thumbnails need no
    /// bookmark resolution or file coordination.
    func thumbnail(source: DocumentSource, cacheKey: String, page: Int = 0, password: String? = nil,
                   size: CGSize = DocumentFiles.pageThumbnailSize) throws -> Data? {
        try Task.checkCancellation()
        if let cached = try? Data(contentsOf: thumbnailURL(name: cacheKey, page: page, size: size)) { return cached }
        let sourceKey: String
        switch source {
        case .managed(let name): sourceKey = name
        case .external(let bookmark, _): sourceKey = SHA256.hash(data: bookmark).map { String(format: "%02x", $0) }.joined()
        case .unlinked: sourceKey = "unlinked"
        }
        guard let pdf = try workerDocument(key: "\(cacheKey)|\(sourceKey)", password: password, open: {
            let lease = try self.access(source)
            return (lease, try lease.coordinate { PDFDocument(url: $0) })
        }) else { return nil }
        return try render(pdf, cacheKey: cacheKey, page: page, size: size)
    }

    /// Drops the reusable worker document, for example when the reader closes.
    func releaseWorkerDocument() {
        workerRelease?.cancel(); workerRelease = nil
        worker = nil
    }

    func forgetThumbnails(for cacheKey: String) {
        if worker?.key.hasPrefix("\(cacheKey)|") == true { releaseWorkerDocument() }
        thumbnailBytes = nil
    }

    private func workerDocument(key cacheKey: String, password: String?,
                                open: () throws -> (DocumentAccess?, PDFDocument?)) throws -> PDFDocument? {
        let key = "\(cacheKey)|\(password ?? "")"
        if let worker, worker.key == key { scheduleWorkerRelease(); return worker.pdf }
        let (lease, opened) = try open()
        guard let pdf = opened else { return nil }
        workerOpenCount += 1
        if pdf.isLocked {
            guard let password, pdf.unlock(withPassword: password) else { return nil }
        }
        worker = (key, lease, pdf)
        scheduleWorkerRelease()
        return pdf
    }

    private func scheduleWorkerRelease() {
        workerRelease?.cancel()
        workerRelease = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            await self?.releaseWorkerDocument()
        }
    }

    private func render(_ pdf: PDFDocument, cacheKey: String, page: Int, size: CGSize) throws -> Data? {
        try Task.checkCancellation()
        guard let pdfPage = pdf.page(at: page) else { return nil }
        let image = pdfPage.thumbnail(of: size, for: .cropBox)
        guard let data = image.jpegData(compressionQuality: 0.8) else { return nil }
        // Never cache decrypted previews of password-protected documents on disk.
        if !pdf.isEncrypted {
            try prepare()
            try data.write(to: thumbnailURL(name: cacheKey, page: page, size: size), options: .atomic)
            try recordThumbnailWrite(data.count)
        }
        return data
    }

    /// Tracks the cache size incrementally and only scans/trims the directory when the
    /// budget is exceeded, instead of after every single write.
    private func recordThumbnailWrite(_ bytes: Int) throws {
        if thumbnailBytes == nil { thumbnailBytes = try measureThumbnails().reduce(0) { $0 + $1.1 } }
        else { thumbnailBytes! += bytes }
        if thumbnailBytes! > Self.thumbnailBudget { try trimThumbnails() }
    }

    private func measureThumbnails() throws -> [(URL, Int, Date)] {
        let urls = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Thumbnails"),
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        return try urls.map { url -> (URL, Int, Date) in
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
    }

    private func trimThumbnails() throws {
        let entries = try measureThumbnails().sorted { $0.2 < $1.2 }
        var total = entries.reduce(0) { $0 + $1.1 }
        // Trim to 80% of the budget so the next few writes don't immediately trim again.
        for (url, size, _) in entries where total > Self.thumbnailBudget * 4 / 5 {
            try FileManager.default.removeItem(at: url)
            total -= size
        }
        thumbnailBytes = total
    }

    func export(name: String, title: String, marks: [Markup], password: String?) throws -> URL {
        try export(url: pdfURL(name), title: title, marks: marks, password: password)
    }

    func export(url: URL, title: String, marks: [Markup], password: String?) throws -> URL {
        try prepare()
        guard let pdf = PDFDocument(url: url) else { throw FolioError.missingFile }
        if pdf.isLocked {
            guard let password, pdf.unlock(withPassword: password) else { throw FolioError.passwordRequired }
        }
        if !marks.isEmpty && !pdf.allowsCommenting { throw FolioError.restricted }
        for mark in marks { pdf.page(at: mark.page)?.addAnnotation(mark.annotation()) }
        let directory = root.appendingPathComponent("Exports").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeTitle = title.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        let destination = directory.appendingPathComponent(safeTitle.isEmpty ? "Document.pdf" : "\(safeTitle).pdf")
        if marks.isEmpty {
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        }
        let partial = destination.appendingPathExtension("partial")
        var options: [PDFDocumentWriteOption: Any] = [:]
        // Preserve access restrictions as well as password protection.
        if pdf.isEncrypted {
            options[.userPasswordOption] = password ?? ""
            options[.ownerPasswordOption] = UUID().uuidString
            options[.accessPermissionsOption] = pdf.accessPermissions.rawValue
        }
        guard pdf.write(to: partial, withOptions: options) else { throw FolioError.exportFailed }
        try FileManager.default.moveItem(at: partial, to: destination)
        return destination
    }

    func cleanExports() throws {
        let directory = root.appendingPathComponent("Exports")
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in urls { try FileManager.default.removeItem(at: url) }
    }
}
