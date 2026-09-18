import SwiftUI
import UIKit

extension View {
    /// Puts the keyboard away when you tap anything that isn't a text field — the thing
    /// every iOS app does and SwiftUI does not.
    ///
    /// A tap gesture written in SwiftUI can't do this: put it on the page and it fires
    /// when you tap the *next* field too, dismissing the keyboard you just asked for. This
    /// goes on the window instead, with `cancelsTouchesInView` off so buttons, links and
    /// scrolling behave exactly as before, and it steps aside for touches that land inside
    /// something you can type into.
    func dismissesKeyboardOnBackgroundTap() -> some View {
        background(KeyboardDismissTap())
    }
}

struct KeyboardDismissTap: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        // The window doesn't exist until this is in the hierarchy.
        DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        if context.coordinator.window == nil { context.coordinator.attach(to: view.window) }
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private(set) var window: UIWindow?
        private var recognizer: UITapGestureRecognizer?

        func attach(to window: UIWindow?) {
            guard let window, self.window == nil else { return }
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            // Everything else still sees the touch; this only listens in.
            tap.cancelsTouchesInView = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
            self.window = window
            recognizer = tap
        }

        func detach() {
            if let recognizer { window?.removeGestureRecognizer(recognizer) }
            recognizer = nil
            window = nil
        }

        @objc private func handleTap() {
            dismissKeyboard()
        }

        func dismissKeyboard() {
            window?.endEditing(true)
        }

        /// Ignores taps that land in something you type into — tapping from one field
        /// straight to another must move the cursor, not close the keyboard.
        ///
        /// Both the touched view and whatever is actually under the finger are checked:
        /// SwiftUI wraps its text fields in views of its own, so `touch.view` is often a
        /// container rather than the field, and a hit test is what finds the field.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            let hit = window?.hitTest(touch.location(in: window), with: nil)
            return !isTextInput(touch.view) && !isTextInput(hit)
        }

        private func isTextInput(_ view: UIView?) -> Bool {
            var candidate = view
            while let current = candidate {
                if current is UITextInput { return true }
                candidate = current.superview
            }
            return false
        }

        /// Never competes with anything: scrolling, buttons and the transcript's own taps
        /// all keep working while this watches.
        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }
}
