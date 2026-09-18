import SwiftUI

/// Reviews one AI pass over a whole album before any of it is written. Only episodes that
/// already have a finished transcript on the phone take part — nothing is downloaded or
/// transcribed to run this — and every proposed change arrives switched on but
/// individually refusable, so a batch stays something you approve rather than something
/// that happens to your library.
struct AlbumAnalysisView: View {
    let album: Album
    let artistName: String?
    let tracks: [Track]
    @Environment(\.dismiss) private var dismiss

    @State private var isAnalyzing = false
    @State private var result: AlbumMetadataSuggester.Result?
    @State private var errorMessage: String?
    @State private var acceptedEpisodes: Set<Int> = []
    @State private var acceptsAlbum = true

    private let suggester = AlbumMetadataSuggester()
    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)

    private var partition: (ready: [Track], skipped: [Track]) { suggester.partition(tracks: tracks) }

    var body: some View {
        NavigationStack {
            List {
                if let result {
                    albumSection(result)
                    episodeSection(result)
                } else {
                    summarySection
                }
                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.orange)
                }
            }
            .navigationTitle("Analyze Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if result == nil {
                        Button("Analyze") { Task { await analyze() } }
                            .disabled(isAnalyzing || partition.ready.isEmpty)
                    } else {
                        Button("Apply") { apply() }
                            .disabled(acceptedEpisodes.isEmpty && !acceptsAlbum)
                    }
                }
            }
        }
    }

    private var summarySection: some View {
        Section {
            let ready = partition.ready
            let skipped = partition.skipped
            LabeledContent("Fully transcribed", value: "\(ready.count)")
            LabeledContent("Skipped", value: "\(skipped.count)")
            if isAnalyzing {
                HStack {
                    ProgressView()
                    Text("Reading \(ready.count) transcript\(ready.count == 1 ? "" : "s")…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Reads only transcripts already stored on this phone — nothing is downloaded and nothing is transcribed. Episodes that aren't finished yet are left exactly as they are.")
        }
    }

    @ViewBuilder
    private func albumSection(_ result: AlbumMetadataSuggester.Result) -> some View {
        if let suggestion = result.album, suggestion.name != nil || suggestion.artist != nil || suggestion.notes != nil {
            Section("Album") {
                Toggle(isOn: $acceptsAlbum) {
                    VStack(alignment: .leading, spacing: 3) {
                        if let name = suggestion.name { change(from: album.name, to: name) }
                        if let artist = suggestion.artist { change(from: artistName ?? "no speaker", to: artist) }
                        if let notes = suggestion.notes {
                            Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func episodeSection(_ result: AlbumMetadataSuggester.Result) -> some View {
        let ready = partition.ready
        Section("Episodes") {
            ForEach(result.episodes.filter { $0.index < ready.count }) { suggestion in
                let track = ready[suggestion.index]
                Toggle(isOn: binding(for: suggestion.index)) {
                    VStack(alignment: .leading, spacing: 3) {
                        change(from: track.title, to: suggestion.title ?? track.title)
                        Text(TrackRow.pathHint(for: track))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        if let notes = suggestion.notes {
                            Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
        }
        if !partition.skipped.isEmpty {
            Section("Left alone (\(partition.skipped.count))") {
                ForEach(partition.skipped) { track in
                    Text(track.title).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private func change(from old: String, to new: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(new).font(.subheadline.weight(.semibold))
            Text(old).font(.caption).foregroundStyle(.secondary).strikethrough()
        }
    }

    private func binding(for index: Int) -> Binding<Bool> {
        Binding(
            get: { acceptedEpisodes.contains(index) },
            set: { accepted in
                if accepted {
                    acceptedEpisodes.insert(index)
                } else {
                    acceptedEpisodes.remove(index)
                }
            }
        )
    }

    private func analyze() async {
        isAnalyzing = true
        errorMessage = nil
        do {
            let analyzed = try await suggester.analyze(album: album, artistName: artistName, tracks: tracks)
            acceptedEpisodes = Set(analyzed.episodes.filter { $0.title != nil || $0.notes != nil }.map(\.index))
            result = analyzed
        } catch {
            errorMessage = error.localizedDescription
        }
        isAnalyzing = false
    }

    private func apply() {
        guard let result else { return }
        let ready = partition.ready
        // Accepting a whole album's suggestions rewrites every episode in it at once, so
        // it leaves a copy of what it's about to overwrite under a name of its own.
        if let current = try? BackupService().currentArchive() {
            LocalBackups.writeBefore("suggestions", archive: current)
        }

        for suggestion in result.episodes where acceptedEpisodes.contains(suggestion.index) {
            guard suggestion.index < ready.count else { continue }
            var track = ready[suggestion.index]
            if let title = suggestion.title { track.title = title }
            if let notes = suggestion.notes { track.notes = notes }
            if let year = suggestion.year { track.year = year }
            track.metadataEditedAt = Date()
            try? trackStore.saveEdit(track, artistName: artistName, albumName: album.name)
        }

        if acceptsAlbum, let suggestion = result.album {
            try? libraryStore.updateAlbum(
                id: album.id,
                name: suggestion.name ?? album.name,
                notes: suggestion.notes ?? album.notes,
                artworkFileName: album.artworkFileName,
                year: album.year
            )
            if let artist = suggestion.artist, artist != artistName {
                _ = try? libraryStore.reassignAlbumArtist(albumID: album.id, artistName: artist)
            }
        }

        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        dismiss()
    }
}
