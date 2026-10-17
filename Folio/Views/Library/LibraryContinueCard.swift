import SwiftUI

struct LibraryContinueCard: View {
    let document: LibraryDocument
    let files: DocumentFiles
    let open: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: open) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
                : AnyLayout(HStackLayout(spacing: 20))
            layout {
                DocumentThumbnail(document: document, files: files, size: DocumentFiles.coverThumbnailSize)
                    .frame(width: 76, height: 106).rotationEffect(.degrees(-9))
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 5)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Continue reading").font(.subheadline).foregroundStyle(.white.opacity(0.7))
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right").font(.caption.weight(.semibold))
                    }
                    Text(document.title).font(.title3.weight(.semibold)).lineLimit(2)
                    Text(document.pageDescription).font(.caption).foregroundStyle(.white.opacity(0.7))
                    ProgressView(value: min(1, document.progress)).tint(Palette.accent).padding(.top, 2)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.white).background(Palette.inkSurface, in: .rect(cornerRadius: Layout.cardRadius))
            .shadow(color: .black.opacity(0.16), radius: 12, y: 6)
        }
        .buttonStyle(ScaleButtonStyle()).accessibilityIdentifier("continueReading")
        .accessibilityLabel("Continue reading \(document.title), \(document.pageDescription)")
    }
}
