import SwiftUI

enum Layout {
    static let controlSize: CGFloat = 44
    static let pageInset: CGFloat = 20
    static let cardRadius: CGFloat = 18
    static let panelRadius: CGFloat = 24
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 20
        static let xl: CGFloat = 28
    }
    enum Radius {
        static let cover: CGFloat = 7
        static let card: CGFloat = 18
        static let panel: CGFloat = 24
    }
}

enum Palette {
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 1, green: 107/255, blue: 107/255, alpha: 1)
        : UIColor(red: 211/255, green: 47/255, blue: 47/255, alpha: 1)
    })
    static let inkSurface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.12, green: 0.19, blue: 0.25, alpha: 1)
        : UIColor(red: 0.07, green: 0.13, blue: 0.20, alpha: 1)
    })
    static let ink = inkSurface
    static let hairline = Color.primary.opacity(0.08)
    static let secondaryPaper = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.12, green: 0.14, blue: 0.15, alpha: 1)
        : UIColor(red: 0.93, green: 0.92, blue: 0.89, alpha: 1)
    })
    static let paper = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.07, green: 0.09, blue: 0.10, alpha: 1)
        : UIColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1)
    })
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
}

struct SectionEyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(.caption2, design: .rounded, weight: .bold))
            .tracking(2).foregroundStyle(.secondary)
    }
}

struct DocumentThumbnail: View {
    let document: LibraryDocument
    let files: DocumentFiles
    var size: CGSize = DocumentFiles.pageThumbnailSize
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.white
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: document.pageCount == 0 ? "lock.doc" : "doc.text")
                    .font(.title).foregroundStyle(Palette.accent.opacity(0.6))
            }
        }
        .clipped()
        .clipShape(.rect(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.black.opacity(0.06)))
        .accessibilityHidden(true)
        .task(id: "\(document.fingerprint)-\(document.sourceKind ?? "managed")-\(document.sourcePath ?? "")-\(size.width)") {
            do {
                let preview = try await ThumbnailCache.shared.image(files: files, source: document.source,
                    fingerprint: document.fingerprint, size: size)
                try Task.checkCancellation()
                image = preview
            } catch { /* A missing preview never prevents opening a document. */ }
        }
    }
}

extension Font {
    static let folioDisplay = Font.system(.largeTitle, design: .serif, weight: .bold)
    static let folioTitle = Font.system(.title2, design: .serif, weight: .semibold)
}

struct GlassIconButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 19, weight: .medium))
                .frame(width: Layout.controlSize, height: Layout.controlSize)
        }
        .buttonStyle(.plain).folioGlass(in: Circle(), interactive: true)
        .accessibilityLabel(title)
    }
}

extension View {
    func folioGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(FolioGlass(shape: shape, interactive: interactive))
    }
}

private struct FolioGlass<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

struct ProgressRing: View {
    let progress: Double
    var body: some View {
        ZStack {
            Circle().stroke(Palette.hairline, lineWidth: 2)
            Circle().trim(from: 0, to: min(1, max(0, progress)))
                .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }.frame(width: 19, height: 19).accessibilityHidden(true)
    }
}

struct FolderChip: View {
    let title: String
    var symbol: String? = nil
    var selected = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol) }
                Text(title).lineLimit(1)
            }
            .font(.subheadline.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 17).frame(minHeight: Layout.controlSize)
            .background(selected ? Palette.card : Palette.secondaryPaper, in: .capsule)
            .shadow(color: .black.opacity(selected ? 0.07 : 0), radius: 5, y: 2)
        }.buttonStyle(ScaleButtonStyle())
            .foregroundStyle(.primary).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SettingsIcon: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white).frame(width: 30, height: 30)
            .background(color.gradient, in: .rect(cornerRadius: 8)).accessibilityHidden(true)
    }
}

struct CoverThumbnail: View {
    let document: LibraryDocument
    let files: DocumentFiles
    var selected = false
    var selecting = false
    var body: some View {
        DocumentThumbnail(document: document, files: files, size: DocumentFiles.coverThumbnailSize)
            .padding(10).background(Palette.card, in: .rect(cornerRadius: Layout.cardRadius))
            .overlay(alignment: selecting ? .topTrailing : .bottomLeading) {
                if selecting {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title2).foregroundStyle(selected ? Palette.accent : .secondary)
                        .background(Palette.card, in: .circle).padding(8)
                } else if document.needsLocation || document.pageCount == 0 {
                    Image(systemName: document.needsLocation ? "doc.badge.ellipsis" : "lock.fill")
                        .font(.caption.weight(.semibold)).padding(8)
                        .background(.regularMaterial, in: .circle).padding(6)
                }
            }
            .shadow(color: .black.opacity(0.08), radius: 8, y: 4).accessibilityHidden(true)
    }
}

struct ScaleButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}
