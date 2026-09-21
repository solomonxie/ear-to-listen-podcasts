import SwiftUI

/// Asking an AI key for a picture: the description it works from, what came back, and the
/// decision to keep it or not.
///
/// The description arrives filled in from what the library already knows — the episode's
/// title, its collection, who is speaking. The listener already told the app all of that
/// once, and asking them to type it again as a prompt would be the app's failing, not
/// theirs. It stays editable because they know things the tags don't.
///
/// **Nothing is saved until the picture is on screen and accepted.** A generated image is
/// a guess that costs money, and a photo a model *named* might be the wrong person
/// entirely — so both are shown, with where they came from, before anything is kept.
struct AiArtworkSheet: View {
    let source: ArtworkSource
    let subject: ArtworkSubject
    /// Handed the image bytes once the listener keeps them.
    let onUse: (Data) -> Void

    @State private var prompt: String
    @State private var isWorking = false
    @State private var found: ArtworkSuggester.Found?
    @State private var preview: UIImage?
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(source: ArtworkSource, subject: ArtworkSubject, onUse: @escaping (Data) -> Void) {
        self.source = source
        self.subject = subject
        self.onUse = onUse
        _prompt = State(initialValue: source == .publicPhoto ? subject.describedForPrompt : subject.defaultPrompt)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(source == .publicPhoto ? "WHO OR WHAT TO LOOK FOR" : "WHAT TO DRAW")
                            .sectionHeading()
                        TextField("Describe it", text: $prompt, axis: .vertical)
                            .font(.body)
                            .lineLimit(2...8)
                            .padding(10)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }

                    Text(source.detail).sectionHint()

                    Button(action: run) {
                        HStack(spacing: 8) {
                            Label(found == nil ? "Ask" : "Try again", systemImage: "sparkles")
                            if isWorking { ProgressView().controlSize(.small) }
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Color.accentColor.opacity(0.22), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isWorking || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(.orange)
                    }

                    if let preview {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(uiImage: preview)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            // Where it came from, before the decision — a face with no
                            // source is the one thing here nobody should keep on trust.
                            if let sourceURL = found?.sourceURL {
                                Link(destination: sourceURL) {
                                    Label(sourceURL.host ?? "Source", systemImage: "safari").font(.caption)
                                }
                            }
                            if let credit = found?.credit {
                                Text(credit).font(.caption2).foregroundStyle(.secondary)
                            }
                            Button("Use this picture") { use() }
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                }
                .padding()
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle(source.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.large])
    }

    private func run() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                let result = try await ArtworkSuggester().picture(for: source, prompt: prompt)
                found = result
                preview = UIImage(data: result.data)
                if preview == nil { errorMessage = ArtworkSuggester.UnusableImageError().localizedDescription }
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func use() {
        guard let found else { return }
        onUse(found.data)
        dismiss()
    }
}

/// The one row that answers "where does this picture come from": the listener's own
/// photos, an image model, or a photo already on the internet.
///
/// Three buttons rather than one button and a menu of sources: which one you want is
/// decided before reaching for it — a real person needs a real photo, a collection about
/// a subject can be drawn — and a menu hides that choice behind a tap.
struct ArtworkSourceRow<LibraryPicker: View>: View {
    let subject: ArtworkSubject
    let hasArtwork: Bool
    /// The Photos picker, built by the caller — each screen saves a picked file its own
    /// way, and `PhotosPicker`'s label closure can't reach back into this view's state.
    @ViewBuilder let libraryPicker: LibraryPicker
    let onUse: (Data) -> Void
    let onRemove: () -> Void

    @State private var asking: ArtworkSource?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(hasArtwork ? "Change photo" : "Add photo")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if hasArtwork {
                    Button("Remove", role: .destructive, action: onRemove).font(.footnote)
                }
            }
            HStack(spacing: 8) {
                libraryPicker
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                sourceButton(.generated, title: "From AI", systemImage: "sparkles")
                sourceButton(.publicPhoto, title: "From Internet", systemImage: "globe")
                Spacer(minLength: 0)
            }
        }
        .sheet(item: $asking) { source in
            AiArtworkSheet(source: source, subject: subject, onUse: onUse)
        }
    }

    private func sourceButton(
        _ source: ArtworkSource, title: LocalizedStringKey, systemImage: String
    ) -> some View {
        Button { asking = source } label: {
            Label(title, systemImage: systemImage).font(.caption)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
    }
}
