import SwiftUI

/// Everywhere one term is said: which episodes, how often, and — once an episode is
/// opened — every line it's said in, in the order it's said, each one a tap that plays
/// from that second.
///
/// **A term belongs to no episode and no speaker.** The same name said in two shows by
/// two people is one term with one page, which is the whole reason it's extracted rather
/// than typed: this page is where a library of hundreds of episodes answers "where have I
/// heard this before".
///
/// **Mentions are derived, not stored.** The count is what a ranking needs and that's in
/// the database; the lines are found by scanning that episode's transcript when its row
/// is opened. A row per sentence would be a second copy of the transcript, and the scan
/// is one episode's worth of text at the moment someone asks for it.
struct TermDetailView: View {
    let term: Term

    @State private var episodes: [(track: Track, mentions: Int)] = []
    @State private var albumNames: [String: String] = [:]
    @State private var speakerNames: [String: String] = [:]
    @State private var openTrackIDs: Set<String> = []
    @State private var mentions: [String: [TermMention]] = [:]

    private let termStore = TermStore()
    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let transcriptStore = TranscriptStore(dbQueue: DatabaseManager.shared.dbQueue)

    private var total: Int { episodes.reduce(0) { $0 + $1.mentions } }
    private var speakerCount: Int {
        Set(episodes.compactMap(\.track.artistID)).count
    }

    var body: some View {
        List {
            Section {
                ForEach(episodes, id: \.track.id) { entry in
                    episodeRow(entry)
                    if openTrackIDs.contains(entry.track.id) {
                        mentionRows(for: entry.track)
                    }
                }
            } header: {
                Text(headline)
            } footer: {
                if episodes.isEmpty {
                    Text("Nothing mentions this any more. Terms are rewritten whenever an episode is analysed again.")
                }
            }
        }
        .listStyle(.plain)
        .contentMargins(.bottom, 72, for: .scrollContent)
        .navigationTitle(term.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            load()
            await healCounts()
        }
    }

    /// Episodes and speakers both, because a term spanning two speakers is the answer to a
    /// different question from one said forty times by the same person.
    private var headline: String {
        var parts = ["\(total) mention\(total == 1 ? "" : "s")"]
        parts.append("\(episodes.count) episode\(episodes.count == 1 ? "" : "s")")
        if speakerCount > 1 { parts.append("\(speakerCount) speakers") }
        return parts.joined(separator: " · ")
    }

    private func episodeRow(_ entry: (track: Track, mentions: Int)) -> some View {
        let isOpen = openTrackIDs.contains(entry.track.id)
        return Button {
            toggle(entry.track)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                ArtworkTile(track: entry.track, cornerRadius: 7, symbolSize: 16)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.track.title).font(.subheadline).lineLimit(2)
                    if let context = context(for: entry.track) {
                        Text(context).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                // The bar is the comparison the list is for: which episode is *about* this
                // term, rather than which one mentions it in passing.
                MentionBar(mentions: entry.mentions, of: episodes.first?.mentions ?? 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func mentionRows(for track: Track) -> some View {
        let found = mentions[track.id]
        if let found, found.isEmpty {
            // The term came out of the AI pass but isn't said in those words — it
            // paraphrased. There's still an episode to play.
            Button {
                PlaybackEngine.shared.open(track: track, queue: episodes.map(\.track))
            } label: {
                Label("Not said in those words — play the episode", systemImage: "play.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 34)
        } else if let found {
            ForEach(found) { mention in
                Button {
                    PlaybackEngine.shared.open(
                        track: track, queue: episodes.map(\.track), startingAt: mention.start
                    )
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Text(Scrubber.formatted(mention.start))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.2), in: Capsule())
                        Text(mention.text)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 34)
            }
        } else {
            HStack {
                ProgressView().controlSize(.small)
                Text("Reading the transcript…").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.leading, 34)
        }
    }

    private func context(for track: Track) -> String? {
        [track.artistID.flatMap { speakerNames[$0] }, track.albumID.flatMap { albumNames[$0] }]
            .compactMap { $0 }
            .nilIfEmpty?
            .joined(separator: " · ")
    }

    private func toggle(_ track: Track) {
        if openTrackIDs.contains(track.id) {
            openTrackIDs.remove(track.id)
            return
        }
        openTrackIDs.insert(track.id)
        guard mentions[track.id] == nil else { return }
        // Off the main actor: a transcript is tens of thousands of words, and the row
        // that opened it has already drawn.
        Task {
            let name = term.name
            let segments = (try? transcriptStore.find(trackID: track.id)).flatMap { $0 } ?? []
            // Lines only. The count beside the row was corrected for every episode when the
            // page opened (`healCounts`) — recounting it again here, one row at a time, is
            // what made the number look like it only became true once you tapped it.
            mentions[track.id] = await Task.detached(priority: .userInitiated) {
                EpisodeSummarizer.mentions(of: name, in: segments)
            }.value
        }
    }

    /// Brings every listed count back in line with the transcript behind it, once, when
    /// the page opens.
    ///
    /// **This used to happen only when a row was expanded**, which meant the number beside
    /// an episode was whatever the analysis pass guessed against a transcript that was
    /// still being written — usually one — until someone happened to tap that exact row.
    /// The list is a ranking; a ranking of numbers that are corrected only when looked at
    /// is not a ranking. The same staleness was being summed into the Terms shelf and the
    /// library chart, so correcting it here fixes those too, which is why it ends with the
    /// notification that redraws them.
    ///
    /// One query for every transcript on the page and the counting off the main actor: the
    /// per-row version was a database round trip per episode, fired from a view body's tap
    /// handler.
    private func healCounts() async {
        let trackIDs = episodes.map(\.track.id)
        guard !trackIDs.isEmpty else { return }
        let transcriptStore = self.transcriptStore
        let termStore = self.termStore
        let changed = await Task.detached(priority: .userInitiated) {
            let byTrack = (try? transcriptStore.find(trackIDs: trackIDs)) ?? [:]
            var changed = false
            for (trackID, segments) in byTrack {
                let spoken = segments.map(\.text).joined(separator: " ")
                if (try? termStore.recount(forTrack: trackID, in: spoken)) == true { changed = true }
            }
            return changed
        }.value
        guard changed else { return }
        load()
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    private func load() {
        episodes = (try? termStore.episodes(forTerm: term.id)) ?? []
        albumNames = names(for: Set(episodes.compactMap(\.track.albumID))) { try libraryStore.album(id: $0)?.name }
        speakerNames = names(for: Set(episodes.compactMap(\.track.artistID))) { try libraryStore.artist(id: $0)?.name }
    }

    private func names(for ids: Set<String>, lookup: (String) throws -> String?) -> [String: String] {
        Dictionary(uniqueKeysWithValues: ids.compactMap { id in
            (try? lookup(id)).flatMap { $0 }.map { (id, $0) }
        })
    }
}

/// A count and the bar that puts it in proportion, in the width a list row has spare.
private struct MentionBar: View {
    let mentions: Int
    let of: Int

    var body: some View {
        HStack(spacing: 6) {
            Text("\(mentions)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
            Capsule()
                .fill(Color.accentColor.opacity(0.7))
                .frame(width: max(4, 44 * CGFloat(mentions) / CGFloat(max(of, 1))), height: 8)
        }
    }
}

private extension Array {
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}
