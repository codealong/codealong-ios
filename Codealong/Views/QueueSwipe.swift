import SwiftUI
import UIKit

/// A sideways swipe across a session's conversation, for going along what waits on you. It's a
/// UIKit pan rather than SwiftUI's drag, so it can leave alone the swipes something else owns: one
/// on a code block or table that scrolls sideways, and one from the screen's left edge, which is
/// iOS's own way back. It goes along with the conversation's own scrolling, and begins only on a
/// swipe more sideways than up or down.
struct QueueSwipe: UIGestureRecognizerRepresentable {
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

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        // In the window's space: the conversation moves with the swipe, and its own space with it.
        let distance = pan.translation(in: nil).x
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

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: nil)
            return abs(v.x) > abs(v.y) * 1.5
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
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
