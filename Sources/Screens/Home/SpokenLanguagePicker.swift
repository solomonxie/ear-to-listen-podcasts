import SwiftUI

/// "What language is this recorded in?", asked at whichever level knows the answer —
/// speaker, album or episode. Most specific wins when they disagree, so each level offers
/// an "inherit" option rather than forcing a choice it can't make.
struct SpokenLanguagePicker: View {
    let title: LocalizedStringKey
    /// What this level would use if it stayed on "inherit" — shown so the choice reads as
    /// a change rather than a guess.
    let inheritedLabel: String
    @Binding var language: String?

    var body: some View {
        Picker(title, selection: $language) {
            Text("Inherit (\(inheritedLabel))").tag(String?.none)
            ForEach(AppleSpeechTranscriber.supportedLocales, id: \.identifier) { locale in
                Text(TranscriptPane.languageName(locale)).tag(String?.some(locale.identifier(.bcp47)))
            }
        }
        .pickerStyle(.menu)
    }
}
