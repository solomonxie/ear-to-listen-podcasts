import SwiftUI
import UIKit

extension View {
    /// Leave a page that isn't in a navigation stack the way a pushed one leaves: a swipe
    /// in from the left edge, the page following the finger.
    ///
    /// `canBegin` is asked once per stroke, as it starts, so a page can stand the gesture
    /// down while something else on it owns horizontal strokes.
    func swipeToGoBack(
        canBegin: @escaping () -> Bool = { true }, perform: @escaping () -> Void
    ) -> some View {
        modifier(SwipeToGoBack(canBegin: canBegin, perform: perform))
    }
}

/// Why a UIKit recogniser rather than a `DragGesture`:
///
/// **It has to win the stroke, not share it.** The page under this is a scroll view full
/// of gestures of its own. A `simultaneousGesture` ran *beside* all of them, so one
/// stroke was answered twice — the playhead moved and the page slid away behind it — and
/// each new competitor needed another guard bolted onto the drag. A screen-edge pan is
/// the recogniser the rest of iOS uses for exactly this, and the arbitration that makes
/// the system's own back swipe behave makes this one behave.
///
/// **It must not redraw the page.** Travel held in the page's own `@State` rebuilt a body
/// carrying a whole episode — artwork, transport, details, a thousand transcript lines —
/// on every frame of the swipe, and an implicit spring on top meant the page then eased
/// towards where the finger had been a third of a second ago. That is the whole of the
/// lag. The travel lives here now: nothing rebuilds, and the offset tracks the finger.
private struct SwipeToGoBack: ViewModifier {
    let canBegin: () -> Bool
    let perform: () -> Void

    @State private var travel: CGFloat = 0

    /// About a thumb's width of deliberate movement — or a flick that was plainly going
    /// that way, which is how the system's own back swipe feels and why a slow short drag
    /// and a fast short one shouldn't end the same.
    private static let distanceToGoBack: CGFloat = 80
    private static let velocityToGoBack: CGFloat = 500

    func body(content: Content) -> some View {
        content
            .offset(x: travel)
            .background {
                EdgePan(
                    canBegin: canBegin,
                    onChange: { travel = max(0, $0) },
                    onEnd: { translation, velocity in
                        guard translation > Self.distanceToGoBack || velocity > Self.velocityToGoBack else {
                            // Only the way back is animated. Following the finger is not an
                            // animation — it is the finger.
                            withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.9)) {
                                travel = 0
                            }
                            return
                        }
                        // Left where the finger left it: the page is about to be taken off
                        // by its own move transition, which carries on from here.
                        perform()
                    }
                )
                .allowsHitTesting(false)
            }
    }
}

private struct EdgePan: UIViewRepresentable {
    let canBegin: () -> Bool
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = WindowAttachingView()
        view.isUserInteractionEnabled = false
        view.recognizer = context.coordinator.recognizer
        return view
    }

    /// The closures come from the page's body, so they're replaced on every pass — which
    /// is what keeps `canBegin` answering with the state of the page as it is now.
    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.owner = self
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var owner: EdgePan

        lazy var recognizer: UIScreenEdgePanGestureRecognizer = {
            let recognizer = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handle))
            recognizer.edges = .left
            recognizer.delegate = self
            return recognizer
        }()

        init(_ owner: EdgePan) { self.owner = owner }

        @objc func handle(_ recognizer: UIScreenEdgePanGestureRecognizer) {
            let translation = recognizer.translation(in: recognizer.view).x
            switch recognizer.state {
            case .changed:
                owner.onChange(translation)
            case .ended:
                owner.onEnd(translation, recognizer.velocity(in: recognizer.view).x)
            case .cancelled, .failed:
                owner.onEnd(0, 0)
            default:
                break
            }
        }

        /// Declining here fails the recogniser for this stroke rather than swallowing it,
        /// so whatever else wanted it — a pushed page's own back swipe — still gets it.
        ///
        /// Never while something is presented over the page. The recogniser lives on the
        /// window, which is the only place it can see the touches it needs; a sheet over
        /// this page is in that same window, and swiping inside one would otherwise slide
        /// the page out from underneath it.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            let window = recognizer.view as? UIWindow
            guard window?.rootViewController?.presentedViewController == nil else { return false }
            return owner.canBegin()
        }
    }
}

/// The recogniser goes on the window, not on this view. This one sits behind the page as
/// a background, so every touch lands on the page in front of it and none would ever
/// reach a recogniser attached here — a recogniser only sees touches on its own view and
/// its descendants. The window is the ancestor of all of them, which is where the
/// system's own edge gestures live too. It leaves with the view, so it is only ever
/// armed while the page that asked for it is on screen.
private final class WindowAttachingView: UIView {
    var recognizer: UIGestureRecognizer?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let recognizer else { return }
        recognizer.view?.removeGestureRecognizer(recognizer)
        window?.addGestureRecognizer(recognizer)
    }
}
