import SwiftUI

/// Every term the library holds, biggest first: the chart at the top, then the list.
/// Home's Terms shelf is chips like every other shelf; this is where "More" goes.
///
/// **The chart earns a page of its own.** Terms are the one thing here with a number
/// attached, and a shelf of chips sorted by a count you can't see claims an order it
/// never shows. On a page there's room to show it — and room for the list underneath,
/// which is what you read when you're looking for one by name.
///
/// **Slide, don't tap.** Twenty-odd bars across a phone are four points wide — a target
/// nobody hits on purpose. The finger moves along the row and the line underneath says
/// whichever it's over; lifting leaves that one on screen, so reading the answer doesn't
/// depend on keeping a thumb over what you're reading. That line is the way into the
/// term's own page.
struct TermsPageView: View {
    let terms: [TermCount]

    @State private var focusedIndex = 0

    /// As many as fit at a width a finger can land between. Past that the bars stop being
    /// distinguishable and the chart is texture, not data.
    private static let maxBars = 24
    private static let barSpacing: CGFloat = 3
    private static let chartHeight: CGFloat = 64

    private var bars: [TermCount] { Array(terms.prefix(Self.maxBars)) }
    private var focused: TermCount? {
        bars.indices.contains(focusedIndex) ? bars[focusedIndex] : bars.first
    }
    private var peak: Int { max(bars.first?.mentions ?? 1, 1) }

    var body: some View {
        List {
            Section {
                chart
                    .listRowSeparator(.hidden)
                if let focused {
                    NavigationLink {
                        TermDetailView(term: focused.term)
                    } label: {
                        HStack(spacing: 8) {
                            Text(focused.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text("\(focused.mentions) in \(focused.episodes) episode\(focused.episodes == 1 ? "" : "s")")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                    }
                }
            } footer: {
                Text("The \(bars.count) said most, tallest first. Slide along the bars; lift to leave one named.")
            }

            Section("All \(terms.count)") {
                ForEach(terms) { term in
                    NavigationLink {
                        TermDetailView(term: term.term)
                    } label: {
                        HStack {
                            Text(term.name).font(.subheadline)
                            Spacer()
                            Text("\(term.mentions) · \(term.episodes) ep")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .contentMargins(.bottom, 72, for: .scrollContent)
        .navigationTitle("Terms")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var chart: some View {
        GeometryReader { geometry in
            let pitch = geometry.size.width / CGFloat(max(bars.count, 1))
            HStack(alignment: .bottom, spacing: Self.barSpacing) {
                ForEach(Array(bars.enumerated()), id: \.element.id) { index, term in
                    Capsule()
                        .fill(index == focusedIndex
                              ? AnyShapeStyle(Color.accentColor)
                              : AnyShapeStyle(Color.accentColor.opacity(0.35)))
                        .frame(height: max(4, Self.chartHeight * CGFloat(term.mentions) / CGFloat(peak)))
                }
            }
            .frame(height: Self.chartHeight, alignment: .bottom)
            .contentShape(Rectangle())
            // Zero distance, so a tap picks a bar too — and `onEnded` deliberately does
            // nothing: where the finger left is where the readout stays.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let index = Int(value.location.x / max(pitch, 1))
                        let clamped = min(max(index, 0), bars.count - 1)
                        guard clamped != focusedIndex else { return }
                        focusedIndex = clamped
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
            )
        }
        .frame(height: Self.chartHeight)
    }
}

