import SwiftUI
import PDFKit

private enum ReaderSheet: String, Identifiable {
    case pages, search, bookmarks, locate, jump
    var id: String { rawValue }
}

struct ReaderView: View {
    @State private var session: ReaderSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sheet: ReaderSheet?
    @State private var share: ShareItem?
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var closing = false
    @State private var showToolHint = false
    @Namespace private var controlsNamespace

    init(document: LibraryDocument, store: LibraryStore, preferences: AppPreferences) {
        _session = State(initialValue: ReaderSession(record: document, store: store, preferences: preferences))
    }

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()
            if session.pdf != nil {
                PDFReaderHost(session: session)
                    .ignoresSafeArea(.container, edges: session.chromeVisible ? [] : .all)
                if !session.ready { ProgressView("Opening your page…").padding().glassEffect() }
            } else if session.requiresPassword {
                passwordView
            } else if session.loading {
                ProgressView("Opening document…")
            } else if let error = session.error {
                ContentUnavailableView {
                    Label("Couldn’t open this PDF", systemImage: "doc.badge.ellipsis")
                } description: { Text(error) } actions: {
                    if session.sourceChanged {
                        Button("Open updated version") { Task { await session.store.openUpdatedVersion(session.record) } }
                    } else {
                        Button("Locate PDF", systemImage: "folder") { sheet = .locate }
                    }
                    Button("Try again") { Task { await session.open() } }.buttonStyle(.borderedProminent)
                }
            }
        }
        .overlay(alignment: .trailing) {
            if session.ready && session.chromeVisible && session.readingMode == .verticalScroll {
                PageScrubber(session: session) { sheet = .jump }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 8) {
                if session.chromeVisible || session.pdf == nil { topBar }
                if let saveError = session.saveError {
                    saveBanner(saveError) { session.retrySave() }
                }
                if let error = session.store.error {
                    saveBanner(error) { session.store.error = nil; session.store.persist() }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if session.chromeVisible && session.ready { bottomControls }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: session.chromeVisible)
        .statusBarHidden(!session.chromeVisible)
        .persistentSystemOverlays(session.chromeVisible ? .automatic : .hidden)
        .onDisappear { session.close() }
        .task(id: "\(session.store.sync?.annotationGeneration ?? 0)-\(session.drawingStroke)-\(session.isScrubbing)-\(session.noteDraft == nil)-\(session.isSaving)") {
            await session.mergeRemoteAnnotations()
        }
        .task { await session.open() }
        .onChange(of: scenePhase) { _, phase in
            session.setSceneActive(phase == .active)
            if phase != .active { session.pageChanged(); Task { _ = await session.flush() } }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .pages: PageBrowser(session: session)
            case .search: SearchSheet(session: session)
            case .bookmarks: BookmarksSheet(session: session)
            case .jump: PageJumpSheet(session: session)
            case .locate:
                OriginalPDFPicker { url in
                    self.sheet = nil
                    guard let url else { return }
                    let lease = DocumentAccess(url: url)
                    Task {
                        if await session.store.openReference(url, linking: session.record) != nil { await session.open() }
                        withExtendedLifetime(lease) {}
                    }
                }
            }
        }
        .sheet(item: $session.noteDraft) { draft in
            NoteEditor(draft: draft, canEdit: session.allowsMarkup) { text in session.saveNote(draft, text: text) }
        }
        .sheet(item: $share) { ShareSheet(url: $0.url) }
        .alert("Couldn’t complete the action", isPresented: Binding(
            get: { session.error != nil && session.pdf != nil },
            set: { if !$0 { session.error = nil } }
        )) {
            Button("OK", role: .cancel) { session.error = nil }
        } message: { Text(session.error ?? "") }
        .disabled(closing || session.exporting)
        .overlay {
            if closing || session.exporting { ProgressView(session.exporting ? "Preparing PDF…" : "Saving…").padding(24).glassEffect() }
        }
        .interactiveDismissDisabled(session.hasUnsavedChanges)
    }

    private var topBar: some View {
        ViewThatFits(in: .horizontal) {
            topBarContent(showSearchText: true).fixedSize(horizontal: true, vertical: false)
            topBarContent(showSearchText: false)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16).padding(.vertical, 10).background(Palette.paper)
    }

    private func topBarContent(showSearchText: Bool) -> some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    closing = true
                    defer { closing = false }
                    session.pageChanged()
                    if await session.flush() { dismiss() }
                }
            } label: { Image(systemName: "chevron.left").font(.system(size: 20, weight: .medium)).frame(width: Layout.controlSize, height: Layout.controlSize) }
            .buttonStyle(.glass).accessibilityLabel("Back to library").accessibilityIdentifier("closeReader")
            VStack(alignment: .leading, spacing: 2) {
                Text(session.record.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if !dynamicTypeSize.isAccessibilitySize && verticalSizeClass != .compact {
                    Text(session.isSaving ? "Saving markup…" : "FOLIO PDF")
                        .font(.caption2.weight(.medium)).tracking(1).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if session.ready {
                Button { sheet = .search } label: {
                    if showSearchText { Label("Search", systemImage: "magnifyingglass").fixedSize() }
                    else { Image(systemName: "magnifyingglass").font(.system(size: 20)) }
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Search document").accessibilityIdentifier("searchDocument")
                Menu {
                    Button("Share PDF", systemImage: "square.and.arrow.up") {
                        Task { if let url = await session.export() { share = ShareItem(url: url) } }
                    }
                    Button("Bookmarks", systemImage: "bookmark") { sheet = .bookmarks }
                    Button("Page thumbnails", systemImage: "square.grid.2x2") { sheet = .pages }
                } label: { Image(systemName: "ellipsis").font(.system(size: 20, weight: .semibold)).frame(width: Layout.controlSize, height: Layout.controlSize) }
                .accessibilityLabel("Document actions")
            }
        }
    }

    private var bottomControls: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                if session.selectedMark != nil || session.selectionAvailable || (session.markupVisible && session.allowsMarkup) {
                    annotationControls
                }
                navigationBar
            }
        }
        .padding(.horizontal, Layout.pageInset).padding(.top, 8).padding(.bottom, 8)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.28), value: session.markupVisible)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.28), value: session.selectionAvailable)
        .task(id: "\(session.markupVisible)-\(session.tool.rawValue)") {
            showToolHint = session.markupVisible
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            withAnimation(.easeOut(duration: 0.2)) { showToolHint = false }
        }
    }

    private var annotationControls: some View {
        Group {
            if verticalSizeClass == .compact || dynamicTypeSize.isAccessibilitySize {
                ScrollView(.vertical) { annotationPanel }
                    .frame(height: verticalSizeClass == .compact ? 104 : 190)
                    .clipped()
            } else {
                annotationPanel
            }
        }
        // Glass belongs to the viewport; applying it inside the scroll view can
        // lift oversized content above its clip and overlap the navigation bar.
        .glassEffect(in: .rect(cornerRadius: Layout.panelRadius))
        .glassEffectID("annotationTray", in: controlsNamespace)
        .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
    }

    private var annotationPanel: some View {
        VStack(spacing: 8) {
            if session.selectedMark != nil {
                HStack {
                    Label("Annotation selected", systemImage: "pencil.circle").font(.caption)
                    Spacer(minLength: 4)
                    Button("Delete", role: .destructive) { session.deleteSelected() }
                        .disabled(!session.allowsMarkup).font(.caption.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                    Button("Deselect annotation", systemImage: "xmark") { session.selectedMarkID = nil }
                        .labelStyle(.iconOnly).font(.system(size: 20)).frame(width: 44, height: 44)
                }
                .padding(.horizontal, 12)
            }
            if session.selectionAvailable {
                selectionControls
            } else if session.markupVisible && session.allowsMarkup {
                markupBar
            }
        }
    }

    private var selectionControls: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    if session.allowsMarkup {
                        ForEach([ReaderTool.highlight, .underline, .strikeOut], id: \.self) { tool in
                            Button { session.applySelection(tool.markupKind) } label: {
                                Image(systemName: tool.symbol).font(.system(size: 20))
                                    .frame(width: Layout.controlSize, height: Layout.controlSize)
                            }.accessibilityLabel(tool.title)
                        }
                        Divider().frame(height: 22).padding(.horizontal, 4)
                        colorDots
                    }
                }
            }
            Button("Deselect text", systemImage: "xmark") { session.clearTextSelection() }
                .labelStyle(.iconOnly).font(.system(size: 18))
                .frame(width: Layout.controlSize, height: Layout.controlSize)
                .accessibilityIdentifier("clearTextSelection")
        }.padding(.horizontal, 8).padding(.vertical, 4).foregroundStyle(.primary)
    }

    private var navigationBar: some View {
        HStack(spacing: 4) {
            Button("Page thumbnails", systemImage: "square.grid.2x2") { sheet = .pages }
                .labelStyle(.iconOnly).frame(width: Layout.controlSize, height: Layout.controlSize)
            Button { sheet = .jump } label: {
                VStack(spacing: 0) {
                    Text("\(session.currentPage + 1) / \(session.record.pageCount)")
                        .font(.system(.subheadline, design: .rounded, weight: .medium)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.7).frame(minHeight: Layout.controlSize)
                    GeometryReader { geometry in
                        Capsule().fill(Palette.accent)
                            .frame(width: geometry.size.width * min(1, Double(session.currentPage + 1) / Double(max(1, session.record.pageCount))))
                    }
                    .frame(height: 2).background(Palette.hairline, in: .capsule).padding(.horizontal, 8)
                }.frame(minWidth: 70, maxWidth: .infinity)
            }
            .accessibilityLabel("Page \(session.currentPage + 1) of \(session.record.pageCount)")
            .accessibilityHint("Opens Go to page").accessibilityIdentifier("pageIndicator")
            Button {
                session.store.toggleBookmark(session.record, page: session.currentPage)
            } label: {
                Image(systemName: session.isBookmarked ? "bookmark.fill" : "bookmark")
                    .foregroundStyle(session.isBookmarked ? Palette.accent : .primary)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .frame(width: Layout.controlSize, height: Layout.controlSize)
            }
            .accessibilityLabel(session.isBookmarked ? "Remove bookmark" : "Bookmark page")
            .accessibilityIdentifier("bookmarkPage")
            Button {
                if session.markupVisible { session.finishMarkup() }
                else { session.markupVisible = true }
            } label: {
                Image(systemName: session.markupVisible ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                    .foregroundStyle(session.markupVisible ? Palette.accent : .primary)
                    .frame(width: Layout.controlSize, height: Layout.controlSize)
            }
            .disabled(!session.allowsMarkup)
            .accessibilityLabel(session.allowsMarkup ? "Annotation tools" : "Annotations restricted by document")
            .accessibilityAddTraits(session.markupVisible ? .isSelected : [])
            .accessibilityIdentifier("annotationTools")
        }
        .font(.system(size: 20)).foregroundStyle(.primary)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .glassEffect(in: .capsule).glassEffectID("readerNavigation", in: controlsNamespace)
    }

    private var markupBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(ReaderTool.allCases, id: \.self) { tool in
                                Button { session.choose(tool) } label: {
                                    Image(systemName: tool.symbol).font(.system(size: 20))
                                        .frame(width: Layout.controlSize, height: Layout.controlSize)
                                        .background(session.tool == tool ? Palette.accent.opacity(0.16) : .clear, in: .capsule)
                                }
                                .accessibilityLabel(tool.title).accessibilityIdentifier("tool-\(tool.rawValue)")
                                .accessibilityHint("Choose the \(tool.title.lowercased()) tool")
                                .accessibilityAddTraits(session.tool == tool ? .isSelected : [])
                                .id(tool)
                            }
                        }
                    }.accessibilityIdentifier("annotationToolStrip")
                    .onChange(of: session.tool) { _, tool in
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            proxy.scrollTo(tool, anchor: .center)
                        }
                    }
                }
                Divider().frame(height: 24).padding(.horizontal, 4)
                Button("Undo", systemImage: "arrow.uturn.backward") { session.undo() }
                    .labelStyle(.iconOnly).frame(width: 44, height: 44).disabled(session.undoStack.isEmpty)
                Button("Redo", systemImage: "arrow.uturn.forward") { session.redo() }
                    .labelStyle(.iconOnly).frame(width: 44, height: 44).disabled(session.redoStack.isEmpty)
                Button("Done") { session.finishMarkup() }
                    .font(.subheadline.weight(.semibold)).fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 44, minHeight: 44).padding(.horizontal, 4)
                    .accessibilityIdentifier("finishMarkup")
            }.font(.system(size: 18)).padding(.horizontal, 8)
            if session.tool.usesColor { colorControls }
            Text(toolHint).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.bottom, 8)
                .opacity(showToolHint ? 1 : 0).accessibilityHidden(!showToolHint)
        }
        .foregroundStyle(.primary).padding(.top, 4)
    }

    private var colorDots: some View {
        HStack(spacing: 0) {
            ForEach(InkColor.allCases, id: \.self) { color in
                Button { session.color = color } label: {
                    Circle().fill(Color(uiColor: color.uiColor)).frame(width: 22, height: 22)
                        .overlay {
                            if session.color == color {
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(color == .graphite ? .white : .black)
                            }
                        }
                        .overlay(Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 1))
                        .frame(width: Layout.controlSize, height: Layout.controlSize)
                }
                .accessibilityLabel("\(color.rawValue.capitalized) ink")
                .accessibilityAddTraits(session.color == color ? .isSelected : [])
            }
        }
    }

    private var colorControls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                colorDots
                if session.tool == .pen && !session.selectionAvailable {
                    Menu {
                        ForEach([1.5, 3.0, 6.0], id: \.self) { width in
                            Button {
                                session.lineWidth = width
                            } label: {
                                if session.lineWidth == width { Label("\(width.formatted()) pt", systemImage: "checkmark") }
                                else { Text("\(width.formatted()) pt") }
                            }
                        }
                    } label: {
                        Label("\(session.lineWidth.formatted()) pt", systemImage: "lineweight")
                            .font(.caption).frame(minWidth: 44, minHeight: 44).padding(.horizontal, 8)
                    }
                    .accessibilityLabel("Pen thickness").accessibilityValue("\(session.lineWidth.formatted()) points")
                }
            }.padding(.horizontal, 8)
        }
    }

    private var toolHint: String {
        switch session.tool {
        case .read: "Drag to read · Hold to select text"
        case .pen: "One finger to draw · Two fingers to scroll"
        case .eraser: "Touch a pen stroke to erase it"
        case .note: "Tap the page to leave a note"
        default: "Select text, then tap its markup action"
        }
    }

    private var passwordView: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.doc").font(.system(size: 52, weight: .light)).foregroundStyle(Palette.accent)
            Text("A private document").font(.system(.title, design: .serif))
            Text("Enter its password to start reading.\nPasswords aren’t stored by Folio.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            SecureField("Document password", text: $session.password)
                .textFieldStyle(.roundedBorder).textContentType(.password)
                .onSubmit { Task { await session.open() } }.accessibilityIdentifier("pdfPassword")
            if let error = session.error { Text(error).font(.caption).foregroundStyle(.red) }
            Button("Unlock PDF") { Task { await session.open() } }
                .buttonStyle(.glassProminent).disabled(session.password.isEmpty || session.loading)
        }.padding(36)
    }

    private func saveBanner(_ text: String, retry: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
            Text(text).font(.caption)
            Button("Retry", action: retry).font(.caption.bold()).frame(minWidth: 44, minHeight: 44)
        }
        .padding(12).background(.orange.opacity(0.15), in: .rect(cornerRadius: 12)).padding(.horizontal)
    }
}

