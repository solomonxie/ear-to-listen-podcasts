import SwiftUI

/// Which fields an AI pass just filled in, and what each held before it did.
///
/// Suggestions land **in the fields themselves**, immediately — no review sheet, no Apply.
/// The page you were already looking at is the best place to judge a suggestion, and a
/// sheet that shows you the same four fields again in a different layout is a step that
/// only ever said "yes". Rejecting is the affordance instead of approving: one tap puts a
/// field back exactly as it was, and doing nothing keeps it.
///
/// Safe because nothing here is destructive-in-the-scary-sense — every field is free text
/// on a page whose whole job is editing, and the previous value is held right here until
/// the page reloads.
struct ProfileSuggestionState {
    private(set) var suggested: Set<String> = []
    private var prior: [String: String] = [:]

    var isEmpty: Bool { suggested.isEmpty }

    func wasSuggested(_ id: String) -> Bool { suggested.contains(id) }

    /// Marks a field as just-suggested, remembering what it held so it can be put back.
    mutating func record(_ id: String, previous: String) {
        suggested.insert(id)
        // Keep the *original*, not the last suggestion: running the pass twice must still
        // reject back to what the listener had, never to the first guess.
        if prior[id] == nil { prior[id] = previous }
    }

    /// The value to restore, and forgets the field.
    mutating func reject(_ id: String) -> String? {
        suggested.remove(id)
        return prior.removeValue(forKey: id)
    }

    mutating func reset() {
        suggested.removeAll()
        prior.removeAll()
    }
}

/// The one affordance a suggested field needs: it says where the text came from, and
/// offers the only action worth offering — putting it back.
struct SuggestedFieldNote: View {
    let onReject: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Label("Suggested", systemImage: "sparkles")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("Reject", action: onReject)
                .font(.caption2.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            Spacer()
        }
    }
}

/// The button itself, in the section header where the fields it fills are — not three
/// levels down a `⋯` menu.
struct SuggestWithAiButton: View {
    let isRunning: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isRunning {
                ProgressView().controlSize(.mini)
            } else {
                Label("Suggest", systemImage: "sparkles").font(.caption.weight(.semibold))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .disabled(isRunning)
    }
}
