import SwiftUI

/// A YouTube video made into an episode: paste the link, and the title, channel and
/// thumbnail fill themselves in. Everything else — marks, notes, summary, collection,
/// speaker — works the way it does for audio from then on.
struct AddYouTubeEpisodeView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var link: String
    @State private var title = ""
    @State private var speaker = ""
    @State private var album = ""
    @State private var length = ""
    @State private var notes = ""
    @State private var isLooking = false
    @State private var isSaving = false
    @State private var lookupFailed = false
    @State private var existing: Track?

    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)

    private var videoID: String? { YouTubeVideo.id(from: link) }

    init(link: String) {
        _link = State(initialValue: link.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("youtube.com/watch?v=…", text: $link)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        Button("Paste") { link = UIPasteboard.general.string ?? link }
                            .buttonStyle(.borderless)
                    }
                    if !link.isEmpty, videoID == nil {
                        Text("That doesn't look like a YouTube link.").font(.footnote).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Link")
                }

                if let videoID {
                    Section {
                        AsyncImage(url: YouTubeVideo.thumbnailURLs(id: videoID).last) { image in
                            image.resizable().aspectRatio(16 / 9, contentMode: .fill)
                        } placeholder: {
                            Color.secondary.opacity(0.15).aspectRatio(16 / 9, contentMode: .fit)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .listRowInsets(EdgeInsets())
                    }

                    if let existing {
                        Section {
                            Button("Open \u{201C}\(existing.title)\u{201D}") { open(existing) }
                        } footer: {
                            Text("This video is already in your library.")
                        }
                    } else {
                        details
                    }
                }
            }
            .navigationTitle("Add YouTube Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Add") { Task { await save() } }
                            .disabled(videoID == nil || existing != nil || title.trimmed.isEmpty)
                    }
                }
            }
            .task(id: videoID) { await lookUp() }
        }
    }

    @ViewBuilder private var details: some View {
        Section {
            HStack {
                TextField("Title", text: $title, axis: .vertical).lineLimit(1...)
                if isLooking { ProgressView() }
            }
            TextField("Speaker", text: $speaker)
            TextField("Album", text: $album)
            TextField("Length, e.g. 1:02:30", text: $length)
                .keyboardType(.numbersAndPunctuation)
        } header: {
            Text("Episode")
        } footer: {
            if lookupFailed {
                Text("Couldn't read the video's details — fill them in by hand.")
            } else {
                Text("Length can stay empty: it's read from the video the first time it plays.")
            }
        }
        Section("My impressions") {
            TextField("What this video is about", text: $notes, axis: .vertical).lineLimit(3...)
        }
    }

    private func lookUp() async {
        existing = nil
        lookupFailed = false
        guard let videoID else { return }
        existing = try? trackStore.find(providerID: YouTubeVideo.providerID, filePath: videoID)
        guard existing == nil else { return }
        isLooking = true
        defer { isLooking = false }
        do {
            let info = try await YouTubeVideo.info(id: videoID)
            guard !Task.isCancelled else { return }
            if title.trimmed.isEmpty { title = info.title }
            if speaker.trimmed.isEmpty, let channel = info.channel { speaker = channel }
        } catch {
            if !Task.isCancelled { lookupFailed = true }
        }
    }

    private func save() async {
        guard let videoID else { return }
        isSaving = true
        defer { isSaving = false }
        var artworkFileName: String?
        if let data = await YouTubeVideo.thumbnail(id: videoID) {
            artworkFileName = try? await ImageFileStore.artwork.save(data, maxDimension: 800)
        }
        let artist = speaker.trimmed.nilIfEmpty.flatMap { try? libraryStore.upsertArtist(name: $0) }
        let collection = album.trimmed.nilIfEmpty.flatMap { try? libraryStore.upsertAlbum(name: $0, artistID: artist?.id) }
        var track = Track(
            id: UUID().uuidString, providerID: YouTubeVideo.providerID,
            artistID: artist?.id, albumID: collection?.id, filePath: videoID, title: title.trimmed,
            durationMs: Self.seconds(in: length).map { Int($0 * 1000) }, updatedAt: Date()
        )
        track.notes = notes.trimmed.nilIfEmpty
        track.artworkFileName = artworkFileName
        track.metadataEditedAt = Date()
        do {
            try trackStore.saveEdit(track, artistName: artist?.name, albumName: collection?.name)
        } catch {
            ImageFileStore.artwork.remove(artworkFileName)
            return
        }
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        open(track)
    }

    private func open(_ track: Track) {
        dismiss()
        PlaybackEngine.shared.open(track: track, queue: [track])
    }

    /// `1:02:30`, `62:30`, or a bare number of minutes.
    static func seconds(in text: String) -> TimeInterval? {
        let parts = text.trimmed.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        let values = parts.compactMap { $0 }
        let total = values.count == 1 ? values[0] * 60 : values.reduce(0) { $0 * 60 + $1 }
        return total > 0 ? total : nil
    }
}