enum PageJumpInput {
    static func page(from text: String, count: Int) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard count > 0, !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }),
              let page = Int(trimmed), (1...count).contains(page) else { return nil }
        return page - 1
    }
}

private struct PageJumpSheet: View {
    let session: ReaderSession
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init(session: ReaderSession) {
        self.session = session
        _text = State(initialValue: "\(session.currentPage + 1)")
    }

    private var target: Int? { PageJumpInput.page(from: text, count: session.record.pageCount) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Page number", text: $text)
                        .keyboardType(.numberPad).focused($focused)
                        .accessibilityIdentifier("pageNumberInput")
                        .onSubmit(go)
                } header: {
                    Text("Page 1–\(session.record.pageCount)")
                } footer: {
                    if target == nil && !text.isEmpty {
                        Label("Enter a whole number from 1 to \(session.record.pageCount).", systemImage: "exclamationmark.circle")
                            .foregroundStyle(Palette.accent).accessibilityIdentifier("pageNumberError")
                    } else {
                        Text("Currently reading page \(session.currentPage + 1).")
                    }
                }
            }
            .navigationTitle("Go to page").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Go", action: go).disabled(target == nil).accessibilityIdentifier("goToPage")
                }
            }
            .task { focused = true }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func go() {
        guard let target else { return }
        session.clearTextSelection()
        session.go(to: target)
        dismiss()
    }
}

