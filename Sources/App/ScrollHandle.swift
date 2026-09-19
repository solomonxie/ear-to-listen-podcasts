import SwiftUI

/// A grab handle for pages that run to thousands of rows.
///
/// iOS's own scroll indicator is a two-point hairline that fades out, can't be grabbed
/// without a pixel-perfect press, and on a 2,500-file folder represents the whole list in
/// a few points of travel. This is the opposite: a thumb-sized target on a visible track,
/// where a drag of the whole track covers the whole list.
///
/// ```
///                        │
///                       ╭─╮
///                       │≡│  ← sits in the middle of the screen,
///                       ╰─╯     where a thumb already is
///                        │      track = 40% of the screen, centred
/// ```
///
/// The track is deliberately short. Mapping a whole screen of travel onto a whole list
/// makes every row a fraction of a point — a touch that moves 2pt skips forty files. Over
/// 40% the same list is still reachable in one drag, and a small correction stays small.
///
/// It shows while the list is moving and fades a couple of seconds after it stops: a
/// permanent bar over the content is furniture, and there's nothing to grab when nobody
/// is scrolling.
struct ScrollHandle: View {
    /// Row identities, in the order they appear. The handle maps its position onto this.
    let ids: [AnyHashable]
    let proxy: ScrollViewProxy
    /// Shown in the bubble while dragging — usually what's under the handle right now.
    var label: (Int) -> String = { "\($0 + 1)" }
    @ObservedObject var activity: ScrollActivity

    @State private var fraction: Double = 0
    @State private var isDragging = false
    @GestureState private var dragStart: Double?

    /// Fraction of the screen the track covers.
    private static let trackShare: Double = 0.4
    private static let knobWidth: CGFloat = 22
    private static let knobHeight: CGFloat = 46
    /// The knob is narrower than a finger, so the column around it takes the touch.
    private static let hitWidth: CGFloat = 44

    private var isShown: Bool { ids.count > 20 && (activity.isActive || isDragging) }

    var body: some View {
        GeometryReader { geometry in
            let trackHeight = geometry.size.height * Self.trackShare
            let travel = trackHeight - Self.knobHeight

            ZStack(alignment: .top) {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .frame(width: 4)
                    .frame(height: trackHeight)
                    .opacity(isDragging ? 0.9 : 0.4)

                knobView
                    .offset(y: travel * fraction)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .updating($dragStart) { _, start, _ in
                                if start == nil { start = fraction }
                            }
                            .onChanged { value in
                                isDragging = true
                                activity.poke()
                                guard travel > 0 else { return }
                                let from = dragStart ?? fraction
                                fraction = min(max(from + value.translation.height / travel, 0), 1)
                                scroll()
                            }
                            .onEnded { _ in
                                isDragging = false
                                activity.poke()
                            }
                    )
            }
            .frame(height: trackHeight)
            // Centred vertically: the middle of the screen is where a thumb rests, and it
            // leaves equal room to drag either way.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .frame(width: Self.hitWidth)
        .opacity(isShown ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: isShown)
        // Nothing to hit while it's faded out, so a hidden handle can't eat a row tap.
        .allowsHitTesting(isShown)
    }

    private var knobView: some View {
        ZStack {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().stroke(Color.accentColor.opacity(isDragging ? 0.8 : 0.3), lineWidth: 1))
                .shadow(radius: isDragging ? 5 : 1.5)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
        .frame(width: Self.knobWidth, height: Self.knobHeight)
        .frame(width: Self.hitWidth)
        .contentShape(Rectangle())
        .scaleEffect(isDragging ? 1.1 : 1)
        .animation(.easeOut(duration: 0.12), value: isDragging)
        .overlay(alignment: .trailing) {
            if isDragging, let index = currentIndex {
                // Beside the thumb, not under it — a bubble where the finger is, is a
                // bubble you can't read.
                Text(label(index))
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .fixedSize()
                    .offset(x: -Self.hitWidth)
                    .transition(.opacity)
            }
        }
    }

    private var currentIndex: Int? {
        guard !ids.isEmpty else { return nil }
        return min(Int(fraction * Double(ids.count - 1) + 0.5), ids.count - 1)
    }

    /// No animation on purpose: this is a scrub, and animating every step of a drag makes
    /// the list lag behind the thumb and then catch up after it stops.
    private func scroll() {
        guard let index = currentIndex else { return }
        proxy.scrollTo(ids[index], anchor: .top)
    }
}

/// "Is this list moving right now?", kept out of the view tree.
///
/// A scroll reports a position several dozen times a second. Publishing each one would
/// redraw the handle — and the page under it — for every frame of a flick, so `poke()`
/// only pushes a deadline forward and publishes twice per episode: once on, once off.
@MainActor
final class ScrollActivity: ObservableObject {
    @Published private(set) var isActive = false

    private var deadline: Date = .distantPast
    private static let linger: TimeInterval = 2

    func poke() {
        deadline = Date().addingTimeInterval(Self.linger)
        guard !isActive else { return }
        isActive = true
        Task { @MainActor in
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            isActive = false
        }
    }
}

extension View {
    /// Puts a `ScrollHandle` over the trailing edge of this scroll view and wakes it
    /// whenever the view scrolls.
    func scrollHandle(
        ids: [AnyHashable],
        proxy: ScrollViewProxy,
        label: @escaping (Int) -> String = { "\($0 + 1)" }
    ) -> some View {
        modifier(ScrollHandleModifier(ids: ids, proxy: proxy, label: label))
    }
}

private struct ScrollHandleModifier: ViewModifier {
    let ids: [AnyHashable]
    let proxy: ScrollViewProxy
    let label: (Int) -> String

    @StateObject private var activity = ScrollActivity()

    func body(content: Content) -> some View {
        scrollWatching(content)
            .overlay(alignment: .trailing) {
                ScrollHandle(ids: ids, proxy: proxy, label: label, activity: activity)
                    .padding(.trailing, 2)
            }
    }

    /// Momentum counts as scrolling, so the offset itself is the signal where the OS
    /// reports it; older systems get the drag that started it.
    @ViewBuilder
    private func scrollWatching(_ content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, _ in
                activity.poke()
            }
        } else {
            content.simultaneousGesture(
                DragGesture(minimumDistance: 6).onChanged { _ in activity.poke() }
            )
        }
    }
}
