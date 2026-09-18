import SwiftUI

/// The language the recognizer should expect, picked where the episode's other details
/// are edited. The language ranks with them — it belongs to the recording, not to the
/// transcript run — so this is the only place it's asked for.
///
/// Value-only and `Equatable` on purpose: the page redraws several times a second while a
/// window is being recognised, and SwiftUI shuts an open `Menu` whose content it rebuilds
/// — which made this impossible to reach at exactly the moment you'd want it. Writes go
/// straight to the shared `LiveTranscript` rather than through a binding, since a binding
/// would defeat the equality check.
struct TranscriptLanguageMenu: View, Equatable {
    /// This episode's own answer, not the app's — someone editing here has just heard the
    /// audio, so what they pick belongs to the episode and outranks the album's and the
    /// speaker's.
    let localeIdentifier: String?
    let inheritedLabel: String
    /// BCP-47 languages this phone can recognise offline, so the picker can say so before
    /// you pick one rather than after it fails.
    let readyLanguages: Set<String>
    let hasCheckedLanguages: Bool

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.localeIdentifier == rhs.localeIdentifier
            && lhs.inheritedLabel == rhs.inheritedLabel
            && lhs.hasCheckedLanguages == rhs.hasCheckedLanguages
            && lhs.readyLanguages == rhs.readyLanguages
    }

    var body: some View {
        Menu {
            // The phone's language says nothing about the episode's, and picking the
            // wrong recognizer doesn't fail — it returns confident nonsense forever.
            Picker("Language", selection: languageSelection) {
                Text("Inherit (\(inheritedLabel))").tag(String?.none)
                ForEach(orderedLocales, id: \.identifier) { locale in
                    Text(label(for: locale)).tag(String?.some(locale.identifier(.bcp47)))
                }
            }
        } label: {
            // Just the answer: this sits in a row already labelled "Language".
            Label(languageLabel, systemImage: "globe")
                .font(.footnote)
        }
    }

    private var languageLabel: String {
        guard let localeIdentifier else { return inheritedLabel }
        return TranscriptPane.languageName(Locale(identifier: localeIdentifier))
    }

    /// Languages with a model already on this phone come first — that's the practical
    /// difference between a choice that works offline and one that has to download first.
    private var orderedLocales: [Locale] {
        let all = AppleSpeechTranscriber.supportedLocales
        guard hasCheckedLanguages else { return all }
        let ready = all.filter { readyLanguages.contains($0.identifier(.bcp47)) }
        return ready + all.filter { !readyLanguages.contains($0.identifier(.bcp47)) }
    }

    private func label(for locale: Locale) -> String {
        let name = TranscriptPane.languageName(locale)
        guard hasCheckedLanguages else { return name }
        return readyLanguages.contains(locale.identifier(.bcp47)) ? "\(name) · on this iPhone" : name
    }

    private var languageSelection: Binding<String?> {
        Binding(get: { localeIdentifier }, set: { LiveTranscript.shared.setEpisodeLanguage($0) })
    }
}


extension TranscriptLanguageMenu {
    /// The menu as the currently-playing episode needs it: the app's own record of which
    /// languages are downloaded, and whose answer this episode would inherit.
    init(playing: LiveTranscript, languages: OnDeviceLanguages) {
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
            hasCheckedLanguages: languages.hasChecked
        )
    }
}
