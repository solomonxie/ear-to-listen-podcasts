import SwiftUI

/// What the saved moments add up to, written by `BookmarkInsights`.
///
/// **Opens on the last result, not a new call.** Asking costs money and a few seconds,
/// and the marks rarely change between two looks. The first open with nothing saved
/// asks straight away — an empty sheet with a button in it is one tap too many — and
/// after that it's "Regenerate", with a line saying how many marks have been added since.
struct BookmarkInsightsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var saved = BookmarkInsights.saved
    @State private var currentCount = 0
    @State private var isRunning = false
    @State private var errorMessage: String?

    private let insights = BookmarkInsights()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let saved {
                        Text(Self.rendered(saved.text))
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(footnote(for: saved))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if isRunning {
                        ProgressView("Reading your bookmarks…")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(.orange)
                    }
                }
                .padding()
            }
            .navigationTitle("Bookmark Insights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if isRunning {
                        ProgressView()
                    } else {
                        Button("Regenerate", systemImage: "arrow.clockwise") { Task { await generate() } }
                            .disabled(currentCount == 0)
                    }
                }
            }
        }
        .task {
            let insights = insights
            currentCount = await Task.detached(priority: .utility) { insights.markCount() }.value
            if saved == nil { await generate() }
        }
    }

    private func generate() async {
        isRunning = true
        errorMessage = nil
        defer { isRunning = false }
        do {
            saved = try await insights.run()
            currentCount = saved?.markCount ?? currentCount
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func footnote(for saved: BookmarkInsights.Saved) -> String {
        let when = saved.generatedAt.formatted(.relative(presentation: .named))
        let added = currentCount - saved.markCount
        let base = String(localized: "From \(saved.markCount) marks, \(when).")
        return added > 0 ? base + " " + String(localized: "\(added) added since — Regenerate to include them.") : base
    }

    /// Bold headings and "-" bullets, which is all the prompt asks for. Inline markdown
    /// keeps the line breaks; full markdown parsing would fold the bullets into one run.
    static func rendered(_ text: String) -> AttributedString {
        let cleaned = text
            .replacingOccurrences(of: #"(?m)^#{1,6}\s*(.+)$"#, with: "**$1**", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^(\s*)[-*]\s+"#, with: "$1• ", options: .regularExpression)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: cleaned, options: options)) ?? AttributedString(text)
    }
}
