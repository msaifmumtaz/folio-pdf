import Foundation
import PDFKit
import CryptoKit

enum DocumentSource: Sendable {
    case managed(name: String)
    case external(bookmark: Data, fingerprint: String)
    case unlinked
}

// PDFKit reads lazily. The access lease must outlive every PDFDocument using this URL.
final class DocumentAccess: @unchecked Sendable {
    let url: URL
    let refreshedBookmark: Data?
    private let scoped: Bool

    init(url: URL, refreshedBookmark: Data? = nil) {
        self.url = url
        self.refreshedBookmark = refreshedBookmark
        scoped = url.startAccessingSecurityScopedResource()
    }

    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }

    func coordinate<T>(_ operation: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
            result = Result { try operation(coordinated) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw FolioError.missingFile }
        return try result.get()
    }
}

struct ReferencedPDF: Sendable {
    let fingerprint: String
    let title: String
    let bookmark: Data
    let path: String
    let pageCount: Int
    let byteCount: Int64
}

extension DocumentFiles {
    func referencePDF(from url: URL) throws -> ReferencedPDF {
        let access = DocumentAccess(url: url)
        return try access.coordinate { source in
            guard let pdf = PDFDocument(url: source) else { throw FolioError.invalidPDF }
            guard pdf.isLocked || pdf.pageCount > 0 else { throw FolioError.emptyPDF }
            let (fingerprint, bytes) = try Self.fingerprint(source)
            let bookmark = try url.bookmarkData(options: .minimalBookmark,
                includingResourceValuesForKeys: nil, relativeTo: nil)
            return ReferencedPDF(fingerprint: fingerprint,
                title: source.deletingPathExtension().lastPathComponent,
                bookmark: bookmark, path: url.standardizedFileURL.path,
                pageCount: pdf.isLocked ? 0 : pdf.pageCount, byteCount: bytes)
        }
    }

    nonisolated static func fingerprint(_ url: URL) throws -> (String, Int64) {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256()
        var bytes: Int64 = 0
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
            bytes += Int64(chunk.count)
        }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), bytes)
    }

    nonisolated func access(_ source: DocumentSource) throws -> DocumentAccess {
        switch source {
        case .managed(let name):
            return DocumentAccess(url: pdfURL(name))
        case .unlinked:
            throw FolioError.missingFile
        case .external(let data, _):
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            let lease = DocumentAccess(url: url)
            if stale {
                let refreshed = try url.bookmarkData(options: .minimalBookmark,
                    includingResourceValuesForKeys: nil, relativeTo: nil)
                withExtendedLifetime(lease) {}
                return DocumentAccess(url: url, refreshedBookmark: refreshed)
            }
            return lease
        }
    }

    func load(source: DocumentSource, id: UUID, password: String? = nil) throws -> LoadedPDF {
        let lease = try access(source)
        return try lease.coordinate { url in
            if case .external(_, let expected) = source,
               try Self.fingerprint(url).0 != expected { throw FolioError.sourceChanged }
            guard let pdf = PDFDocument(url: url) else { throw FolioError.invalidPDF }
            if pdf.isLocked {
                guard let password else { throw FolioError.passwordRequired }
                guard pdf.unlock(withPassword: password) else { throw FolioError.wrongPassword }
            }
            guard pdf.pageCount > 0 else { throw FolioError.emptyPDF }
            let marks = try readMarks(id)
            for mark in marks { pdf.page(at: mark.page)?.addAnnotation(mark.annotation()) }
            return LoadedPDF(document: pdf, marks: marks, access: lease)
        }
    }

    // `thumbnail(source:…)` lives with the thumbnail cache in DocumentFiles.swift.

    func export(source: DocumentSource, title: String, marks: [Markup], password: String?) throws -> URL {
        let lease = try access(source)
        return try lease.coordinate { url in
            if case .external(_, let expected) = source,
               try Self.fingerprint(url).0 != expected { throw FolioError.sourceChanged }
            return try export(url: url, title: title, marks: marks, password: password)
        }
    }

    func removeManagedCopy(_ name: String) throws {
        guard !name.isEmpty else { return }
        let url = pdfURL(name)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
