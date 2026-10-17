import UIKit
import PDFKit

/// Keeps live PDFKit canvases inside the system's single-sided book animation.
@MainActor
final class BookPDFController: UIViewController, UIPageViewControllerDataSource,
    UIPageViewControllerDelegate, UIGestureRecognizerDelegate, ReaderNavigating {
    let session: ReaderSession
    let pager = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal,
                                    options: [.spineLocation: UIPageViewController.SpineLocation.min.rawValue])
    var reduceMotion: Bool
    private var canvases: [Int: PDFHostController] = [:]
    private(set) var currentCanvas: PDFHostController?
    private var transitioning = false
    private var turnOrigin: Int?
    private var queuedNavigation: (Int, () -> Void)?
    private var motionSwipes: [UISwipeGestureRecognizer] = []
    private var backdropTap: UITapGestureRecognizer?
    private let paperBackdrop = UIView()
    private var closed = false

    init(session: ReaderSession, reduceMotion: Bool? = nil) {
        self.session = session
        self.reduceMotion = reduceMotion ?? UIAccessibility.isReduceMotionEnabled
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        paperBackdrop.backgroundColor = .white
        paperBackdrop.isUserInteractionEnabled = false
        paperBackdrop.isAccessibilityElement = false
        view.addSubview(paperBackdrop)
        addChild(pager)
        pager.view.frame = view.bounds
        view.addSubview(pager.view)
        pager.didMove(toParent: self)
        pager.isDoubleSided = false
        pager.delegate = self
        pager.dataSource = self
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(reducedMotionSwipe(_:)))
            swipe.direction = direction
            swipe.delegate = self
            pager.view.addGestureRecognizer(swipe)
            motionSwipes.append(swipe)
        }
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapBackdrop(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        view.addGestureRecognizer(tap)
        backdropTap = tap
        session.navigation = self
        if let initial = canvas(at: session.currentPage) {
            pager.setViewControllers([initial], direction: .forward, animated: false)
            activate(initial)
        }
        update()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPage()
        currentCanvas?.view.layoutIfNeeded()
        updateGestures()
    }

    /// Curl only the fitted PDF crop box; the surrounding reader stays still.
    static func pageFrame(for page: PDFPage, in bounds: CGRect) -> CGRect {
        let crop = page.bounds(for: .cropBox)
        let sideways = abs(page.rotation % 180) == 90
        let size = sideways ? CGSize(width: crop.height, height: crop.width) : crop.size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    private func layoutPage() {
        guard !transitioning, let index = currentCanvas?.fixedPage,
              let page = session.pdf?.page(at: index) else { return }
        let frame = Self.pageFrame(for: page, in: view.bounds)
        if pager.view.frame != frame {
            pager.view.frame = frame
            pager.view.setNeedsLayout()
            pager.view.layoutIfNeeded()
        }
        paperBackdrop.frame = frame
    }

    func update() {
        guard isViewLoaded, !closed else { return }
        for canvas in canvases.values { canvas.update() }
        updateCurlLighting()
        updateGestures()
    }

    private func updateCurlLighting() {
        // UIKit owns the curl's baked-in shading. Compositing the moving paper
        // over white softens its black shadows without accessing private views.
        // The resting PDF always keeps its full contrast and original colors.
        pager.view.alpha = transitioning && !reduceMotion ? 0.82 : 1
    }

    func canvas(at index: Int) -> PDFHostController? {
        guard let pdf = session.pdf, (0..<pdf.pageCount).contains(index) else { return nil }
        if let existing = canvases[index], existing.fixedPage == index { return existing }
        let canvas = PDFHostController(session: session, fixedPage: index)
        canvas.onInteractionChanged = { [weak self] in self?.updateGestures() }
        canvas.onPageNavigation = { [weak self, weak canvas] page in
            guard let self, let canvas, self.currentCanvas === canvas, !self.transitioning else { return }
            // PDFKit can follow an internal link without going through ReaderSession.go.
            self.canvases = self.canvases.filter { $0.value !== canvas }
            if let stale = self.canvases.removeValue(forKey: page) { stale.tearDown() }
            self.canvases[page] = canvas
            self.session.commitPage(page)
            self.layoutPage()
            self.trimCanvases()
            self.updateGestures()
        }
        canvases[index] = canvas
        return canvas
    }

    private func activate(_ canvas: PDFHostController) {
        if let previous = currentCanvas, previous !== canvas { previous.deactivate() }
        currentCanvas = canvas
        canvas.activate()
        layoutPage()
        session.navigation = self
        canvas.pdfView.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Next page", target: self, selector: #selector(accessibleNext)),
            UIAccessibilityCustomAction(name: "Previous page", target: self, selector: #selector(accessiblePrevious))
        ]
        canvas.pdfView.onAccessibilityPageTurn = { [weak self] forward in self?.turnPage(forward: forward) == true }
    }

    private func trimCanvases() {
        guard !transitioning, let index = currentCanvas?.fixedPage else { return }
        let discarded = canvases.filter { abs($0.key - index) > 1 }
        for (key, canvas) in discarded { canvases.removeValue(forKey: key); canvas.tearDown() }
    }

    private var canTurn: Bool {
        session.ready && !closed && !session.isScrubbing && !session.drawingStroke
            && !session.selectionAvailable && currentCanvas?.isZoomed == false
    }

    private func updateGestures() {
        guard isViewLoaded, !closed else { return }
        let drawing = session.tool == .pen || session.tool == .eraser
        if !transitioning {
            if reduceMotion { pager.dataSource = nil }
            else if pager.dataSource !== self { pager.dataSource = self }
        }
        for gesture in pager.gestureRecognizers {
            if let pan = gesture as? UIPanGestureRecognizer {
                pan.minimumNumberOfTouches = drawing ? 2 : 1
                pan.maximumNumberOfTouches = drawing ? 2 : 1
                // Do not disable a gesture while its completed/canceled turn is settling.
                if !transitioning { pan.isEnabled = !reduceMotion && canTurn }
            } else if gesture is UITapGestureRecognizer {
                gesture.isEnabled = false
            }
        }
        for swipe in motionSwipes {
            swipe.numberOfTouchesRequired = drawing ? 2 : 1
            swipe.isEnabled = reduceMotion && canTurn && !transitioning
        }
    }

    func navigate(to index: Int, completion: @escaping () -> Void) {
        guard !closed else { return }
        loadViewIfNeeded()
        if transitioning { queuedNavigation = (index, completion); return }
        guard let target = canvas(at: index) else { return }
        session.clearTextSelection()
        let forward = index >= (currentCanvas?.fixedPage ?? index)
        pager.setViewControllers([target], direction: forward ? .forward : .reverse, animated: false)
        activate(target)
        target.view.layoutIfNeeded()
        completion()
        trimCanvases()
        updateGestures()
    }

    @discardableResult
    func turnPage(forward: Bool) -> Bool {
        guard canTurn, !transitioning, let index = currentCanvas?.fixedPage,
              let target = canvas(at: index + (forward ? 1 : -1)) else { return false }
        transitioning = true
        turnOrigin = index
        updateCurlLighting()
        session.setReaderInteraction(active: true)
        pager.setViewControllers([target], direction: forward ? .forward : .reverse, animated: !reduceMotion) { [weak self] finished in
            guard let self, !self.closed else { return }
            self.finishTransition(to: target, completed: finished)
        }
        return true
    }

    private func finishTransition(to target: PDFHostController?, completed: Bool) {
        if completed, let target, let index = target.fixedPage,
           let origin = turnOrigin, abs(index - origin) == 1 {
            activate(target)
            target.view.layoutIfNeeded()
            session.completedPageTurn(to: index)
            if UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .pageScrolled, argument: "Page \(index + 1) of \(session.record.pageCount)")
            }
        } else if completed, let currentCanvas {
            pager.setViewControllers([currentCanvas], direction: .forward, animated: false)
        }
        transitioning = false
        turnOrigin = nil
        updateCurlLighting()
        session.setReaderInteraction(active: false)
        layoutPage()
        trimCanvases()
        updateGestures()
        if let (index, completion) = queuedNavigation {
            queuedNavigation = nil
            navigate(to: index, completion: completion)
        }
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let index = (viewController as? PDFHostController)?.fixedPage else { return nil }
        return adjacentCanvas(at: index - 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let index = (viewController as? PDFHostController)?.fixedPage else { return nil }
        return adjacentCanvas(at: index + 1)
    }

    private func adjacentCanvas(at index: Int) -> PDFHostController? {
        guard let origin = turnOrigin ?? currentCanvas?.fixedPage, abs(index - origin) <= 1 else { return nil }
        // UIKit may ask for a neighbor of a preloaded page during a long swipe.
        // Never supply a second forward/backward page for the same curl.
        return canvas(at: index)
    }

    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        turnOrigin = currentCanvas?.fixedPage
        transitioning = true
        updateCurlLighting()
        session.setReaderInteraction(active: true)
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        finishTransition(to: pager.viewControllers?.first as? PDFHostController, completed: completed)
    }

    func pageViewController(_ pageViewController: UIPageViewController, spineLocationFor orientation: UIInterfaceOrientation) -> UIPageViewController.SpineLocation {
        pager.isDoubleSided = false
        return .min
    }

    @objc private func accessibleNext() -> Bool { turnPage(forward: true) }
    @objc private func accessiblePrevious() -> Bool { turnPage(forward: false) }
    @objc private func reducedMotionSwipe(_ gesture: UISwipeGestureRecognizer) { turnPage(forward: gesture.direction == .left) }
    @objc private func tapBackdrop(_ gesture: UITapGestureRecognizer) {
        if gesture.state == .ended { session.clearTextSelection() }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === backdropTap { return !transitioning && session.acceptsPageTap() && !session.drawingStroke }
        return canTurn && !transitioning
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === backdropTap { return !pager.view.frame.contains(touch.location(in: view)) }
        return true
    }

    func tearDown() {
        closed = true
        pager.view.alpha = 1
        pager.dataSource = nil
        pager.delegate = nil
        queuedNavigation = nil
        backdropTap?.isEnabled = false
        for gesture in motionSwipes { gesture.isEnabled = false }
        for canvas in canvases.values { canvas.tearDown() }
        canvases.removeAll()
        currentCanvas = nil
        session.setReaderInteraction(active: false)
        if session.navigation === self { session.navigation = nil }
    }
}
