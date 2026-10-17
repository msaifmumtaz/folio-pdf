import SwiftUI
import UniformTypeIdentifiers

struct OriginalPDFPicker: UIViewControllerRepresentable {
    let complete: (URL?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(complete: complete) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let complete: (URL?) -> Void
        init(complete: @escaping (URL?) -> Void) { self.complete = complete }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { complete(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { complete(nil) }
    }
}

struct MoveRequest: Identifiable {
    let id = UUID()
    var documents: Set<UUID> = []
    var folder: UUID?
}

struct FolderDestinationView: View {
    let store: LibraryStore
    let request: MoveRequest
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                destination("Library", id: nil)
                ForEach(store.folders.sorted { store.folderPath($0.id).localizedStandardCompare(store.folderPath($1.id)) == .orderedAscending }) { folder in
                    destination(store.folderPath(folder.id), id: folder.id)
                }
            }
            .navigationTitle("Move to folder").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
    private func destination(_ title: String, id: UUID?) -> some View {
        Button {
            if let folderID = request.folder, let folder = store.folders.first(where: { $0.id == folderID }) {
                store.moveFolder(folder, to: id)
            } else { store.moveDocuments(request.documents, to: id) }
            dismiss()
        } label: { Label(title, systemImage: id == nil ? "books.vertical" : "folder") }
        .accessibilityIdentifier("destination-\(title)")
        .disabled(request.folder.map { !store.canMoveFolder($0, to: id) } ?? false)
    }
}
