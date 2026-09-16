import SwiftUI

/// Real folder-style browsing over a remote source, one directory level at a time —
/// recurses by pushing itself with the tapped subfolder's path. There's no separate
/// detail screen and no per-level distinction: every level carries the same "More" menu
/// (frequency, last synced, sync now, sync queue, delete) and the same one-line
/// storage-stats footer, scoped to that folder.
///
/// Both the listing and the stats come from already-synced local metadata — browsing
/// never calls out to the provider. The whole connection is listed and queued once when
/// it's added (`AddS3ProviderView`/`SyncQueueManager.enqueueConnection`); after that only
/// an explicit "Sync Now" or a scheduled `syncFrequencyMinutes` goes back out for file
/// headers. Tapping a file plays it directly, same as tapping any other synced episode.
struct RemoteBrowserView: View {
    @State var record: ProviderRecord
    var folder: String?
    var title: String?
    @ObservedObject var viewModel: SettingsViewModel

    @State private var folders: [String] = []
    @State private var files: [CloudFile] = []
    @State private var isLoadingListing = true
    @State private var errorMessage: String?
    @State private var showingFileInfo: CloudFile?
    @State private var loadingFileID: String?
    @State private var isShowingPlayer = false
    @State private var showingQueue = false

    @State private var frequency: SyncFrequency
    @State private var isSyncing = false
    @State private var syncMessage: String?
    @State private var stats: TrackStore.ProviderStats?
    @State private var showingDeleteConfirm = false

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var queueManager = SyncQueueManager.shared
    private let providerStore = ProviderStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)

    init(record: ProviderRecord, folder: String? = nil, title: String? = nil, viewModel: SettingsViewModel) {
        _record = State(initialValue: record)
        self.folder = folder
        self.title = title
        self.viewModel = viewModel
        _frequency = State(initialValue: SyncFrequency(minutes: record.syncFrequencyMinutes))
    }

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.orange)
            }
            Section {
                if isLoadingListing {
                    // Neither the (still-empty) list nor the stats footer below show while
                    // this is in flight — otherwise the stats render first (a fast local DB
                    // read) above an empty list, looking like an empty folder.
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(folders, id: \.self) { name in
                        NavigationLink {
                            RemoteBrowserView(record: record, folder: childPath(name), title: name, viewModel: viewModel)
                        } label: {
                            Label(name, systemImage: "folder.fill")
                        }
                    }
                    ForEach(files) { file in
                        fileRow(file)
                    }
                }
            } footer: {
                // A compact stats line rather than its own section — it's a status readout,
                // not another navigable tier alongside the folders above it. The syncing
                // indicator rides on the same line rather than its own row, since it's just
                // a transient qualifier on those same numbers.
                if !isLoadingListing {
                    HStack(spacing: 4) {
                        Text(statsSummary).font(.caption)
                        if isSyncing || isProviderSyncQueueActive {
                            ProgressView().controlSize(.small)
                            Text("Syncing…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(title ?? record.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // Nested rather than inline: seven frequencies would otherwise be most
                    // of this menu, burying the actions underneath them. Persisting happens
                    // in the binding's setter, since an `onChange` on a view inside a menu
                    // only fires while that menu is open.
                    Menu {
                        Picker("Sync frequency", selection: Binding(
                            get: { frequency },
                            set: { newValue in
                                frequency = newValue
                                try? providerStore.updateSyncFrequency(id: record.id, minutes: newValue.minutes)
                            }
                        )) {
                            ForEach(SyncFrequency.allCases) { freq in
                                Text(freq.displayName).tag(freq)
                            }
                        }
                    } label: {
                        Label("Sync: \(frequency.shortName)", systemImage: "clock.arrow.circlepath")
                    }
                    Text("Last synced: \(record.lastSyncedAt.map(formattedDate) ?? "Never")")
                    Button {
                        Task { await syncNow() }
                    } label: {
                        Text(isSyncing ? "Syncing…" : "Sync Now")
                    }
                    .disabled(isSyncing)
                    if let syncMessage {
                        Text(syncMessage)
                    }
                    Divider()
                    Button {
                        showingQueue = true
                    } label: {
                        Label("Sync Queue", systemImage: "list.bullet.rectangle")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showingDeleteConfirm = true
                    } label: {
                        Label("Delete Connection", systemImage: "trash")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .task { load() }
        .onAppear { loadStats() }
        .onChange(of: isProviderSyncQueueActive) { wasActive, isActive in
            // The queue's own jobs are the source of truth for progress; once they drain,
            // pull the listing and the stats footer back in sync with what actually landed.
            if wasActive && !isActive {
                load()
                loadStats()
            }
        }
        .confirmationDialog("Delete this connection?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                viewModel.delete(record)
            }
        }
        .onChange(of: viewModel.providers.contains { $0.id == record.id }) { _, stillExists in
            if !stillExists { dismiss() }
        }
        .sheet(item: $showingFileInfo) { file in
            FileInfoSheet(file: file)
        }
        .sheet(isPresented: $isShowingPlayer) {
            RealPlayerView()
        }
        .sheet(isPresented: $showingQueue) {
            NavigationStack { SyncQueueView() }
        }
    }

    @ViewBuilder
    private func fileRow(_ file: CloudFile) -> some View {
        HStack {
            Button {
                Task { await play(file) }
            } label: {
                HStack {
                    Label(file.name, systemImage: "waveform")
                    Spacer()
                    if loadingFileID == file.id {
                        ProgressView().controlSize(.small)
                    } else if let sizeBytes = file.sizeBytes {
                        Text(Self.formattedSize(sizeBytes))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(loadingFileID != nil)

            Button {
                showingFileInfo = file
            } label: {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    /// Whether this connection has any not-yet-finished sync queue job — covers both a
    /// queued per-file import and a whole-bucket `syncNow()` run, since both now leave
    /// their in-flight files in the same `syncJobs` table. Read off the manager's SQL-backed
    /// set rather than `jobs`, which is only the visible page.
    private var isProviderSyncQueueActive: Bool {
        queueManager.activeProviderIDs.contains(record.id)
    }

    private var statsSummary: String {
        guard let stats, stats.count > 0 else { return "No episodes synced yet." }
        var text = "\(stats.count) episodes synced · \(ByteCountFormatter.string(fromByteCount: stats.totalBytes, countStyle: .file))"
        if stats.lostCount > 0 {
            text += " · \(stats.lostCount) missing since last sync"
        }
        return text
    }

    private func childPath(_ name: String) -> String {
        guard let folder, !folder.isEmpty else { return name }
        return folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }

    /// Draws this level from already-synced local metadata — browsing never touches the
    /// provider. The whole bucket is listed once when the connection is added
    /// (`SyncQueueManager.enqueueConnection`), and after that only an explicit "Sync Now"
    /// or a scheduled frequency goes back out for file headers, so opening a folder costs
    /// nothing and works offline.
    private func load() {
        defer { isLoadingListing = false }
        guard let listing = try? trackStore.directoryListing(providerID: record.id, pathPrefix: folder) else {
            errorMessage = "Couldn't read this folder's synced files."
            return
        }
        folders = listing.folders
        files = listing.tracks.map { track in
            CloudFile(
                id: track.filePath, name: (track.filePath as NSString).lastPathComponent, path: track.filePath,
                sizeBytes: track.sizeBytes, mimeType: nil, modifiedAt: track.remoteModifiedAt,
                contentHash: track.contentHash
            )
        }
    }

    private func loadStats() {
        stats = try? trackStore.stats(forProvider: record.id, pathPrefix: folder)
    }

    private func syncNow() async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            let result = try await SyncEngine().sync(providerRecord: record)
            syncMessage = "Added \(result.added), \(result.lost) missing, \(result.totalFiles) files found."
            record.lastSyncedAt = Date()
            // Anything new the sync just pulled in is now local, so redraw this level.
            load()
            loadStats()
        } catch {
            syncMessage = describeAWSError(error)
        }
    }

    private func formattedDate(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }

    /// Plays a file like any other synced episode — importing it first (and persisting
    /// that) if it isn't already known, rather than requiring a sync to happen first.
    private func play(_ file: CloudFile) async {
        guard let provider = try? ProviderManager.shared.provider(for: record) else {
            errorMessage = "Couldn't connect to this source."
            return
        }
        var track = try? trackStore.find(providerID: record.id, filePath: file.path)
        if track == nil {
            loadingFileID = file.id
            _ = try? await SyncEngine().importFileIfNeeded(file, providerRecord: record, provider: provider)
            loadingFileID = nil
            track = try? trackStore.find(providerID: record.id, filePath: file.path)
            loadStats()
        }
        guard let track else {
            errorMessage = "Couldn't load that file."
            return
        }
        let knownQueue = files.compactMap { try? trackStore.find(providerID: record.id, filePath: $0.path) }
        PlaybackEngine.shared.play(track: track, queue: knownQueue.isEmpty ? [track] : knownQueue)
        isShowingPlayer = true
    }

    static func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct FileInfoSheet: View {
    let file: CloudFile

    var body: some View {
        NavigationStack {
            List {
                LabeledContent("File", value: file.name)
                if let sizeBytes = file.sizeBytes {
                    LabeledContent("Size", value: RemoteBrowserView.formattedSize(sizeBytes))
                }
                if let modifiedAt = file.modifiedAt {
                    LabeledContent("Modified", value: modifiedAt.formatted())
                }
                Section {
                    Text("Tapping this file plays it directly — if it isn't already synced, it's imported first so future syncs recognize it.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Episode file")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}
