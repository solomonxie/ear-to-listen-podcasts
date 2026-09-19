import SwiftUI

/// "What language is this recorded in?", asked at whichever level knows the answer —
/// speaker, album or episode. Most specific wins when they disagree, so each level offers
/// an "inherit" option rather than forcing a choice it can't make.
///
/// A wheel that unfolds in the form rather than a menu over it. There are dozens of
/// languages — a wheel turns under one thumb, where a list of rows scrolls the whole page
/// along with it.
struct SpokenLanguagePicker: View {
    let title: LocalizedStringKey
    /// What this level would use if it stayed on "inherit" — shown so the choice reads as
    /// a change rather than a guess.
    let inheritedLabel: String
    @Binding var language: String?
    /// Shared with the other pickers in the same form, so only one is ever open.
    let id: String
    @Binding var open: String?

    var body: some View {
        UnfoldingOptionWheel(
            title: title, id: id, open: $open, selection: $language,
            options: [UnfoldingPicker.Option(nil, "Inherit (\(inheritedLabel))")]
                + SpokenLanguagePicker.ordered(AppleSpeechTranscriber.supportedLocales).map {
                    UnfoldingPicker.Option($0.identifier(.bcp47), TranscriptPane.languageName($0))
                }
        )
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
