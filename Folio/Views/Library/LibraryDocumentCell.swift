import SwiftUI

enum LibraryDocumentAction { case open, move, link, rename, share, delete }

struct LibraryDocumentActions: View {
    let document: LibraryDocument
    let action: (LibraryDocumentAction) -> Void
    var body: some View {
        Button("Open", systemImage: "book") { action(.open) }
        Button("Move to folder", systemImage: "folder") { action(.move) }
        Button(document.needsLocation ? "Locate PDF" : "Link original in Files", systemImage: "link") { action(.link) }
        Button("Rename", systemImage: "pencil") { action(.rename) }
        Button("Share PDF", systemImage: "square.and.arrow.up") { action(.share) }
        Button("Delete", systemImage: "trash", role: .destructive) { action(.delete) }
    }
}

struct LibraryDocumentCell: View {
    let document: LibraryDocument
    let files: DocumentFiles
    let folder: String
    let layout: AppPreferences.LibraryLayout
    let selecting: Bool
    let selected: Bool
    let open: () -> Void
    let action: (LibraryDocumentAction) -> Void

    private var progressDescription: String {
        document.pageCount > 0 ? "\(document.pageCount) pages · \(Int((min(1, document.progress) * 100).rounded()))%" : "Password protected"
    }

    var body: some View {
        Group {
            if layout == .grid { gridCard }
            else { listRow }
        }
        .contextMenu {
            if !selecting { LibraryDocumentActions(document: document, action: action) }
        }
    }

    private var documentButton: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                CoverThumbnail(document: document, files: files, selected: selected, selecting: selecting)
                    .aspectRatio(0.75, contentMode: .fit)
                Text(document.title).font(.subheadline.weight(.medium)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.contentShape(.rect)
        }
        .buttonStyle(ScaleButtonStyle()).foregroundStyle(.primary)
        .accessibilityIdentifier("document-\(document.title)")
        .accessibilityLabel("\(document.title), \(progressDescription), \(folder)")
        .accessibilityHint(selecting ? "Select document to move" : "Open PDF")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var gridCard: some View {
        VStack(alignment: .leading, spacing: 2) {
            documentButton
            HStack(spacing: 4) {
                Text(progressDescription).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                ProgressRing(progress: document.progress)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !selecting { actionsMenu.background(.regularMaterial, in: .circle).padding(6) }
        }
    }

    private var listRow: some View {
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 14) {
                    CoverThumbnail(document: document, files: files, selected: selected, selecting: selecting)
                        .frame(width: 70, height: 90)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(document.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text(progressDescription).font(.caption).foregroundStyle(.secondary)
                        Text(folder).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        if document.needsLocation {
                            Label("Locate PDF", systemImage: "doc.badge.ellipsis")
                                .font(.caption).foregroundStyle(Palette.accent)
                        }
                    }
                    Spacer(minLength: 0)
                }.contentShape(.rect)
            }
            .buttonStyle(ScaleButtonStyle()).foregroundStyle(.primary)
            .accessibilityIdentifier("document-\(document.title)")
            .accessibilityLabel("\(document.title), \(progressDescription), \(folder)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            if !selecting { actionsMenu }
        }
        .padding(12).background(Palette.card, in: .rect(cornerRadius: Layout.cardRadius))
    }

    private var actionsMenu: some View {
        Menu { LibraryDocumentActions(document: document, action: action) } label: {
            Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold))
                .frame(width: Layout.controlSize, height: Layout.controlSize)
        }
        .foregroundStyle(.secondary).accessibilityLabel("Actions for \(document.title)")
    }
}
