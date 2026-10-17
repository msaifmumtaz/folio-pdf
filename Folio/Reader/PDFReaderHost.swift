import SwiftUI
import PDFKit
import UIKit.UIGestureRecognizerSubclass

struct PDFReaderHost: UIViewControllerRepresentable {
    let session: ReaderSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var effectiveReduceMotion: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return reduceMotion || (arguments.contains("--ui-testing") && arguments.contains("--reduce-motion"))
    }
    func makeUIViewController(context: Context) -> UIViewController {
        if session.readingMode == .flip { return BookPDFController(session: session, reduceMotion: effectiveReduceMotion) }
        return PDFHostController(session: session)
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) {
        if let book = controller as? BookPDFController { book.reduceMotion = effectiveReduceMotion; book.update() }
        else if let canvas = controller as? PDFHostController { canvas.update() }
    }
    static func dismantleUIViewController(_ controller: UIViewController, coordinator: ()) {
        if let book = controller as? BookPDFController { book.tearDown() }
        else if let canvas = controller as? PDFHostController { canvas.tearDown() }
    }
}

@MainActor
final class PDFHostController: UIViewController, UIGestureRecognizerDelegate, ReaderNavigating {
    let session: ReaderSession
    let pdfView = ReaderPDFView()
    private let strokeLayer = CAShapeLayer()
    private var observations: [NSObjectProtocol] = []
    private var points: [CGPoint] = []
    private var strokePage: PDFPage?
    private var restored = false
    private var drawGesture: UIPanGestureRecognizer!
    private var tapGesture: ReaderPageTapRecognizer!
    private var motionDisplayLink: CADisplayLink?
    private var motionTarget: ReaderMotionTarget?
    private weak var scrollView: UIScrollView?
    private var scrollObservation: NSKeyValueObservation?
    private var layoutSize: CGSize = .zero
    private var visibleAnchor: PDFDestination?
    private var savedScale: CGFloat?
    private var savedZoomRatio: CGFloat?
    private(set) var fixedPage: Int?
    var onPageNavigation: ((Int) -> Void)?
    var onInteractionChanged: (() -> Void)?
    var isActive: Bool { session.pdfView === pdfView }
    var isZoomed: Bool { pdfView.scaleFactor > pdfView.scaleFactorForSizeToFit * 1.05 }

