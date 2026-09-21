import GRDB

/// A "Speaker" in the UI — real synced tracks read this from embedded artist metadata.
struct Artist: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "artists"

    var id: String
    var name: String
    var bio: String?
    /// The themes this speaker keeps coming back to — a short comma-separated line, not
    /// a paragraph, since it sits in a row beside its label.
    var knownFor: String?
    /// Who they are away from the microphone: role, affiliation, what they did before.
    var background: String?
    /// A public page about them — Wikipedia, a university profile, their own site. Only
    /// ever as good as the model that suggested it, which is why it's shown as a link to
    /// check rather than as a fact.
    var link: String?
    /// The long read — a few paragraphs holding together everything above. Written by
    /// `SpeakerProfileSuggester` from what the library already knows, and editable after.
    var profile: String?
    /// Filename under `ImageFileStore.speakerPhotos`'s directory — not a full path, so it stays valid
    /// across reinstalls/devices and travels as-is in a `LibrarySnapshot` backup.
    var photoFileName: String?
    /// BCP-47 identifier for the language this speaker speaks, e.g. `zh-CN`. Drives which
    /// recognizer transcribes their episodes; nil falls back to the phone's language.
    var language: String?
    /// Only ever set by the repo-only sample seeder (`DemoData/`); nothing shipped writes it.
    var isDemo: Bool = false
}
