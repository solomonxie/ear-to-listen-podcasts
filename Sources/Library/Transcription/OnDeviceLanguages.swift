import Foundation
import Speech

/// Which languages this particular phone can recognise with no network.
///
/// The list exists because the answer is per-phone and invisible: iOS downloads a speech
/// model when its language is added to Dictation, and nothing in the app can tell you it
/// happened. Picking a language the phone has no model for looks identical to picking one
/// it has — until transcription refuses, which is a bad place to find out.
@MainActor
final class OnDeviceLanguages: ObservableObject {
    static let shared = OnDeviceLanguages()

    /// BCP-47 identifiers with a model already on this phone.
    @Published private(set) var ready: Set<String> = []
    @Published private(set) var hasChecked = false

    private var isChecking = false

    func isReady(_ locale: Locale) -> Bool { ready.contains(locale.identifier(.bcp47)) }

    /// Cheap enough to call from `.task`; the sweep itself runs once.
    func refreshIfNeeded() async {
        guard !hasChecked, !isChecking else { return }
        isChecking = true
        ready = await Self.sweep()
        hasChecked = true
        isChecking = false
    }

    /// Off the main actor: this builds one recognizer per supported language, which is
    /// slow enough to stutter a menu if done while it's open.
    private static func sweep() async -> Set<String> {
        await Task.detached(priority: .utility) { () -> Set<String> in
            // The flags settle asynchronously, so the first recognizer built after launch
            // reads false for a moment and would poison the whole sweep.
            _ = SFSpeechRecognizer(locale: Locale.current)?.supportsOnDeviceRecognition
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            var found: Set<String> = []
            for locale in SFSpeechRecognizer.supportedLocales() {
                guard let recognizer = SFSpeechRecognizer(locale: locale) else { continue }
                if recognizer.supportsOnDeviceRecognition { found.insert(locale.identifier(.bcp47)) }
            }
            return found
        }.value
    }
}