    init(session: ReaderSession, fixedPage: Int? = nil) {
        self.session = session
        self.fixedPage = fixedPage
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: view.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        pdfView.displayMode = fixedPage == nil ? .singlePageContinuous : .singlePage
        pdfView.displayDirection = .vertical
        pdfView.displayBox = .cropBox
        pdfView.autoScales = true
        pdfView.displaysPageBreaks = fixedPage == nil
        pdfView.pageBreakMargins = fixedPage == nil ? UIEdgeInsets(top: 5, left: 0, bottom: 5, right: 0) : .zero
        pdfView.backgroundColor = .secondarySystemBackground
        pdfView.accessibilityIdentifier = "pdfCanvas"
        pdfView.alpha = 0
        if fixedPage == nil { session.pdfView = pdfView; session.navigation = self }
        strokeLayer.fillColor = nil
        strokeLayer.lineCap = .round
        strokeLayer.lineJoin = .round
        pdfView.layer.addSublayer(strokeLayer)
        drawGesture = UIPanGestureRecognizer(target: self, action: #selector(draw(_:)))
        drawGesture.maximumNumberOfTouches = 1
        drawGesture.minimumNumberOfTouches = 1
        drawGesture.delegate = self
        pdfView.addGestureRecognizer(drawGesture)
        tapGesture = ReaderPageTapRecognizer(target: self, action: #selector(tap(_:)))
        tapGesture.isEligible = { [weak self] in self?.canAcceptPageTap == true }
        tapGesture.captureSelection = { [weak self] in
            guard let self else { return nil }
            return ReaderTextSelection(in: self.pdfView)
        }
        tapGesture.delegate = self
        tapGesture.cancelsTouchesInView = false
        pdfView.addGestureRecognizer(tapGesture)
        observations.append(NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive, self.restored, self.layoutSize == self.view.bounds.size else { return }
                if let fixed = self.fixedPage, let page = self.pdfView.currentPage,
                   let index = self.session.pdf?.index(for: page), index != NSNotFound, index != fixed {
                    self.fixedPage = index
                    self.onPageNavigation?(index)
                } else if self.fixedPage == nil {
                    self.session.pageChanged()
                }
            }
        })
        observations.append(NotificationCenter.default.addObserver(forName: .PDFViewSelectionChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                self.session.selectionAvailable = self.pdfView.currentSelection?.string?.isEmpty == false
                if self.session.selectionAvailable { self.session.chromeVisible = true }
                self.onInteractionChanged?()
            }
        })
        observations.append(NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                self.updateScrollGestures()
                self.captureAnchor()
                self.onInteractionChanged?()
            }
        })
        update()
    }

    func update() {
        guard isViewLoaded else { return }
        if pdfView.document !== session.pdf {
            restored = false
            pdfView.alpha = 0
            pdfView.document = session.pdf
            view.setNeedsLayout()
        }
        let drawing = session.tool == .pen || session.tool == .eraser
        drawGesture.isEnabled = isActive && drawing && session.allowsMarkup
        let foundScroll = findScroll(in: pdfView)
        if foundScroll !== scrollView {
            detachScrollTracking()
            scrollView = foundScroll
            foundScroll?.panGestureRecognizer.addTarget(self, action: #selector(scrollGestureChanged(_:)))
            foundScroll?.pinchGestureRecognizer?.addTarget(self, action: #selector(scrollGestureChanged(_:)))
            scrollObservation = foundScroll?.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, self.isActive else { return }
                    if self.isScrollMoving { self.startMotionTracking() }
                    self.captureAnchor()
                }
            }
        }
        scrollView?.contentInsetAdjustmentBehavior = .never
        scrollView?.showsVerticalScrollIndicator = false
        scrollView?.contentInset = .zero
        scrollView?.panGestureRecognizer.minimumNumberOfTouches = drawing ? 2 : 1
        updateScrollGestures()
        strokeLayer.strokeColor = session.color.uiColor.cgColor
        strokeLayer.lineWidth = session.lineWidth * pdfView.scaleFactor
    }

    private func updateScrollGestures() {
        // At fit size the book's curl owns swipes; a magnified PDF owns panning.
        if fixedPage != nil { scrollView?.panGestureRecognizer.isEnabled = isZoomed }
    }

    func activate() {
        loadViewIfNeeded()
        session.pdfView = pdfView
        if fixedPage == nil { session.navigation = self }
        update()
        if restored { session.restored() }
    }

    func deactivate() {
        detachScrollTracking()
        pdfView.accessibilityCustomActions = nil
        pdfView.onAccessibilityPageTurn = nil
        drawGesture?.isEnabled = false
    }

    func navigate(to index: Int, completion: @escaping () -> Void) {
        guard let page = session.pdf?.page(at: index) else { return }
        pdfView.go(to: page)
        completion()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        strokeLayer.frame = pdfView.bounds
        if restored {
            if layoutSize != view.bounds.size {
                let anchor = visibleAnchor
                let scale = savedScale
                let zoomRatio = savedZoomRatio
                pdfView.layoutDocumentView()
                if fixedPage != nil {
                    let fitted = pdfView.scaleFactorForSizeToFit * (zoomRatio ?? 1)
                    pdfView.scaleFactor = max(pdfView.minScaleFactor, min(pdfView.maxScaleFactor, fitted))
                } else if let scale {
                    pdfView.scaleFactor = max(pdfView.minScaleFactor, min(pdfView.maxScaleFactor, scale))
                }
                if let anchor { pdfView.go(to: anchor) }
            }
            layoutSize = view.bounds.size
            captureAnchor()
            return
        }
        guard let pdf = session.pdf, pdfView.bounds.width > 0 else { return }
        pdfView.layoutDocumentView()
        if let page = pdf.page(at: min(max(0, fixedPage ?? session.currentPage), pdf.pageCount - 1)) {
            pdfView.go(to: page)
        }
        restored = true
        pdfView.alpha = 1
        layoutSize = view.bounds.size
        captureAnchor()
        if isActive { session.restored() }
        update()
    }

    private func captureAnchor() {
        guard restored, layoutSize == view.bounds.size, !session.isScrubbing else { return }
        let point = CGPoint(x: pdfView.bounds.minX, y: pdfView.bounds.minY + 1)
        if let page = pdfView.currentPage {
            let bounds = page.bounds(for: .cropBox)
            let converted = pdfView.convert(point, to: page)
            let anchor = CGPoint(x: max(bounds.minX, min(bounds.maxX, converted.x)), y: max(bounds.minY, min(bounds.maxY, converted.y)))
            visibleAnchor = PDFDestination(page: page, at: anchor)
            savedScale = pdfView.scaleFactor
            let fit = pdfView.scaleFactorForSizeToFit
            savedZoomRatio = fit > 0 ? pdfView.scaleFactor / fit : 1
        }
    }

    private func findScroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for child in view.subviews { if let scroll = findScroll(in: child) { return scroll } }
        return nil
    }

    @objc private func tap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        handlePageTap(at: gesture.location(in: pdfView), selectionAtStart: tapGesture.selectionAtStart)
    }

    func handlePageTap(at location: CGPoint, selectionAtStart: ReaderTextSelection?) {
        guard canAcceptPageTap, let pdf = session.pdf else { return }
        // PDFKit may already have cleared currentSelection by the time its tap
        // recognizer lets ours finish. The touch-down snapshot owns this tap.
        if let selection = selectionAtStart ?? ReaderTextSelection(in: pdfView) {
            if selection.contains(location) {
                if pdfView.currentSelection == nil {
                    pdfView.setCurrentSelection(selection.selection, animate: false)
                }
            } else {
                session.clearTextSelection()
            }
            return
        }
        // Selection dismissal also works in margins and between PDF pages.
        guard let page = pdfView.page(for: location, nearest: false) else { return }
        let point = pdfView.convert(location, to: page)
        if session.tap(at: point, page: pdf.index(for: page)) { return }
        if session.readingMode == .verticalScroll && session.tool == .read && !session.selectionAvailable {
            // Links and PDFKit widgets own their taps, even in read mode.
            if page.annotation(at: point) != nil { return }
            session.chromeVisible.toggle()
        }
    }

    @objc private func draw(_ gesture: UIPanGestureRecognizer) {
        guard session.ready, let pdf = session.pdf else { return }
        let location = gesture.location(in: pdfView)
        if gesture.state == .began {
            session.drawingStroke = true
            strokePage = pdfView.page(for: location, nearest: false)
            points = []
            session.clearTextSelection()
        }
        guard let page = strokePage else { return }
        let point = pdfView.convert(location, to: page)
        if session.tool == .eraser {
            session.erase(at: point, page: pdf.index(for: page), tolerance: 12 / pdfView.scaleFactor)
        } else if page.bounds(for: .cropBox).contains(point) {
            points.append(point)
            let path = UIBezierPath()
            for (index, point) in points.enumerated() {
                let screen = pdfView.convert(point, from: page)
                if index == 0 { path.move(to: screen) } else { path.addLine(to: screen) }
            }
            strokeLayer.lineWidth = session.lineWidth * pdfView.scaleFactor
            strokeLayer.path = path.cgPath
        }
        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            if gesture.state == .ended && session.tool == .pen {
                session.addStroke(points: points, page: pdf.index(for: page))
            }
            strokeLayer.path = nil
            points = []
            strokePage = nil
            session.drawingStroke = false
        }
    }

    private var isScrollMoving: Bool {
        guard let scrollView else { return false }
        return scrollView.isDragging || scrollView.isDecelerating || scrollView.isZooming || scrollView.isZoomBouncing || scrollView.isZoomAnimating
            || [scrollView.panGestureRecognizer, scrollView.pinchGestureRecognizer].compactMap { $0 }
                .contains { $0.state == .began || $0.state == .changed }
    }

    private var canAcceptPageTap: Bool {
        isActive && session.acceptsPageTap() && !isScrollMoving && !session.drawingStroke
    }

    @objc private func scrollGestureChanged(_ gesture: UIGestureRecognizer) {
        // Track through the frame after lift-off, when deceleration becomes observable.
        startMotionTracking()
    }

    private func startMotionTracking() {
        guard isActive else { return }
        session.setReaderInteraction(active: true)
        guard motionDisplayLink == nil else { return }
        let target = ReaderMotionTarget { [weak self] in self?.sampleMotion() }
        motionTarget = target
        let link = CADisplayLink(target: target, selector: #selector(ReaderMotionTarget.tick))
        motionDisplayLink = link
        link.add(to: .main, forMode: .common)
    }

    private func sampleMotion() {
        guard isActive else { detachScrollTracking(); return }
        if isScrollMoving {
            session.setReaderInteraction(active: true)
        } else {
            motionDisplayLink?.invalidate()
            motionDisplayLink = nil
            motionTarget = nil
            session.setReaderInteraction(active: false)
        }
    }

    private func detachScrollTracking() {
        scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(scrollGestureChanged(_:)))
        scrollView?.pinchGestureRecognizer?.removeTarget(self, action: #selector(scrollGestureChanged(_:)))
        scrollObservation = nil
        motionDisplayLink?.invalidate()
        motionDisplayLink = nil
        motionTarget = nil
        if isActive { session.setReaderInteraction(active: false) }
        scrollView = nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Let PDFKit's own single tap dismiss its edit menu or activate links.
        // Pan, pinch, long press, and multi-tap gestures still take precedence.
        let other = gestureRecognizer === tapGesture ? otherGestureRecognizer : gestureRecognizer
        return (gestureRecognizer === tapGesture || otherGestureRecognizer === tapGesture)
            && tapGesture.selectionAtStart != nil
            && (other as? UITapGestureRecognizer)?.numberOfTapsRequired == 1
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === tapGesture,
              let otherView = otherGestureRecognizer.view,
              otherView === pdfView || otherView.isDescendant(of: pdfView) else { return false }
        if let tap = otherGestureRecognizer as? UITapGestureRecognizer { return tap.numberOfTapsRequired > 1 }
        return otherGestureRecognizer is UIPanGestureRecognizer
            || otherGestureRecognizer is UIPinchGestureRecognizer
            || otherGestureRecognizer is UILongPressGestureRecognizer
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === drawGesture { return isActive && session.ready && session.allowsMarkup }
        if gestureRecognizer === tapGesture { return canAcceptPageTap }
        return session.ready
    }

    func tearDown() {
        for observation in observations { NotificationCenter.default.removeObserver(observation) }
        observations = []
        detachScrollTracking()
        tapGesture?.isEnabled = false
        drawGesture?.isEnabled = false
        pdfView.document = nil
        if isActive { session.pdfView = nil }
        if session.navigation === self { session.navigation = nil }
    }
}

