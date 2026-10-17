import SwiftUI

struct LibraryPrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsCard(title: "Your documents", symbol: "folder.fill", color: .teal) {
                    helpRow("doc", "Open PDFs directly from Files. Folio remembers access without importing a copy.")
                    helpRow("folder", "Folders organize your library without moving original files.")
                    helpRow("link", "Older imported PDFs still work. Use Link original in Files to replace a managed copy with a reference.")
                }
                SettingsCard(title: "On this device", symbol: "lock.fill", color: .indigo) {
                    helpRow("internaldrive", "Reading progress, bookmarks, folders, and annotations are stored locally.")
                    helpRow("pencil.tip", "Markup saves separately. Share PDF creates a portable copy with your annotations.")
                    helpRow("eye.slash", "No analytics. iCloud reading-data sync is disabled for this release. PDFs in iCloud Drive are available through Files.")
                }
            }.padding(Layout.pageInset)
        }
        .background(Palette.paper).navigationTitle("Library & privacy").navigationBarTitleDisplayMode(.inline)
    }

    private func helpRow(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
    }
}

struct TipsAndGesturesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsCard(title: "Reading", symbol: "book.fill", color: .red) {
                    tip("Scroll vertically, or choose Flip for a book-style page turn with a horizontal swipe.")
                    tip("In Scroll mode, tap a stationary page to hide or restore controls. Flip keeps them visible.")
                    tip("Pinch to zoom. When zoomed in, drag to pan; zoom back out before turning pages in Flip.")
                    tip("Page-turn sound plays only after a completed Flip turn. It respects device volume and silent mode.")
                }
                SettingsCard(title: "Annotating", symbol: "pencil.tip", color: .purple) {
                    tip("Hold text to select it, then choose Highlight, Underline, or Strikethrough. Tap outside to deselect.")
                    tip("With the pen or eraser, use one finger to draw or erase and two to navigate.")
                    tip("Notes and pen work on scanned PDFs too. The eraser removes whole strokes.")
                    tip("Tap a Folio annotation to select or delete it. Tap a note to edit it. Done returns to reading.")
                }
                SettingsCard(title: "Page scroller", symbol: "arrow.up.arrow.down", color: .orange) {
                    tip("In Scroll mode, drag the right-edge page tab to skim, or tap it to jump. It fades after 1.5 seconds of inactivity and hides in fullscreen.")
                    tip("Tap the bottom page counter to jump in either mode. Open the grid for thumbnails or the bookmark to keep a page close.")
                }
            }.padding(Layout.pageInset)
        }
        .background(Palette.paper).navigationTitle("Tips & gestures").navigationBarTitleDisplayMode(.inline)
    }
    private func tip(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).padding(.vertical, 3)
    }
}
