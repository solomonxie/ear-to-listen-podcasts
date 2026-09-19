import SwiftUI

/// The language the recognizer should expect, picked where the episode's other details
/// are edited. The language ranks with them — it belongs to the recording, not to the
/// transcript run — so this is the only place it's asked for.
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
    let inheritedLabel: String
    /// BCP-47 languages this phone can recognise offline, so the picker can say so before
    /// you pick one rather than after it fails.
    let readyLanguages: Set<String>
    let hasCheckedLanguages: Bool
    let id: String
    @Binding var open: String?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.localeIdentifier == rhs.localeIdentifier
            && lhs.inheritedLabel == rhs.inheritedLabel
            && lhs.hasCheckedLanguages == rhs.hasCheckedLanguages
            && lhs.readyLanguages == rhs.readyLanguages
            && lhs.open == rhs.open
    }

    var body: some View {
        // The phone's language says nothing about the episode's, and picking the wrong
        // recognizer doesn't fail — it returns confident nonsense forever.
        UnfoldingOptionWheel(
            title: "Language", id: id, open: $open, selection: languageSelection,
            options: [UnfoldingPicker.Option(nil, "Inherit (\(inheritedLabel))")]
                + orderedLocales.map {
                    UnfoldingPicker.Option($0.identifier(.bcp47), label(for: $0))
                }
        )
    }

    private var languageLabel: String {
        guard let localeIdentifier else { return inheritedLabel }
        return TranscriptPane.languageName(Locale(identifier: localeIdentifier))
    }

    /// English, then the Chinese variants, then the rest — the two this library is in,
    /// where they can be reached without scrolling. Whether a model is already downloaded
    /// is said in the row's own label rather than by reordering, so the list doesn't
    /// rearrange itself as downloads finish.
    private var orderedLocales: [Locale] {
        SpokenLanguagePicker.ordered(AppleSpeechTranscriber.supportedLocales)
    }

    private func label(for locale: Locale) -> String {
        let name = TranscriptPane.languageName(locale)
        guard hasCheckedLanguages else { return name }
        return readyLanguages.contains(locale.identifier(.bcp47)) ? "\(name) · on this iPhone" : name
    }

    private var languageSelection: Binding<String?> {
        Binding(get: { localeIdentifier }, set: { TranscriptRunner.shared.setEpisodeLanguage($0) })
    }
}


extension EpisodeLanguageField {
    /// The field as the currently-playing episode needs it: the app's own record of which
    /// languages are downloaded, and whose answer this episode would inherit.
    init(playing: TranscriptRunner, languages: OnDeviceLanguages, id: String, open: Binding<String?>) {
        let inherited = playing.inheritedLanguage
        let label: String
        if let inherited, inherited.source != .episode {
            label = "\(TranscriptPane.languageName(Locale(identifier: inherited.identifier))) · \(inherited.source.displayName)"
        } else {
            label = "automatic"
        }
        self.init(
            localeIdentifier: playing.track?.language,
            inheritedLabel: label,
            readyLanguages: languages.ready,
            hasCheckedLanguages: languages.hasChecked,
            id: id,
            open: open
        )
    }
}