@MainActor
final class ReaderPDFView: PDFView {
    var onAccessibilityPageTurn: ((Bool) -> Bool)?

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        if let turn = onAccessibilityPageTurn {
            if direction == .left || direction == .next { return turn(true) }
            if direction == .right || direction == .previous { return turn(false) }
        }
        return super.accessibilityScroll(direction)
    }
}

/// View-space line rectangles avoid treating the blank area beside a short
/// selected line as selected, including rotated and multi-page selections.
@MainActor
struct ReaderTextSelection {
    let selection: PDFSelection
    let lineRects: [CGRect]

    init?(in view: PDFView) {
        guard let current = view.currentSelection, current.string?.isEmpty == false,
              let copy = current.copy() as? PDFSelection else { return nil }
        selection = copy
        lineRects = copy.selectionsByLine().flatMap { line in
            line.pages.compactMap { page in
                let bounds = line.bounds(for: page)
                guard !bounds.isEmpty, !bounds.isInfinite, !bounds.isNull else { return nil }
                return view.convert(bounds, from: page)
            }
        }
    }

    func contains(_ point: CGPoint) -> Bool { lineRects.contains { $0.contains(point) } }
}

/// Keeps the display link from retaining the PDF controller during dismissal.
@MainActor
private final class ReaderMotionTarget: NSObject {
    let sample: () -> Void
    init(sample: @escaping () -> Void) { self.sample = sample }
    @objc func tick() { sample() }
}

