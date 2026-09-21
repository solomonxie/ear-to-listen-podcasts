import SwiftUI

/// "What language is this recorded in?", asked at whichever level knows the answer —
/// speaker, album or episode. Most specific wins when they disagree.
///
/// **The inherited answer shows as the selected one**, not as an "Inherit (English)" row
/// above the real choices. Both said the same thing, and the bracket made the reader work
/// out that they did; a language field should read as the language. Nothing is written
/// until the listener picks — inheriting stays inheriting until it's changed by hand —
/// but on screen the row says what this episode will actually be recognised in.
///
/// A wheel that unfolds in the form rather than a menu over it. There are dozens of
/// languages — a wheel turns under one thumb, where a list of rows scrolls the whole page
/// along with it.
struct SpokenLanguagePicker: View {
    let title: LocalizedStringKey
    /// What this level uses while it has no answer of its own — the parent's, or the
    /// phone's. Shown as the selection when `language` is nil.
    let inheritedLabel: String
    @Binding var language: String?
    /// Shared with the other pickers in the same form, so only one is ever open.
    let id: String
    @Binding var open: String?

    private var options: [UnfoldingPicker<String?>.Option] {
        SpokenLanguagePicker.ordered(AppleSpeechTranscriber.supportedLocales).map {
            UnfoldingPicker.Option($0.identifier(.bcp47), TranscriptPane.languageName($0))
        }
    }

    /// The inherited value shown in place of the empty one, matched by name against the
    /// options so the wheel lands on it. An inherited language the recognisers don't
    /// offer falls back to the first option rather than showing a blank row.
    private var shown: Binding<String?> {
        Binding(
            get: {
                if let language { return language }
                return options.first { $0.label == inheritedLabel }?.value ?? options.first?.value
            },
            set: { language = $0 }
        )
    }

    var body: some View {
        UnfoldingOptionWheel(title: title, id: id, open: $open, selection: shown, options: options)
    }

    /// The two this library is actually in, first, then everything else alphabetically as
    /// the system lists it. A recogniser list sorted by locale identifier buries the
    /// answer somewhere in the middle for every single user.
    static func ordered(_ locales: [Locale]) -> [Locale] {
        func code(_ locale: Locale) -> String? { locale.language.languageCode?.identifier }
        return locales.filter { code($0) == "en" }
            + locales.filter { code($0) == "zh" }
            + locales.filter { code($0) != "en" && code($0) != "zh" }
    }
}