private struct NoteEditor: View {
    let draft: NoteDraft
    let canEdit: Bool
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(draft: NoteDraft, canEdit: Bool, save: @escaping (String) -> Void) {
        self.draft = draft; self.canEdit = canEdit; self.save = save
        _text = State(initialValue: draft.text)
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text).padding(20).scrollContentBackground(.hidden)
                .background(Palette.paper).disabled(!canEdit).accessibilityIdentifier("noteText")
                .navigationTitle("Note · Page \(draft.page + 1)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save note") { save(text); dismiss() }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canEdit)
                    }
                }
        }.presentationDetents([.medium, .large])
    }
}

private struct SearchSheet: View {
    @Bindable var session: ReaderSession
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if session.searching { ProgressView("Searching…") }
                if session.searchResults.isEmpty && !session.searching {
                    ContentUnavailableView {
                        Label(query.isEmpty ? "Find a thought" : "No matching text", systemImage: "magnifyingglass")
                    } description: {
                        Text(query.isEmpty ? "Search for a word or phrase in this PDF." : "Scanned pages may not contain searchable text.")
                    }
                }
                ForEach(session.searchResults) { hit in
                    Button {
                        session.show(hit); dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Page \(hit.page + 1)").font(.caption.weight(.semibold)).foregroundStyle(Palette.accent)
                            Text(hit.excerpt).font(.subheadline).foregroundStyle(.primary).lineLimit(3)
                        }
                    }
                }
                if session.searchResults.count == 200 {
                    Text("Showing the first 200 matches. Refine your search to narrow the results.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, prompt: "Word or phrase").navigationTitle("Search document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { session.search(query) }
            .onChange(of: query) { _, value in session.search(value) }
            .onDisappear { session.closeSearch() }
        }
    }
}

