import SwiftUI

struct PageScrubber: View {
    let session: ReaderSession
    let jump: () -> Void
    @State private var startPage: Int?
    @GestureState private var dragActive = false
    @AccessibilityFocusState private var markerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var markerHeight = 32.0

    static func page(at fraction: CGFloat, count: Int) -> Int {
        guard count > 1 else { return 0 }
        return Int((min(1, max(0, fraction)) * CGFloat(count - 1)).rounded())
    }

    var body: some View {
        GeometryReader { geometry in
            let count = max(1, session.record.pageCount)
            let track = max(1, geometry.size.height - max(44, markerHeight))
            let fraction = CGFloat(session.currentPage) / CGFloat(max(1, count - 1))
            let visible = session.chromeVisible && (session.pageMarkerVisible || markerFocused)
            Color.clear.allowsHitTesting(false).overlay(alignment: .topTrailing) {
                if visible {
                    HStack(spacing: 0) {
                        if session.isScrubbing {
                            Text("\(session.currentPage + 1) / \(count)")
                                .font(.caption.monospacedDigit()).padding(10)
                                .background(.regularMaterial, in: .capsule).padding(.trailing, 8)
                        }
                        Text("\(session.currentPage + 1)")
                            .font(.system(.caption, design: .rounded, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.leading, 12).padding(.trailing, 8)
                            .frame(minWidth: 32, minHeight: markerHeight)
                            .background(Color(white: 0.12), in: PageMarkerShape())
                            .overlay { PageMarkerShape().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5) }
                            .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                            .contentShape(.rect)
                            .onTapGesture(perform: jump)
                            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("pageScrubberTrack"))
                                .updating($dragActive) { _, active, _ in active = true }
                                .onChanged { value in
                                    if startPage == nil { startPage = session.currentPage; session.isScrubbing = true }
                                    let origin = CGFloat(startPage ?? 0) / CGFloat(max(1, count - 1))
                                    let target = Self.page(at: origin + value.translation.height / track, count: count)
                                    if target != session.currentPage { session.go(to: target, persist: false) }
                                }.onEnded { _ in startPage = nil; session.endScrub() })
                    }
                    .fixedSize()
                    .offset(y: fraction * track)
                    .allowsHitTesting(visible)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Page scroller")
                    .accessibilityValue("Page \(session.currentPage + 1) of \(count)")
                    .accessibilityAdjustableAction { direction in
                        session.scrollActivity()
                        switch direction {
                        case .increment: session.go(to: min(count - 1, session.currentPage + 1))
                        case .decrement: session.go(to: max(0, session.currentPage - 1))
                        @unknown default: break
                        }
                    }
                    .accessibilityAction(named: "Go to page", jump)
                    .accessibilityIdentifier("pageScrubber")
                    .accessibilityFocused($markerFocused)
                    .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: visible)
        }
        .coordinateSpace(name: "pageScrubberTrack")
        .onChange(of: dragActive) { _, active in
            if !active && session.isScrubbing { startPage = nil; session.endScrub() }
        }
        .onDisappear { startPage = nil; if session.isScrubbing { session.endScrub() } }
    }
}

/// A compact edge tab with a pointed, softly rounded leading shoulder.
private struct PageMarkerShape: InsettableShape {
    var insetAmount: CGFloat = 0
    func inset(by amount: CGFloat) -> some InsettableShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let tip = min(8, r.width / 4)
        return Path { p in
            p.move(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.minX + tip + 4, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.minX + tip, y: r.minY + 3), control: CGPoint(x: r.minX + tip + 1, y: r.minY))
            p.addLine(to: CGPoint(x: r.minX, y: r.midY))
            p.addLine(to: CGPoint(x: r.minX + tip, y: r.maxY - 3))
            p.addQuadCurve(to: CGPoint(x: r.minX + tip + 4, y: r.maxY), control: CGPoint(x: r.minX + tip + 1, y: r.maxY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.closeSubpath()
        }
    }
}
