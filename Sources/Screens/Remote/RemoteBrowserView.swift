import SwiftUI

/// Real folder-style browsing over a remote source, one directory level at a time —
/// recurses by pushing itself with the tapped subfolder's path. There's no separate
/// detail screen: the root level (no folder) also carries the connection's sync
/// controls (frequency, last synced, sync now, delete) behind a single toolbar "More"
/// menu, plus a one-line storage-stats footer under the folder/file list. The global
/// sync queue itself is reached from `RemoteSectionView`, not from here. Each level
/// can also be synced on its own via "Sync This Folder", without pulling in the rest
/// of the bucket. Synced episodes are browsed/played from Home, not from here.
struct RemoteBrowserView: View {
    @State var record: ProviderRecord
    var folder: String?
    var title: String?
    var onDelete: (() -> Void)?

    @State private var folders: [String] = []
    @State private var files: [CloudFile] = []
    @State private var errorMessage: String?
    @State private var enqueueMessage: String?
    @State private var showingFileInfo: CloudFile?

    @State private var frequency: SyncFrequency
    @State private var isSyncing = false
    @State private var syncMessage: String?
    @State private var stats: TrackStore.ProviderStats?
    @State private var showingDeleteConfirm = false

    @Environment(\.dismiss) private var dismiss
    private let providerStore = ProviderStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)

    /// Sync controls/stats and delete only apply to the connection as a whole, so
    /// only show them at the top level, not on pushed subfolders.
    private var isRoot: Bool { folder == nil }

    init(record: ProviderRecord, folder: String? = nil, title: String? = nil, onDelete: (() -> Void)? = nil) {
        _record = State(initialValue: record)
        self.folder = folder
        self.title = title
        self.onDelete = onDelete
        _frequency = State(initialValue: SyncFrequency(minutes: record.syncFrequencyMinutes))
    }

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.orange)
            }
            if let enqueueMessage {
                Text(enqueueMessage).foregroundStyle(.secondary)
            }
            Section {
                ForEach(folders, id: \.self) { name in
                    NavigationLink {
                        RemoteBrowserView(record: record, folder: childPath(name), title: name)
                    } label: {
                        Label(name, systemImage: "folder.fill")
                    }
                }
                ForEach(files) { file in
                    Button {
                        showingFileInfo = file
                    } label: {
                        HStack {
                            Label(file.name, systemImage: "waveform")
                            Spacer()
                            if let sizeBytes = file.sizeBytes {
                                Text(Self.formattedSize(sizeBytes))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                // A compact stats line rather than its own section — it's a status readout,
                // not another navigable tier alongside the folders above it.
                if isRoot {
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
                    Button {
                        Task { await syncThisFolder() }
                    } label: {
                        Label("Sync This Folder", systemImage: "arrow.triangle.2.circlepath")
                    }
                    if isRoot {
                        Divider()
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
                        if onDelete != nil {
                            Divider()
                            Button(role: .destructive) {
                                showingDeleteConfirm = true
                            } label: {
                                Label("Delete Connection", systemImage: "trash")
                            }
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .task { await load() }
        .onAppear { if isRoot { loadStats() } }
        .confirmationDialog("Delete this connection?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                onDelete?()
                dismiss()
            }
        }
        .sheet(item: $showingFileInfo) { file in
            FileInfoSheet(file: file)
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
        stats = try? trackStore.stats(forProvider: record.id)
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

    /// Enqueues just the files directly in this folder (not subfolders) into the sync queue.
    /// The queue itself lives under Remote's global "Sync queue" line, not a sheet here.
    private func syncThisFolder() async {
        await SyncQueueManager.shared.enqueueFolder(providerID: record.id, folder: folder)
        enqueueMessage = "Added to sync queue."
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
                    Text("Would be imported as a new episode on next sync — its file hash is checked against local metadata first, so anything already known doesn't get rebuilt.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Episode file")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}