private struct PageBrowser: View {
    let session: ReaderSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 95), spacing: 18)], spacing: 20) {
                        ForEach(0..<session.record.pageCount, id: \.self) { index in
                            Button { session.go(to: index); dismiss() } label: {
                                PageTile(session: session, index: index)
                                    .accessibilityHidden(true)
                            }
                            .buttonStyle(.plain).id(index)
                            .accessibilityLabel("Page \(index + 1)")
                            .accessibilityIdentifier("thumbnail-\(index)")
                        }
                    }.padding(20)
                }
                .onAppear { proxy.scrollTo(session.currentPage, anchor: .center) }
            }
            .background(Palette.paper).navigationTitle("Pages").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct PageTile: View {
    let session: ReaderSession
    let index: Int
    @State private var image: UIImage?
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Color.white
                if let image { Image(uiImage: image).resizable().scaledToFit() }
                else { Image(systemName: "doc.text").foregroundStyle(Palette.accent.opacity(0.4)) }
            }
            .frame(height: 145).clipShape(.rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(session.currentPage == index ? Palette.accent : .clear, lineWidth: 3))
            HStack(spacing: 4) {
                Text("\(index + 1)").font(.caption.monospacedDigit())
                if session.record.bookmarks.contains(index) { Image(systemName: "bookmark.fill").font(.caption2) }
            }
        }
        .task(id: "\(session.record.fingerprint)-\(index)") {
            do {
                let preview = try await ThumbnailCache.shared.image(files: session.store.thumbnails,
                    source: session.record.source, fingerprint: session.record.fingerprint,
                    page: index, password: session.password)
                try Task.checkCancellation()
                image = preview
            } catch { }
        }
    }
}

private struct BookmarksSheet: View {
    let session: ReaderSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if session.record.bookmarks.isEmpty {
                    ContentUnavailableView("Keep a page close", systemImage: "bookmark",
                        description: Text("Tap the bookmark in the reader to save a page here."))
                }
                ForEach(session.record.bookmarks, id: \.self) { page in
                    Button { session.go(to: page); dismiss() } label: {
                        Label("Page \(page + 1)", systemImage: "bookmark.fill")
                    }
                    .swipeActions { Button("Remove", role: .destructive) { session.store.toggleBookmark(session.record, page: page) } }
                }
            }
            .navigationTitle("Bookmarks").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
