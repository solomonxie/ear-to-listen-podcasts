import SwiftUI

/// The language the recognizer should expect, picked where the episode's other details
/// are edited. The language ranks with them — it belongs to the recording, not to the
/// transcript run — so this is the only place it's asked for.
///
/// **The inherited answer shows as the selected one**, not as an "Inherit (English)" row
/// above the real choices — same as `SpokenLanguagePicker`, and for the same reason: the
/// row should read as the language this episode will actually be recognised in. Nothing
/// is written until the listener picks.
///
/// Unfolds in the episode card like every other field there, rather than dropping a menu
/// over it. That also fixes what this type was fighting: the page redraws several times a
/// second while a window is being recognised, and SwiftUI shuts an open `Menu` whose
/// content it rebuilds — which made the old version impossible to reach at exactly the
/// moment you'd want it. The open state now lives in the parent, so a redraw can't close
/// it.
///
/// Value-only and `Equatable` on purpose, and writes go straight to the shared
/// `TranscriptRunner` rather than through a binding, since a binding would defeat the
/// equality check.
struct EpisodeLanguageField: View, Equatable {
    /// This episode's own answer, not the app's — someone editing here has just heard the
    /// audio, so what they pick belongs to the episode and outranks the album's and the
    /// speaker's.
    let localeIdentifier: String?
    /// What this episode would be recognised in while it has no answer of its own — the
    /// album's language, or the speaker's. Shown as the selection when there's no answer.
    let inheritedIdentifier: String?
    let id: String
    @Binding var open: String?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.localeIdentifier == rhs.localeIdentifier
            && lhs.inheritedIdentifier == rhs.inheritedIdentifier
            && lhs.open == rhs.open
    }

    var body: some View {
        // The phone's language says nothing about the episode's, and picking the wrong
        // recognizer doesn't fail — it returns confident nonsense forever.
        UnfoldingOptionWheel(
            title: "Language", id: id, open: $open, selection: languageSelection,
            options: orderedLocales.map {
                UnfoldingPicker.Option($0.identifier(.bcp47), TranscriptPane.languageName($0))
            }
        )
    }

    /// English, then the Chinese variants, then the rest — the two this library is in,
    /// where they can be reached without scrolling. A row says the language and nothing
    /// else: whether its model happens to be downloaded is the phone's business, it
    /// changes under you, and `supportsOnDeviceRecognition` reads false for languages
    /// that transcribe perfectly well anyway.
    private var orderedLocales: [Locale] {
        SpokenLanguagePicker.ordered(AppleSpeechTranscriber.supportedLocales)
    }

    private var languageSelection: Binding<String?> {
        Binding(
            get: { localeIdentifier ?? shownInherited },
            set: { TranscriptRunner.shared.setEpisodeLanguage($0) }
        )
    }

    /// The inherited language matched against the recogniser list so the wheel lands on
    /// it. An album tagged `zh` and a recogniser offering `zh-CN` are the same answer to
    /// a reader, so the region is allowed to differ; anything unmatched falls back to the
    /// first option rather than showing a blank row.
    private var shownInherited: String? {
        let values = orderedLocales.map { $0.identifier(.bcp47) }
        guard let inheritedIdentifier else { return values.first }
        let code = Locale(identifier: inheritedIdentifier).language.languageCode
        return values.first { $0 == inheritedIdentifier }
            ?? values.first { Locale(identifier: $0).language.languageCode == code }
            ?? values.first
    }
}


extension EpisodeLanguageField {
    /// The field as the currently-playing episode needs it — including whose answer this
    /// episode would inherit while it has none of its own.
    init(playing: TranscriptRunner, id: String, open: Binding<String?>) {
        let inherited = playing.inheritedLanguage
        self.init(
            localeIdentifier: playing.track?.language,
            inheritedIdentifier: inherited?.source == .episode ? nil : inherited?.identifier,
            id: id,
            open: open
        )
    }
}
