import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Bindable var store: LibraryStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable var preferences: AppPreferences
    @State private var folderID: UUID?
    @State private var selecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var move: MoveRequest?
    @State private var folderEditor = false
    @State private var editingFolder: LibraryFolder?
    @State private var folderName = ""
    @State private var folderToDelete: LibraryFolder?
    @State private var deletingFolder = false
    @State private var query = ""
    @State private var renameTarget: LibraryDocument?
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var deleteTarget: LibraryDocument?
    @State private var deleting = false
    @State private var share: ShareItem?
    @State private var exporting = false
    @State private var showAbout = false
    @State private var sampleLoading = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var filtered: [LibraryDocument] {
        store.documents.filter { document in
            if !query.isEmpty { return document.title.localizedStandardContains(query) || store.folderPath(document.folderID).localizedStandardContains(query) }
            return folderID == nil || document.folderID == folderID
        }
    }
    private var recent: LibraryDocument? { store.documents.first { $0.lastOpenedAt != nil } }

    var body: some View { NavigationStack { libraryState } }

    private var effectiveLayout: AppPreferences.LibraryLayout {
        dynamicTypeSize.isAccessibilitySize ? .list : preferences.libraryLayout
    }

    private var libraryContent: some View {
        let documents = filtered
        return ScrollView {
            VStack(alignment: .leading, spacing: Layout.Spacing.lg) {
                masthead
                if store.documents.isEmpty && store.folders.isEmpty && query.isEmpty {
                    emptyLibrary
                } else {
                    if query.isEmpty && folderID == nil && !selecting, let recent {
                        LibraryContinueCard(document: recent, files: store.thumbnails) {
                            Task { await store.present(recent) }
                        }
                    }
                    if query.isEmpty { folderNavigation }
                    librarySection(documents)
                }
            }
            .padding(.horizontal, Layout.pageInset).padding(.top, 6).padding(.bottom, 24)
        }
        .background(Palette.paper).accessibilityIdentifier("libraryScrollView")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if selecting {
                    Text("\(selectedIDs.count) selected").font(.headline).fixedSize()
                        .accessibilityIdentifier("librarySelectionCount")
                } else { Text("Home").font(.subheadline).foregroundStyle(.primary).fixedSize() }
            }.sharedBackgroundVisibility(.hidden)
            ToolbarItemGroup(placement: .topBarTrailing) {
                if selecting {
                    Button("Done") { selecting = false; selectedIDs = [] }
                        .accessibilityIdentifier("finishLibrarySelection")
                } else {
                    Button {
                        preferences.libraryLayout = preferences.libraryLayout == .grid ? .list : .grid
                    } label: {
                        Image(systemName: effectiveLayout == .grid ? "list.bullet" : "square.grid.2x2")
                    }
                    .accessibilityLabel(effectiveLayout == .grid ? "Show list" : "Show grid")
                    .accessibilityIdentifier("libraryLayoutToggle")
                    .foregroundStyle(.primary)
                    .disabled(dynamicTypeSize.isAccessibilitySize)
                    Menu {
                        Button("New folder", systemImage: "folder.badge.plus") { newFolder() }
                        Button("Select documents", systemImage: "checkmark.circle") { selecting = true; selectedIDs = [] }
                        Button("Settings", systemImage: "gearshape") { showAbout = true }
                    } label: { Image(systemName: "gearshape").foregroundStyle(.primary) }
                    .accessibilityLabel("Library actions").accessibilityIdentifier("Library actions")
                }
            }
            if !selecting {
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) { Spacer() }
                ToolbarItem(placement: .bottomBar) {
                    Button { store.fileRequest = FileRequest() } label: {
                        Image(systemName: "plus").font(.title3.weight(.semibold))
                    }
                    .buttonStyle(.glassProminent).tint(Palette.accent)
                    .disabled(store.isImporting).accessibilityLabel("Open PDF")
                    .accessibilityIdentifier("importPDF")
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .modifier(LibrarySearch(query: $query, enabled: !selecting))
        .toolbarVisibility(selecting ? .hidden : .visible, for: .bottomBar)
        .safeAreaInset(edge: .bottom) {
            if selecting {
                Button(dynamicTypeSize.isAccessibilitySize ? "Move" : selectedIDs.count == 1 ? "Move 1 document" : "Move \(selectedIDs.count) documents", systemImage: "folder") {
                    move = MoveRequest(documents: selectedIDs)
                }.font(.headline).buttonStyle(.glassProminent).disabled(selectedIDs.isEmpty).padding()
                    .accessibilityLabel(selectedIDs.count == 1 ? "Move 1 document" : "Move \(selectedIDs.count) documents")
                    .accessibilityIdentifier("moveSelectedDocuments")
            }
        }
        .onChange(of: documents.map(\.id)) { _, ids in selectedIDs.formIntersection(ids) }
    }

    private var libraryPresentations: some View {
        libraryContent
            .fullScreenCover(item: $store.selected, onDismiss: { store.readerDismissed() }) { document in
                ReaderView(document: document, store: store, preferences: preferences).id(document.id)
                    .preferredColorScheme(preferences.appearance.colorScheme)
            }
            .sheet(item: $store.fileRequest) { request in
                VStack(spacing: 0) {
                    if request.requiresOriginal {
                        Text("Choose the original PDF in Files to keep reading without importing a copy.").font(.callout).padding()
                    }
                    OriginalPDFPicker { url in
                        store.fileRequest = nil
                        guard let url else { return }
                        let lease = DocumentAccess(url: url)
                        Task {
                            let target = store.documents.first { $0.id == request.documentID }
                            if let document = await store.openReference(url, linking: target, folderID: folderID) {
                                await store.present(document)
                            }
                            withExtendedLifetime(lease) {}
                        }
                    }
                }
            }
            .sheet(item: $move) { FolderDestinationView(store: store, request: $0) }
            .sheet(item: $share) { ShareSheet(url: $0.url) }
            .sheet(isPresented: $showAbout) { SettingsView(preferences: preferences, store: store) }
    }

    private var libraryFolderAlerts: some View {
        libraryPresentations
            .alert(editingFolder == nil ? "New folder" : "Rename folder", isPresented: $folderEditor) {
                TextField("Folder name", text: $folderName)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    if let editingFolder { store.renameFolder(editingFolder, to: folderName) }
                    else { store.createFolder(folderName, parentID: folderID) }
                }
            }
            .alert("Delete folder?", isPresented: $deletingFolder, presenting: folderToDelete) { folder in
                Button("Cancel", role: .cancel) {}
                Button("Delete folder", role: .destructive) { store.deleteFolder(folder) }
            } message: { _ in Text("Its documents and subfolders move to the parent folder. No original PDFs are deleted.") }
    }

    private var libraryDocumentAlerts: some View {
        libraryFolderAlerts
            .alert("Rename document", isPresented: $renaming, presenting: renameTarget) { document in
                TextField("Document name", text: $newTitle)
                Button("Cancel", role: .cancel) {}
                Button("Save") { store.rename(document, to: newTitle) }
            }
            .alert("Remove from library?", isPresented: $deleting, presenting: deleteTarget) { document in
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    Task { await store.delete(document) }
                }
            } message: { _ in Text("This removes its library entry, history, and Folio annotations. Original files in Files stay untouched.") }
    }

    private var libraryAlerts: some View {
        libraryDocumentAlerts
            .alert("Something needs attention", isPresented: Binding(get: { store.error != nil && store.selected == nil }, set: { if !$0 { store.error = nil } })) {
                Button("Retry save") { store.error = nil; store.persist() }
                Button("Dismiss", role: .cancel) { store.error = nil }
            } message: { Text(store.error ?? "") }
            .disabled(exporting || store.isImporting || sampleLoading)
            .overlay {
                if exporting || store.isImporting || sampleLoading {
                    ProgressView(exporting ? "Preparing PDF…" : sampleLoading ? "Opening sample…" : "Opening PDF…")
                        .padding(28).glassEffect()
                }
            }
    }

    private var libraryState: some View {
        libraryAlerts
            .onChange(of: selecting) { _, active in if !active { selectedIDs = [] } }
            .onChange(of: folderID) { _, _ in selectedIDs = [] }
            .onChange(of: query) { _, _ in selectedIDs = [] }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { store.persist() }
            }
            .task { try? await store.files.cleanExports() }
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(selecting ? "Select documents" : !query.isEmpty ? "Search" : "Library")
                .font(.folioDisplay).tracking(-0.8).fixedSize(horizontal: false, vertical: true)
            if selecting && !dynamicTypeSize.isAccessibilitySize {
                Text("Choose documents to move into a folder.").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func librarySection(_ documents: [LibraryDocument]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if !query.isEmpty {
                Text("\(documents.count) \(documents.count == 1 ? "result" : "results")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if documents.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView("No PDFs here", systemImage: "folder", description: Text("Open a PDF or move documents into this folder."))
                } else { ContentUnavailableView.search(text: query) }
            } else if effectiveLayout == .grid {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: horizontalSizeClass == .regular ? 160 : 140), spacing: 18)], alignment: .leading, spacing: 22) {
                    ForEach(documents) { document in documentCell(document) }
                }
                .accessibilityIdentifier("libraryGrid")
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(documents) { document in documentCell(document) }
                }.accessibilityIdentifier("libraryList")
            }
        }
    }

    private func documentCell(_ document: LibraryDocument) -> some View {
        LibraryDocumentCell(document: document, files: store.thumbnails, folder: store.folderPath(document.folderID),
            layout: effectiveLayout, selecting: selecting, selected: selectedIDs.contains(document.id), open: {
                if selecting {
                    if selectedIDs.contains(document.id) { selectedIDs.remove(document.id) }
                    else { selectedIDs.insert(document.id) }
                } else { Task { await store.present(document) } }
            }, action: { perform($0, on: document) })
    }

    private func perform(_ action: LibraryDocumentAction, on document: LibraryDocument) {
        switch action {
        case .open: Task { await store.present(document) }
        case .move: move = MoveRequest(documents: [document.id])
        case .link: store.fileRequest = FileRequest(documentID: document.id)
        case .rename: newTitle = document.title; renameTarget = document; renaming = true
        case .share: export(document)
        case .delete: deleteTarget = document; deleting = true
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 24).fill(Palette.accent.opacity(0.08)).frame(width: 150, height: 150)
                Image(systemName: "doc.text").font(.system(size: 70, weight: .ultraLight)).foregroundStyle(Palette.accent)
                Image(systemName: "bookmark.fill").font(.system(size: 23)).foregroundStyle(Palette.accent)
                    .offset(x: 23, y: -23)
            }.padding(.top, 12)
            VStack(spacing: 8) {
                Text("A home for your PDFs").font(.folioTitle)
                Text("Bring in a document, find your focus,\nand leave a few thoughts in the margins.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button("Explore a sample document", systemImage: "arrow.up.right") {
                guard !sampleLoading else { return }
                sampleLoading = true
                Task {
                    defer { sampleLoading = false }
                    do {
                        let url = URL.temporaryDirectory.appendingPathComponent("The art of focused reading.pdf")
                        try await Task.detached { try SamplePDF.create(at: url) }.value
                        if let document = await store.importPDF(url) { await store.present(document) }
                    } catch { store.error = error.localizedDescription }
                }
            }
            .font(.subheadline.weight(.medium)).frame(minHeight: 44).disabled(sampleLoading)
            .accessibilityIdentifier("sampleDocument")
        }
        .frame(maxWidth: .infinity).padding(.vertical, 20)
    }

    private func newFolder() { editingFolder = nil; folderName = ""; folderEditor = true }

    private var folderNavigation: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let current = folderID {
                HStack(spacing: 8) {
                    FolderChip(title: "Back", symbol: "chevron.left") { folderID = store.foldersByID[current]?.parentID }
                    Text(store.folderPath(current)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FolderChip(title: "All", selected: folderID == nil) { folderID = nil }
                        .accessibilityIdentifier("allDocuments")
                    ForEach(store.folders.filter { $0.parentID == folderID }) { folder in
                        FolderChip(title: folder.name) { folderID = folder.id }
                            .accessibilityIdentifier("folder-\(folder.name)")
                            .contextMenu {
                                Button("Rename folder", systemImage: "pencil") { editingFolder = folder; folderName = folder.name; folderEditor = true }
                                Button("Move folder", systemImage: "folder") { move = MoveRequest(folder: folder.id) }
                                Button("Delete folder", systemImage: "trash", role: .destructive) { folderToDelete = folder; deletingFolder = true }
                            }
                    }
                    Button(action: newFolder) {
                        Image(systemName: "plus").frame(width: Layout.controlSize, height: Layout.controlSize)
                            .background(Palette.secondaryPaper, in: .circle)
                    }.buttonStyle(ScaleButtonStyle()).foregroundStyle(.primary)
                        .accessibilityLabel("Create folder").accessibilityIdentifier("newFolderChip")
                }.padding(.vertical, 4)
            }.contentMargins(.trailing, 4)
        }
    }

    private func export(_ document: LibraryDocument) {
        guard !exporting else { return }
        if document.pageCount == 0 { Task { await store.present(document) }; return }
        exporting = true
        Task {
            defer { exporting = false }
            do {
                let marks = try await store.files.readMarks(document.id)
                let url = try await store.files.export(source: document.source, title: document.title, marks: marks, password: nil)
                share = ShareItem(url: url)
            } catch FolioError.passwordRequired {
                Task { await store.present(document) }
            } catch { store.error = error.localizedDescription }
        }
    }
}

private struct LibrarySearch: ViewModifier {
    @Binding var query: String
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.searchable(text: $query, placement: .toolbar, prompt: "Search") }
        else { content }
    }
}
