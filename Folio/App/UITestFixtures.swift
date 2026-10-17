#if DEBUG
import Foundation

/// Opt-in fixtures for UI verification. The production library is never used.
@MainActor
enum UITestFixtures {
    static func seed(_ store: LibraryStore) async throws {
        guard store.documents.isEmpty else { return }
        let work = store.createFolder("Work", parentID: nil)
        let notes = store.createFolder("Notes", parentID: nil)
        let large = ProcessInfo.processInfo.arguments.contains("--large-document")
        let titles = ["The art of focused reading", "Field notes", "Notes & ideas", "A quieter way to read"]
        for (index, title) in titles.enumerated() {
            let url = URL.temporaryDirectory.appendingPathComponent("\(title).pdf")
            let pages = index == 0 && large ? 500 : [25, 32, 12, 8][index]
            try await Task.detached { try SamplePDF.create(at: url, pages: pages) }.value
            if let document = await store.importPDF(url) {
                if index == 1 { document.folderID = work?.id }
                if index == 2 { document.folderID = notes?.id }
                if index == 0 { document.lastOpenedAt = .now; document.lastPage = 11 }
            }
        }
        store.persist()
    }
}
#endif
