import SwiftUI

extension View {
    /// A bar docked over the bottom of every page in a navigation stack, with each page's
    /// scrolling content given room to scroll clear of it.
    ///
    /// Not `safeAreaInset` on the stack: that left pages' last rows — Home's Settings
    /// button — sitting under the bar. The bar's measured height goes to every scroll view
    /// inside as a content margin instead, which reaches pushed pages too.
    func dockedBottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        modifier(DockedBottomBar(bar: bar()))
    }
}

private struct DockedBottomBar<Bar: View>: ViewModifier {
    let bar: Bar
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .contentMargins(.bottom, height, for: .scrollContent)
            .overlay(alignment: .bottom) {
                // Wrapped, so a bar that draws nothing measures zero and the margin goes.
                VStack(spacing: 0) { bar }
                    .background {
                        GeometryReader { geo in
                            Color.clear.onChange(of: geo.size.height, initial: true) { height = $1 }
                        }
                    }
            }
    }
}
