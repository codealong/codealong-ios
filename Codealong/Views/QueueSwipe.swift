import SwiftUI
import UIKit

/// A sideways swipe across a session's conversation, for going along what waits on you. It's a
/// UIKit pan rather than SwiftUI's drag, so it can leave alone the swipes something else owns: one
/// on a code block or table that scrolls sideways, and one from the screen's left edge, which is
/// iOS's own way back. It goes along with the conversation's own scrolling, and begins only on a
/// swipe more sideways than up or down. iOS's swipe back to the list from anywhere on the screen
/// waits for it: to the right it's this swipe's while there's a session to go back to, and iOS's
/// once there isn't.
struct QueueSwipe: UIGestureRecognizerRepresentable {
    /// There's a session to go back to.
    var back: Bool
    /// How far it's gone, in points: negative to the left.
    var moved: (CGFloat) -> Void
    /// It ended, this far and this fast (points a second); both zero when it was cancelled.
    var ended: (_ distance: CGFloat, _ speed: CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
        context.coordinator.back = back
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        // In the window's space: the conversation moves with the swipe, and its own space with it.
        // From where it began, as a scroll view goes: by the time it's sure it's sideways the
        // finger has gone a little way, and the screen doesn't jump to catch up.
        let gone = pan.translation(in: nil).x
        if pan.state == .began { context.coordinator.start = gone }
        let distance = gone - context.coordinator.start
        switch pan.state {
        case .changed: moved(distance)
        case .ended: ended(distance, pan.velocity(in: nil).x)
        case .cancelled, .failed: ended(0, 0)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Swipes that start this close to the screen's left edge are iOS's way back.
        private let edge: CGFloat = 28
        /// How far the finger had gone when the swipe began.
        var start: CGFloat = 0
        var back = false

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: nil)
            // To the right with no session to go back to, it's iOS's swipe back to the list.
            if v.x > 0 && !back { return false }
            return abs(v.x) > abs(v.y) * 1.5
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            !backToList(other, from: recognizer)
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            backToList(other, from: recognizer)
        }

        /// `other` is iOS's swipe back to the list from anywhere on the screen (both going at once,
        /// the screen slid toward the list and to the session before).
        private func backToList(_ other: UIGestureRecognizer, from recognizer: UIGestureRecognizer) -> Bool {
            var responder: UIResponder? = recognizer.view
            while let r = responder {
                if let nav = r as? UINavigationController { return other === nav.interactiveContentPopGestureRecognizer }
                responder = r.next
            }
            return false
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if let window = touch.window, touch.location(in: window).x < edge { return false }
            var view = touch.view
            while let v = view {
                if let scroll = v as? UIScrollView, scroll.contentSize.width > scroll.bounds.width + 1 { return false }
                view = v.superview
            }
            return true
        }
    }
}
