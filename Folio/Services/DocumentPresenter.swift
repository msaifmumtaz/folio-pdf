import Foundation

/// Observes provider moves/replacements without writing to the original PDF.
final class DocumentPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var location: URL
    private let changed: @Sendable (URL) -> Void
    var presentedItemURL: URL? { lock.lock(); defer { lock.unlock() }; return location }
    let presentedItemOperationQueue = OperationQueue.main

    init(url: URL, changed: @escaping @Sendable (URL) -> Void) {
        location = url; self.changed = changed
        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }
    func presentedItemDidChange() { if let url = presentedItemURL { changed(url) } }
    func presentedItemDidMove(to newURL: URL) {
        lock.lock(); location = newURL; lock.unlock()
        changed(newURL)
    }
    func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        if let url = presentedItemURL { changed(url) }
        completionHandler(nil)
    }
    func invalidate() { NSFileCoordinator.removeFilePresenter(self) }
    deinit { NSFileCoordinator.removeFilePresenter(self) }
}
