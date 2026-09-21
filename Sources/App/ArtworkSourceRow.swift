import SwiftUI

/// The one row that answers "where does this picture come from": the listener's own
/// photos, an image model, or the internet.
///
/// Three buttons rather than one button and a menu of sources: which one you want is
/// decided before reaching for it — a real person needs a real photo, a collection about
/// a subject can be drawn — and a menu hides that choice behind a tap.
///
/// **Search is a web search, not a model.** Asking a chat model to name a public photo
/// produced a URL that looked right and often wasn't, and the wrong face on a real
/// speaker is the one mistake here that matters. Image search hands back a page of
/// candidates the listener judges, costs nothing, and the picture comes home through the
/// Photos picker like any other. It opens in the phone's own browser — see
/// `ArtworkSubject.imageSearchURL` for what it takes to keep it there.
///
/// **Draw unfolds downward rather than opening a sheet.** A sheet covered the page the
/// description came from and had to be dismissed; unfolded in place, the page stays where
/// it was and the answer lands under the button that asked for it. Opening the panel
/// costs nothing — the request only leaves when "Draw it" is pressed, because the
/// description is the thing worth reading first and it costs real money to get wrong.
///
/// **Nothing is saved until the picture is on screen and accepted.** A generated image is
/// a guess that costs a few cents, so it's shown before it's kept.
struct ArtworkSourceRow<LibraryPicker: View>: View {
    let subject: ArtworkSubject
    let hasArtwork: Bool
    /// The Photos picker, built by the caller — each screen saves a picked file its own
    /// way, and `PhotosPicker`'s label closure can't reach back into this view's state.
    @ViewBuilder let libraryPicker: LibraryPicker
    let onUse: (Data) -> Void
    let onRemove: () -> Void

    @State private var isDrawing = false
    @State private var prompt = ""
    @State private var isWorking = false
    @State private var preview: UIImage?
    @State private var pictureData: Data?
    @State private var errorMessage: String?
    @State private var job: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(hasArtwork ? "Change photo" : "Add photo")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                libraryPicker
                    .capsuleSourceButton()
                Button { open() } label: {
                    Label("Draw", systemImage: "sparkles").font(.caption)
                }
                .capsuleSourceButton()
                if let searchURL = subject.imageSearchURL {
                    Link(destination: searchURL) {
                        Label("Search", systemImage: "globe").font(.caption)
                    }
                    .capsuleSourceButton()
                }
                // In with the ways of putting a picture on, because taking one off is
                // the fourth answer to the same question. Icon only: it's the one of the
                // four whose symbol needs no word, and the row has to fit a phone.
                if hasArtwork {
                    Button(role: .destructive) { onRemove() } label: {
                        Image(systemName: "trash").font(.caption)
                    }
                    .capsuleSourceButton()
                    .tint(.red)
                    .accessibilityLabel("Remove photo")
                }
                Spacer(minLength: 0)
            }
            if isDrawing {
                panel
            }
        }
        .animation(.easeOut(duration: 0.2), value: isDrawing)
        .onDisappear { job?.cancel() }
    }

    /// What was asked, how it's going, and what came back — in that order, because that
    /// is the order it happens in.
    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Draw one").font(.caption.weight(.semibold))
                if isWorking { ProgressView().controlSize(.mini) }
                Spacer(minLength: 0)
                Button { close() } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            TextField("Describe it", text: $prompt, axis: .vertical)
                .font(.caption)
                .lineLimit(1...5)
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))

            if let errorMessage {
                Text(errorMessage).font(.caption2).foregroundStyle(.orange)
            }

            if let preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            HStack(spacing: 8) {
                if preview != nil {
                    Button("Use this picture") { use() }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                }
                Button(preview == nil ? "Draw it" : "Try again") { send() }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .disabled(isWorking || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer(minLength: 0)
            }
            .font(.caption)

            Text(ArtworkSourceCopy.costNote).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// Tapping Draw while it's open folds it away again — the same button, both
    /// directions, like every other unfolding control on these pages. Opening only fills
    /// the description in; nothing is sent until the button under it is pressed.
    private func open() {
        guard !isDrawing else { return close() }
        isDrawing = true
        prompt = subject.defaultPrompt
        preview = nil
        pictureData = nil
        errorMessage = nil
    }

    private func send() {
        job?.cancel()
        isWorking = true
        errorMessage = nil
        let asked = prompt
        job = Task {
            do {
                let data = try await ArtworkSuggester().picture(prompt: asked)
                guard !Task.isCancelled else { return }
                pictureData = data
                preview = UIImage(data: data)
                if preview == nil {
                    errorMessage = ArtworkSuggester.UnusableImageError().localizedDescription
                }
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func use() {
        guard let pictureData else { return }
        onUse(pictureData)
        close()
    }

    private func close() {
        job?.cancel()
        isDrawing = false
        preview = nil
        pictureData = nil
        errorMessage = nil
        isWorking = false
    }
}

private extension View {
    /// One shape for every way of getting a picture, so the row reads as a set of peers.
    func capsuleSourceButton() -> some View {
        font(.caption)
            // `Label` leaves a gap wide enough for a word between the icon and the text,
            // which is what made four short names into four long capsules — and then made
            // the longest of them wrap inside its own pill.
            .labelStyle(TightLabelStyle())
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
    }
}

private enum ArtworkSourceCopy {
    static var costNote: LocalizedStringKey {
        "An image model draws a picture from the description. Costs a few cents on your own key, and it lands in that key's history. Never use it for a real person's face."
    }
}

private struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}