struct ReaderTapSample {
    let origin: CGPoint
    let startedAt: TimeInterval
    private(set) var eligible: Bool

    init(origin: CGPoint, startedAt: TimeInterval, eligible: Bool) {
        self.origin = origin
        self.startedAt = startedAt
        self.eligible = eligible
    }

    mutating func move(to point: CGPoint) {
        if hypot(point.x - origin.x, point.y - origin.y) > 8 { eligible = false }
    }

    func acceptsEnd(at time: TimeInterval, eligibleNow: Bool) -> Bool {
        eligible && eligibleNow && time >= startedAt && time - startedAt <= 0.35
    }
}

/// UIKit still arbitrates tap counts; this adds stricter travel and lifetime checks.
@MainActor
private final class ReaderPageTapRecognizer: UITapGestureRecognizer {
    var isEligible: () -> Bool = { false }
    var captureSelection: () -> ReaderTextSelection? = { nil }
    private(set) var selectionAtStart: ReaderTextSelection?
    private var sample: ReaderTapSample?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1, sample == nil, let touch = touches.first else {
            state = .failed
            return
        }
        sample = ReaderTapSample(origin: touch.location(in: view), startedAt: touch.timestamp, eligible: isEligible())
        guard sample?.eligible == true else { state = .failed; return }
        selectionAtStart = captureSelection()
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first { sample?.move(to: touch.location(in: view)) }
        guard sample?.eligible == true else { state = .failed; return }
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first else { state = .failed; return }
        sample?.move(to: touch.location(in: view))
        guard sample?.acceptsEnd(at: touch.timestamp, eligibleNow: isEligible()) == true else {
            state = .failed
            return
        }
        super.touchesEnded(touches, with: event)
    }

    override func reset() {
        super.reset()
        sample = nil
        selectionAtStart = nil
    }
}
