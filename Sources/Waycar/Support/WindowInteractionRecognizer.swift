import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Notices the user working in one window: any touch, pointer click, or key
/// press that reaches it.
///
/// This is how Waycar tells which window is being worked in. Since iOS 15
/// `UIWindow.isKeyWindow` and `didBecomeKeyNotification` are per scene, so
/// with several Waycar windows on screen under Stage Manager or Split View
/// every one of them is key and foreground-active, and moving between them
/// changes neither.
///
/// Strictly passive: it fails at the first event of every sequence, never
/// cancels or delays touches, and neither prevents nor is prevented by other
/// recognizers, so every control and the responder chain behave as if it
/// were not there.
final class WindowInteractionRecognizer: UIGestureRecognizer {
    private let onInteraction: @MainActor () -> Void

    init(onInteraction: @escaping @MainActor () -> Void) {
        self.onInteraction = onInteraction
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        reportInteraction()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        reportInteraction()
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    private func reportInteraction() {
        onInteraction()
        state = .failed
    }
}
