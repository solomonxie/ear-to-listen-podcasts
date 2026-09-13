import SwiftUI

/// Per-source sync controls (frequency, manual sync, storage stats), a real synced-episode
/// list that plays via `PlaybackEngine` (transcribing live if needed), and a way into
/// the (still mock) folder browser.
struct RemoteSourceDetailView: View {
    @State var record: ProviderRecord

    @State private var frequency: SyncFrequency
    @State private var isSyncing = false
    @State private var syncMessage: String?
    @State private var stats: TrackStore.ProviderStats?
    @State private var tracks: [Track] = []
    @State private var isShowingPlayer = false

    private let providerStore = ProviderStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)

    init(record: ProviderRecord) {
        _record = State(initialValue: record)
        _frequency = State(initialValue: SyncFrequency(minutes: record.syncFrequencyMinutes))
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    RemoteBrowserView(record: record)
                } label: {
                    Label("Browse Files", systemImage: "folder")
                }
                NavigationLink {
                    SyncQueueView()
                } label: {
                    Label("Sync Queue", systemImage: "arrow.triangle.2.circlepath")
                }
            }

            Section("Sync") {
                Picker("Sync frequency", selection: $frequency) {
                    ForEach(SyncFrequency.allCases) { freq in
                        Text(freq.displayName).tag(freq)
                    }
                }
                .onChange(of: frequency) { _, newValue in
                    try? providerStore.updateSyncFrequency(id: record.id, minutes: newValue.minutes)
                }
                if frequency != .manual {
                    Label("More frequent syncing means more requests to your cloud storage — this can increase your bill if your provider charges per request.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                LabeledContent("Last synced", value: record.lastSyncedAt.map(formattedDate) ?? "Never")
                Button {
                    Task { await syncNow() }
                } label: {
                    if isSyncing {
                        ProgressView()
                    } else {
                        Text("Sync Now")
                    }
                }
                .disabled(isSyncing)
                if let syncMessage {
                    Text(syncMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if !tracks.isEmpty {
                Section("Episodes") {
                    ForEach(tracks) { track in
                        Button {
                            PlaybackEngine.shared.play(track: track, queue: tracks)
                            isShowingPlayer = true
                        } label: {
                            Text(track.title).lineLimit(1)
                        }
                    }
                }
            }

            Section("Storage") {
                if let stats, stats.count > 0 {
                    LabeledContent("Episodes", value: "\(stats.count)")
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: stats.totalBytes, countStyle: .file))
                    if stats.lostCount > 0 {
                        LabeledContent("Missing since last sync", value: "\(stats.lostCount)")
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("No episodes synced yet.").foregroundStyle(.secondary)
                }
                Text("From local metadata as of the last sync — not a live scan of the bucket.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(record.label)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadStats)
        .sheet(isPresented: $isShowingPlayer) {
            RealPlayerView()
        }
    }

    private func loadStats() {
        stats = try? trackStore.stats(forProvider: record.id)
        tracks = (try? trackStore.tracks(forProvider: record.id)) ?? []
    }

    private func syncNow() async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            let result = try await SyncEngine().sync(providerRecord: record)
            syncMessage = "Added \(result.added), \(result.lost) missing, \(result.totalFiles) files found."
            record.lastSyncedAt = Date()
            loadStats()
        } catch {
            syncMessage = describeAWSError(error)
        }
    }

    private func formattedDate(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}
