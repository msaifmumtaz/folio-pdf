import CloudKit
import SwiftData
import SwiftUI
import CryptoKit

@MainActor @Observable
final class ReadingSyncService: CKSyncEngineDelegate {
    private weak var store: LibraryStore?
    let preferences: AppPreferences
    let journal: SyncJournal
    var status = "Off"
    var lastSuccess: Date?
    var isSyncing = false
    var failure: String?
    var annotationGeneration = 0
    @ObservationIgnored private var engine: CKSyncEngine?
    @ObservationIgnored private var accountObserver: NSObjectProtocol?
    @ObservationIgnored private var applying = false
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var generation = 0
    private let zone = CKRecordZone.ID(zoneName: "FolioReading")
    private var container: CKContainer { CKContainer(identifier: "iCloud.com.folio.pdf") }

    init(store: LibraryStore, preferences: AppPreferences) throws {
        self.store = store
        self.preferences = preferences
        journal = try SyncJournal(url: store.root.appendingPathComponent("Sync/Journal.json"))
        lastSuccess = journal.state.lastSuccess
        if ReleaseFeatures.iCloudSync {
            accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.checkAccount() }
            }
        }
    }

    deinit { if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) } }

    func recover() async throws {
        if journal.state.needsProjection == true { try await applyJournal() }
        try captureLibrary()
        if let store {
            for document in store.documents where !hasAnnotationHistory(document.fingerprint) {
                try captureAnnotations(try await store.files.readMarks(document.id), fingerprint: document.fingerprint)
            }
        }
    }

    func setEnabled(_ enabled: Bool) async {
        let enabled = enabled && ReleaseFeatures.iCloudSync
        preferences.syncEnabled = enabled
        if enabled { await start(allowAccountChange: true) }
        else {
            generation += 1
            let previous = engine; engine = nil
            await previous?.cancelOperations()
            isSyncing = false; status = "Off"; failure = nil
        }
    }

    func start(allowAccountChange: Bool = false) async {
        guard ReleaseFeatures.iCloudSync, preferences.syncEnabled, engine == nil, !starting, let store else { return }
        starting = true
        defer { starting = false }
        let token = generation
        do {
            status = "Checking iCloud…"
            guard try await container.accountStatus() == .available else {
                status = "iCloud unavailable"; failure = "Sign in to iCloud in iPhone Settings, then retry."; return
            }
            let account = try await container.userRecordID().recordName
            guard preferences.syncEnabled, generation == token else { return }
            if let previous = journal.state.account, previous != account {
                guard allowAccountChange else { await accountChanged(); return }
                // Explicitly re-enabling after the account change authorizes a fresh upload.
                try journal.transaction { state in
                    state.account = account; state.engineState = nil; state.serverRecords = [:]
                    state.pending = Set(state.changes.keys)
                }
            } else { try journal.transaction { $0.account = account } }
            try captureLibrary()
            for document in store.documents where !hasAnnotationHistory(document.fingerprint) {
                try captureAnnotations(try await store.files.readMarks(document.id), fingerprint: document.fingerprint)
            }
            guard preferences.syncEnabled, generation == token else { return }
            let serialization = try journal.state.engineState.map { try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
            let newEngine = CKSyncEngine(CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                stateSerialization: serialization, delegate: self))
            engine = newEngine
            UIApplication.shared.registerForRemoteNotifications()
            newEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zone))])
            schedulePending()
            failure = nil; status = "Ready to sync"
        } catch { failed(error) }
    }

    func syncNow() async {
        guard ReleaseFeatures.iCloudSync else { return }
        if engine == nil { await start() }
        guard let engine, preferences.syncEnabled else { return }
        do {
            isSyncing = true; status = "Syncing…"; failure = nil
            try await engine.fetchChanges()
            try await engine.sendChanges()
            guard self.engine === engine, preferences.syncEnabled else { return }
            if journal.state.pending.isEmpty && failure == nil {
                try journal.transaction { $0.lastSuccess = .now }
                lastSuccess = journal.state.lastSuccess
                status = "Up to date"
            } else if failure == nil { status = "Waiting to sync" }
            isSyncing = false
        } catch { failed(error) }
    }

    private func checkAccount() async {
        guard ReleaseFeatures.iCloudSync, preferences.syncEnabled, let expected = journal.state.account else { return }
        do {
            let available = try await container.accountStatus() == .available
            let current = available ? try await container.userRecordID().recordName : nil
            if current != expected { await accountChanged() }
        } catch { failed(error) }
    }

    private func accountChanged() async {
        await setEnabled(false)
        // Retain local reading data, but never reuse one account's CloudKit record metadata in another.
        do { try journal.transaction { $0.engineState = nil; $0.serverRecords = [:] } }
        catch { failed(error) }
        status = "iCloud account changed"
        failure = "Sync is off. Enable it again to sync this library with your current iCloud account."
    }

    func captureLibrary() throws {
        guard !applying, let store else { return }
        try journal.transaction { state in
            for document in store.documents {
                let fingerprint = document.fingerprint
                guard state.changes["d:\(fingerprint)"]?.deleted != true else { continue }
                SyncJournal.put("d:\(fingerprint)", kind: .document, fingerprint: fingerprint,
                    payload: ReadingPayload(title: document.title, pageCount: document.pageCount,
                        byteCount: document.byteCount, folderID: document.folderID), into: &state)
                SyncJournal.put("p:\(fingerprint)", kind: .progress, fingerprint: fingerprint,
                    payload: ReadingPayload(lastOpenedAt: document.lastOpenedAt, lastPage: document.lastPage), into: &state)
                let pages = Set(document.bookmarks)
                for page in pages {
                    SyncJournal.put("b:\(fingerprint):\(page)", kind: .bookmark, fingerprint: fingerprint,
                        payload: ReadingPayload(page: page), into: &state)
                }
                for change in Array(state.changes.values) where change.kind == .bookmark && change.fingerprint == fingerprint && !change.deleted {
                    if let page = change.payload.page, !pages.contains(page) {
                        SyncJournal.put(change.id, kind: .bookmark, fingerprint: fingerprint,
                            payload: change.payload, deleted: true, into: &state)
                    }
                }
            }
            for folder in store.folders {
                SyncJournal.put("f:\(folder.id.uuidString)", kind: .folder,
                    payload: ReadingPayload(folderName: folder.name, parentID: folder.parentID), into: &state)
            }
        }
        schedulePending()
    }

    /// Records reading progress for a single document. Page turns use this instead of
    /// `captureLibrary()`, which walks every document, folder, and bookmark.
    func captureProgress(_ document: LibraryDocument) throws {
        let fingerprint = document.fingerprint
        guard !applying, journal.state.changes["d:\(fingerprint)"]?.deleted != true else { return }
        let payload = ReadingPayload(lastOpenedAt: document.lastOpenedAt, lastPage: document.lastPage)
        // Skip the journal write entirely when nothing changed.
        guard journal.state.changes["p:\(fingerprint)"]?.payload != payload else { return }
        try journal.transaction { state in
            SyncJournal.put("p:\(fingerprint)", kind: .progress, fingerprint: fingerprint, payload: payload, into: &state)
        }
        schedulePending()
    }

    func captureAnnotations(_ marks: [Markup], fingerprint: String, previous: [Markup]? = nil) throws {
        guard !applying, journal.state.changes["d:\(fingerprint)"]?.deleted != true else { return }
        try journal.transaction { state in
            let ids = Set(marks.map { "a:\(fingerprint):\($0.id.uuidString)" })
            for mark in marks where previous?.first(where: { $0.id == mark.id }) != mark {
                SyncJournal.put("a:\(fingerprint):\(mark.id.uuidString)", kind: .annotation,
                    fingerprint: fingerprint, payload: ReadingPayload(markup: mark), into: &state)
            }
            for change in Array(state.changes.values) where change.kind == .annotation && change.fingerprint == fingerprint && !change.deleted && !ids.contains(change.id) && (previous == nil || previous!.contains(where: { $0.id == change.payload.markup?.id })) {
                SyncJournal.put(change.id, kind: .annotation, fingerprint: fingerprint,
                    payload: change.payload, deleted: true, into: &state)
            }
        }
        schedulePending()
    }

    func deleteDocument(_ fingerprint: String) throws {
        try journal.transaction { state in
            for change in Array(state.changes.values) where change.fingerprint == fingerprint {
                SyncJournal.put(change.id, kind: change.kind, fingerprint: fingerprint,
                    payload: change.payload, deleted: true, into: &state)
            }
        }
        schedulePending()
    }

    func deleteFolder(_ id: UUID) throws {
        try journal.transaction { state in
            let key = "f:\(id.uuidString)"
            SyncJournal.put(key, kind: .folder, payload: state.changes[key]?.payload ?? ReadingPayload(), deleted: true, into: &state)
        }
        schedulePending()
    }

    func restoreDocument(_ document: LibraryDocument) throws {
        let key = "d:\(document.fingerprint)"
        guard journal.state.changes[key]?.deleted == true else { return }
        try journal.transaction { state in
            SyncJournal.put(key, kind: .document, fingerprint: document.fingerprint,
                payload: ReadingPayload(title: document.title, pageCount: document.pageCount,
                    byteCount: document.byteCount, folderID: document.folderID), into: &state)
        }
    }

    private func schedulePending() {
        guard preferences.syncEnabled, let engine else { return }
        engine.state.add(pendingRecordZoneChanges: journal.state.pending.map {
            .saveRecord(CKRecord.ID(recordName: $0, zoneID: zone))
        })
    }

    // Merge changes into the local projection. No network or file access enters SwiftUI view bodies.
    func applyJournal(repairFolders: Bool = true) async throws {
        guard let store, !applying else { return }
        applying = true
        defer { applying = false }
        let changes = Array(journal.state.changes.values)
        var annotationWrites: [(UUID, [Markup])] = []
        for change in changes where change.kind == .folder {
            guard let id = UUID(uuidString: String(change.id.dropFirst(2))) else { continue }
            if change.deleted {
                if let folder = store.folders.first(where: { $0.id == id }) { store.context.delete(folder) }
            } else if let folder = store.folders.first(where: { $0.id == id }) {
                folder.name = change.payload.folderName ?? "Folder"; folder.parentID = change.payload.parentID
            } else {
                store.context.insert(LibraryFolder(id: id, name: change.payload.folderName ?? "Folder", parentID: change.payload.parentID))
            }
        }
        for change in changes where change.kind == .document {
            guard let fingerprint = change.fingerprint else { continue }
            if change.deleted {
                if let document = store.documents.first(where: { $0.fingerprint == fingerprint }), store.activeSession?.record.id != document.id {
                    store.context.delete(document)
                }
                continue
            }
            let document = store.documents.first { $0.fingerprint == fingerprint } ?? LibraryDocument(fingerprint: fingerprint,
                title: change.payload.title ?? "PDF", fileName: "", pageCount: change.payload.pageCount ?? 0, byteCount: change.payload.byteCount ?? 0)
            if !store.documents.contains(where: { $0.id == document.id }) {
                document.sourceKind = "unlinked"; store.context.insert(document)
            }
            document.title = change.payload.title ?? document.title
            document.pageCount = change.payload.pageCount ?? document.pageCount
            document.byteCount = change.payload.byteCount ?? document.byteCount
            document.folderID = change.payload.folderID
            if let progress = journal.state.changes["p:\(fingerprint)"], !progress.deleted {
                document.lastOpenedAt = progress.payload.lastOpenedAt
                // The active PDFView remains where the reader placed it.
                document.lastPage = min(max(0, progress.payload.lastPage ?? 0), max(0, document.pageCount - 1))
            }
            document.bookmarks = changes.filter { $0.kind == .bookmark && $0.fingerprint == fingerprint && !$0.deleted }
                .compactMap { $0.payload.page }.sorted()
            if store.activeSession?.record.id != document.id && hasAnnotationHistory(fingerprint) {
                let marks = changes.filter { $0.kind == .annotation && $0.fingerprint == fingerprint && !$0.deleted }
                    .compactMap { $0.payload.markup }.sorted { $0.id.uuidString < $1.id.uuidString }
                annotationWrites.append((document.id, marks))
            }
        }
        try store.context.save()
        store.refresh()
        if repairFolders { store.repairFolderGraph() }
        try store.context.save()
        applying = false
        for (id, marks) in annotationWrites where store.activeSession?.record.id != id {
            try await store.files.saveMarks(marks, id: id)
        }
        try journal.transaction { $0.needsProjection = false }
        annotationGeneration += 1
    }

    func hasAnnotationHistory(_ fingerprint: String) -> Bool {
        journal.state.changes.values.contains { $0.kind == .annotation && $0.fingerprint == fingerprint }
    }

    func remoteMarks(for fingerprint: String) -> [Markup] {
        journal.state.changes.values.filter { $0.kind == .annotation && $0.fingerprint == fingerprint && !$0.deleted }
            .compactMap { $0.payload.markup }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func finishCycle() {
        isSyncing = false
        if failure == nil {
            status = journal.state.pending.isEmpty ? "Up to date" : "Waiting to sync"
            if journal.state.pending.isEmpty {
                do { try journal.transaction { $0.lastSuccess = .now }; lastSuccess = journal.state.lastSuccess }
                catch { failed(error) }
            }
        }
    }

    private func failed(_ error: Error) {
        isSyncing = false; failure = error.localizedDescription; status = "Sync needs attention"
    }

    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await receive(event, from: syncEngine)
    }

    nonisolated func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await makeBatch(context, engine: syncEngine)
    }

    private func makeBatch(_ context: CKSyncEngine.SendChangesContext, engine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard self.engine === engine, preferences.syncEnabled else { return nil }
        let pending = engine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [weak self] id in
            guard let self else { return nil }
            return await self.makeRecord(id)
        }
    }

    private func makeRecord(_ id: CKRecord.ID) -> CKRecord? {
        guard let change = journal.state.changes[id.recordName] else { return nil }
        do {
            let record: CKRecord
            if let data = journal.state.serverRecords[id.recordName] {
                let coder = try NSKeyedUnarchiver(forReadingFrom: data)
                coder.requiresSecureCoding = true
                record = CKRecord(coder: coder) ?? CKRecord(recordType: "ReadingChange", recordID: id)
                coder.finishDecoding()
            } else { record = CKRecord(recordType: "ReadingChange", recordID: id) }
            // CKAsset avoids CloudKit's record-size ceiling for long pen strokes.
            let directory = journal.url.deletingLastPathComponent().appendingPathComponent("Uploads")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(UUID().uuidString + ".json")
            try JSONEncoder().encode(change).write(to: file, options: .atomic)
            record["payload"] = CKAsset(fileURL: file)
            return record
        } catch { failed(error); return nil }
    }

    private func decode(_ record: CKRecord) throws -> ReadingChange {
        guard let url = (record["payload"] as? CKAsset)?.fileURL else { throw FolioError.newerMarkup }
        let change = try JSONDecoder().decode(ReadingChange.self, from: Data(contentsOf: url))
        guard change.id == record.recordID.recordName else { throw FolioError.newerMarkup }
        return change
    }

    private func cacheRecord(_ record: CKRecord) throws {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder); coder.finishEncoding()
        try journal.transaction { $0.serverRecords[record.recordID.recordName] = coder.encodedData }
    }

    private func receive(_ event: CKSyncEngine.Event, from engine: CKSyncEngine) async {
        guard self.engine === engine, preferences.syncEnabled else { return }
        do {
            switch event {
            case .stateUpdate(let update):
                let data = try JSONEncoder().encode(update.stateSerialization)
                try journal.transaction { $0.engineState = data }
            case .accountChange(let event):
                switch event.changeType {
                case .signOut, .switchAccounts: await accountChanged()
                case .signIn: await checkAccount()
                @unknown default: await accountChanged()
                }
            case .willFetchChanges, .willSendChanges:
                isSyncing = true; status = "Syncing…"; failure = nil
            case .fetchedRecordZoneChanges(let fetched):
                var incoming: [ReadingChange] = []
                for modification in fetched.modifications {
                    incoming.append(try decode(modification.record))
                    try cacheRecord(modification.record)
                }
                for deletion in fetched.deletions {
                    if var change = journal.state.changes[deletion.recordID.recordName] {
                        change.deleted = true; change.modifiedAt = .now; change.writer = "cloud-deletion"
                        incoming.append(change)
                    }
                }
                try journal.merge(incoming)
                try await applyJournal(repairFolders: false)
                schedulePending()
            case .sentRecordZoneChanges(let sent):
                for record in sent.savedRecords {
                    let sentChange = try decode(record)
                    try cacheRecord(record)
                    try journal.transaction { state in
                        if state.changes[sentChange.id] == sentChange { state.pending.remove(sentChange.id) }
                    }
                    if let url = (record["payload"] as? CKAsset)?.fileURL { try? FileManager.default.removeItem(at: url) }
                }
                for failedSave in sent.failedRecordSaves {
                    switch failedSave.error.code {
                    case .serverRecordChanged:
                        if let server = failedSave.error.serverRecord {
                            try cacheRecord(server); try journal.merge([decode(server)])
                            try await applyJournal()
                        }
                    case .zoneNotFound:
                        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zone))])
                    default: failed(failedSave.error)
                    }
                }
                schedulePending()
            case .didFetchChanges:
                try await applyJournal()
                finishCycle()
            case .didSendChanges:
                finishCycle()
            default: break
            }
        } catch { failed(error) }
    }
}
