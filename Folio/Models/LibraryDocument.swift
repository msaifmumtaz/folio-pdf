import Foundation
import SwiftData

@Model
final class LibraryDocument {
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
    // Optional additions allow existing SwiftData libraries to migrate in place.
    var sourceKind: String?
    var sourceBookmark: Data?
    var sourcePath: String?
    var folderID: UUID?

    init(id: UUID = UUID(), fingerprint: String, title: String, fileName: String,
         pageCount: Int, byteCount: Int64) {
        self.id = id
        self.fingerprint = fingerprint
        self.title = title
        self.fileName = fileName
        self.pageCount = pageCount
        self.byteCount = byteCount
        importedAt = .now
        lastPage = 0
        bookmarks = []
    }

    var progress: Double { pageCount > 0 ? Double(lastPage + 1) / Double(pageCount) : 0 }
    var pageDescription: String { pageCount > 0 ? "Page \(lastPage + 1) of \(pageCount)" : "Password protected" }

    var source: DocumentSource {
        if sourceKind == "external", let sourceBookmark {
            return .external(bookmark: sourceBookmark, fingerprint: fingerprint)
        }
        if sourceKind == "unlinked" { return .unlinked }
        return .managed(name: fileName)
    }
    var needsLocation: Bool { sourceKind == "unlinked" }
}

@Model
final class LibraryFolder {
    @Attribute(.unique) var id: UUID
    var name: String
    var parentID: UUID?

    init(id: UUID = UUID(), name: String, parentID: UUID? = nil) {
        self.id = id
        self.name = name
        self.parentID = parentID
    }
}
