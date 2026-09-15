import SwiftUI

/// Real folder-style browsing over a remote source, one directory level at a time —
/// recurses by pushing itself with the tapped subfolder's path. There's no separate
/// detail screen and no per-level distinction: every level carries the same "More" menu
/// (frequency, last synced, sync now, sync queue, delete) and the same one-line
/// storage-stats footer (scoped to that folder, from already-collected metadata — not a
/// live rescan). The whole connection is queued for syncing right when it's added
/// (`AddS3ProviderView`/`SyncQueueManager.enqueueConnection`), so there's no manual
/// per-folder "sync this" action here. Tapping a file plays it directly — importing it
/// first if it isn't already known — same as tapping any other synced episode.
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
                // not another navigable tier alongside the folders above it.
                if !isLoadingListing {
                    Text(statsSummary).font(.caption)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(title ?? record.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sync frequency", selection: $frequency) {
                        ForEach(SyncFrequency.allCases) { freq in
                            Text(freq.displayName).tag(freq)
                        }
                    }
                    .onChange(of: frequency) { _, newValue in
                        try? providerStore.updateSyncFrequency(id: record.id, minutes: newValue.minutes)
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
        .task { await load() }
        .onAppear { loadStats() }
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

    private func load() async {
        defer { isLoadingListing = false }
        guard let provider = try? ProviderManager.shared.provider(for: record) else {
            errorMessage = "Couldn't connect to this source."
            return
        }
        guard let listing = try? await provider.listDirectory(atFolder: folder) else {
            errorMessage = "Couldn't list files."
            return
        }
        folders = listing.folders
        files = listing.files
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
