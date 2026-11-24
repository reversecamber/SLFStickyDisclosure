import SwiftUI
import UIKit

/// Installs the drag long press on the UIKit scroll view behind the list.
///
/// SwiftUI's own gestures can't express what dragging needs: a button inside a row claims its touch
/// as soon as it lands, so a long press around it never starts. A UIKit recognizer can make the
/// content's gestures wait for it instead. It also keeps tracking while the dragged row scrolls away,
/// and it drives auto-scroll near the edges.
struct SectionedListDragDriver: UIViewRepresentable {
    /// Whether a header or row that can be dragged is at this point, in the list's coordinates.
    let canLift: (CGPoint) -> Bool
    let began: (CGPoint) -> Void
    let moved: (CGPoint) -> Void
    /// Called with `true` for a drop and `false` for a cancelled drag.
    let ended: (Bool) -> Void

    func makeUIView(context: Context) -> SectionedListDragDriverView {
        SectionedListDragDriverView()
    }

    func updateUIView(_ view: SectionedListDragDriverView, context: Context) {
        view.canLift = canLift
        view.began = began
        view.moved = moved
        view.ended = ended
    }

    static func dismantleUIView(_ view: SectionedListDragDriverView, coordinator: ()) {
        view.uninstall()
    }
}

/// Sized to the list, so locations in this view are locations in the list.
final class SectionedListDragDriverView: UIView, UIGestureRecognizerDelegate {
    var canLift: (CGPoint) -> Bool = { _ in false }
    var began: (CGPoint) -> Void = { _ in }
    var moved: (CGPoint) -> Void = { _ in }
    var ended: (Bool) -> Void = { _ in }

    private weak var scrollView: UIScrollView?
    private var recognizer: UILongPressGestureRecognizer?
    private var displayLink: CADisplayLink?
    private var lastPoint: CGPoint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { uninstall() } else { install() }
    }

    private func install() {
        guard recognizer == nil else { return }
        var candidate = superview
        while let view = candidate, !(view is UIScrollView) {
            candidate = view.superview
        }
        guard let scrollView = candidate as? UIScrollView else { return }
        let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
        recognizer.minimumPressDuration = 0.35
        recognizer.delegate = self
        scrollView.addGestureRecognizer(recognizer)
        self.scrollView = scrollView
        self.recognizer = recognizer
    }

    func uninstall() {
        stopDisplayLink()
        if let recognizer {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }
        scrollView?.panGestureRecognizer.isEnabled = true
        recognizer = nil
        scrollView = nil
    }

    // MARK: Gesture precedence

    /// Takes part only in touches that start on a header or row that can be dragged.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        canLift(touch.location(in: self))
    }

    /// For those touches, every other recognizer waits for the long press to fail: a quick tap or a
    /// move still reaches buttons and swipes, and holding still lifts the item instead. SwiftUI
    /// attaches its recognizers above the scroll view, so they can't be singled out by view. The
    /// scroll view's own pan and pinch don't wait, so scrolling stays immediate.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard let scrollView else { return false }
        return otherGestureRecognizer !== scrollView.panGestureRecognizer
            && otherGestureRecognizer !== scrollView.pinchGestureRecognizer
    }

    // UIView declares this too; as this view is the recognizer's delegate, UIKit asks it here.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        canLift(gestureRecognizer.location(in: self))
    }

    // MARK: Tracking

    @objc private func handle(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            let point = recognizer.location(in: self)
            lastPoint = point
            // The list can't scroll under the finger; auto-scroll still moves it.
            scrollView?.panGestureRecognizer.isEnabled = false
            began(point)
            startDisplayLink()
        case .changed:
            reportFinger()
        case .ended:
            finish(dropped: true)
        case .cancelled, .failed:
            finish(dropped: false)
        default:
            break
        }
    }

    private func finish(dropped: Bool) {
        stopDisplayLink()
        scrollView?.panGestureRecognizer.isEnabled = true
        lastPoint = nil
        ended(dropped)
    }

    /// Reports the finger in list coordinates; it changes when the finger moves or the content scrolls.
    private func reportFinger() {
        guard let recognizer else { return }
        let point = recognizer.location(in: self)
        guard point != lastPoint else { return }
        lastPoint = point
        moved(point)
    }

    // MARK: Auto-scroll

    private func startDisplayLink() {
        stopDisplayLink()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// Scrolls when the finger rests near the top or bottom edge, faster the closer it gets.
    @objc private func tick(_ link: CADisplayLink) {
        guard let scrollView, let recognizer else { return }
        let finger = recognizer.location(in: scrollView)
        let inset = scrollView.adjustedContentInset
        let visibleTop = scrollView.contentOffset.y + inset.top
        let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height - inset.bottom
        let edge: CGFloat = 70
        let maximumStep: CGFloat = 18
        var step: CGFloat = 0
        if finger.y < visibleTop + edge {
            step = -min(maximumStep, (visibleTop + edge - finger.y) / edge * maximumStep + 2)
        } else if finger.y > visibleBottom - edge {
            step = min(maximumStep, (finger.y - (visibleBottom - edge)) / edge * maximumStep + 2)
        }
        if step != 0 {
            let minimumOffset = -inset.top
            let maximumOffset = max(minimumOffset, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
            let offset = min(max(scrollView.contentOffset.y + step, minimumOffset), maximumOffset)
            if offset != scrollView.contentOffset.y {
                scrollView.contentOffset.y = offset
            }
        }
        reportFinger()
    }
}
