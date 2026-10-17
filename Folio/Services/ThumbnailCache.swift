import UIKit

/// Decoded previews shared by covers and page tiles. PDF parsing stays on the
/// thumbnail worker actor; image decompression happens here, away from the UI.
actor ThumbnailCache {
    static let shared = ThumbnailCache()
    private let images = NSCache<NSString, UIImage>()

    init() {
        images.totalCostLimit = 32 * 1024 * 1024
        images.countLimit = 180
    }

    func image(files: DocumentFiles, source: DocumentSource, fingerprint: String,
               page: Int = 0, password: String? = nil,
               size: CGSize = DocumentFiles.pageThumbnailSize) async throws -> UIImage? {
        let key = "\(files.root.path)|\(fingerprint)|\(page)|\(Int(size.width))x\(Int(size.height))" as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let data = try await files.thumbnail(source: source, cacheKey: fingerprint,
            page: page, password: password, size: size), let original = UIImage(data: data) else { return nil }
        try Task.checkCancellation()
        let decoded = original.preparingForDisplay() ?? original
        let cost = decoded.cgImage.map { $0.bytesPerRow * $0.height } ?? data.count
        images.setObject(decoded, forKey: key, cost: cost)
        return decoded
    }

    func removeAll() { images.removeAllObjects() }
}
