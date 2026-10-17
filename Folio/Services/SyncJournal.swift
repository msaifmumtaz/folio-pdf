import Foundation

// An explicit whitelist: no source URLs, bookmark blobs, passwords, thumbnails, or PDF bytes.
struct ReadingPayload: Codable, Equatable, Sendable {
    var title: String?
    var pageCount: Int?
    var byteCount: Int64?
    var folderID: UUID?
    var lastOpenedAt: Date?
    var lastPage: Int?
    var page: Int?
    var markup: Markup?
    var folderName: String?
    var parentID: UUID?
}

struct ReadingChange: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case document, progress, bookmark, annotation, folder }
    var id: String
    var kind: Kind
    var fingerprint: String?
    var payload: ReadingPayload
    var modifiedAt: Date
    var writer: String
    var deleted = false

    func supersedes(_ other: ReadingChange) -> Bool {
        if modifiedAt != other.modifiedAt { return modifiedAt > other.modifiedAt }
        if deleted != other.deleted { return deleted }
        return writer > other.writer
    }
}

@MainActor
final class SyncJournal {
    struct State: Codable {
        var version = 1
        var writer = UUID().uuidString
        var changes: [String: ReadingChange] = [:]
        var pending: Set<String> = []
        var account: String?
        var engineState: Data?
        var serverRecords: [String: Data] = [:]
        var lastSuccess: Date?
        var needsProjection: Bool?
    }
    let url: URL
    private(set) var state: State
    private(set) var writeCount = 0

    init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
            guard state.version == 1 else { throw FolioError.newerMarkup }
        } else { state = State() }
    }

    func transaction(_ action: (inout State) throws -> Void) throws {
        let previous = state
        do {
            try action(&state)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            writeCount += 1
        } catch { state = previous; throw error }
    }

    static func put(_ id: String, kind: ReadingChange.Kind, fingerprint: String? = nil,
                    payload: ReadingPayload, deleted: Bool = false, into state: inout State) {
        let old = state.changes[id]
        guard old?.payload != payload || old?.deleted != deleted else { return }
        let time = max(Date.now, (old?.modifiedAt ?? .distantPast).addingTimeInterval(0.000001))
        state.changes[id] = ReadingChange(id: id, kind: kind, fingerprint: fingerprint,
            payload: payload, modifiedAt: time, writer: state.writer, deleted: deleted)
        state.pending.insert(id)
    }

    func merge(_ incoming: [ReadingChange]) throws {
        try transaction { state in
            for change in incoming {
                if let local = state.changes[change.id], !change.supersedes(local) {
                    if change != local { state.pending.insert(local.id) }
                    else { state.pending.remove(local.id) }
                    continue
                }
                state.changes[change.id] = change
                state.needsProjection = true
                state.pending.remove(change.id)
            }
        }
    }
}
