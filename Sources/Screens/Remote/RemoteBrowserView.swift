import SwiftUI
import UniformTypeIdentifiers

/// Real folder-style browsing over a remote source, one directory level at a time —
/// recurses by pushing itself with the tapped subfolder's path. There's no separate
/// detail screen and no per-level distinction: every level carries the same "More" menu
/// (frequency, last synced, sync now, sync queue, delete) and the same one-line
/// storage-stats footer, scoped to that folder.
///
/// The listing is live: every level asks the provider for that one folder
/// (`listDirectory`, a delimited S3 request), so what's on screen is what's in the bucket
/// right now — files added since the last sync included. Only when that call can't be made
/// (offline, or it errors) does it fall back to already-synced local metadata, and says so.
/// The stats footer stays local, since it's reporting what this device has synced.
///
/// A bucket holds whatever the user keeps there, so only audio is treated as an episode
/// (`FileKind`). Tapping an episode plays it; tapping a transcript or any other text file
/// shows its contents; anything else offers its details and nothing more.
struct RemoteBrowserView: View {
    @State var record: ProviderRecord
    var folder: String?
    var title: String?
    @ObservedObject var viewModel: SettingsViewModel

    @State private var folders: [String] = []
    @State private var files: [CloudFile] = []
    @State private var isLoadingListing = true
    @State private var errorMessage: String?
    @State private var isShowingSyncedFallback = false
    @State private var showingFileInfo: CloudFile?
    @State private var previewingFile: CloudFile?
    @State private var loadingFileID: String?
    @State private var showingQueue = false
    @State private var showingUploadPicker = false
    @State private var isUploading = false
    @State private var uploadMessage: String?
    @State private var canUpload = false

    @State private var frequency: SyncFrequency
    @State private var isSyncing = false
    @State private var syncMessage: String?
    @State private var stats: TrackStore.ProviderStats?
    @State private var showingDeleteConfirm = false

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var queueManager = SyncQueueManager.shared
    private let providerStore = ProviderStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)

    /// A file to scroll to and mark on arrival — set when the browser was opened *at* a
    /// particular episode rather than to browse.
    var highlight: String?

    init(
        record: ProviderRecord, folder: String? = nil, title: String? = nil,
        highlight: String? = nil, viewModel: SettingsViewModel
    ) {
        self.highlight = highlight
        _record = State(initialValue: record)
        self.folder = folder
        self.title = title
        self.viewModel = viewModel
        _frequency = State(initialValue: SyncFrequency(minutes: record.syncFrequencyMinutes))
    }

    var body: some View {
        ScrollViewReader { proxy in
            list.scrollHandle(
                ids: folders.map(AnyHashable.init) + fileGroups.map { AnyHashable($0.file.path) },
                proxy: proxy,
                label: { index in
                    let names = folders.map { ($0 as NSString).lastPathComponent }
                        + fileGroups.map(\.file.name)
                    return index < names.count ? names[index] : ""
                }
            )
        }
    }

    private var list: some View {
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
                    ForEach(folders, id: \.self) { path in
                        let name = (path as NSString).lastPathComponent
                        NavigationLink {
                            RemoteBrowserView(record: record, folder: path, title: name, viewModel: viewModel)
                        } label: {
                            Label(name, systemImage: "folder.fill")
                        }
                    }
                    ForEach(fileGroups) { group in
                        fileRow(group)
                    }
                    if folders.isEmpty, files.isEmpty {
                        Text(isShowingSyncedFallback
                             ? "Couldn't reach this source, and nothing here has been synced yet."
                             : "This folder is empty.")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                // A compact stats line rather than its own section — it's a status readout,
                // not another navigable tier alongside the folders above it. The syncing
                // indicator rides on the same line rather than its own row, since it's just
                // a transient qualifier on those same numbers.
                if !isLoadingListing {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Text(isShowingSyncedFallback ? "Last synced · \(statsSummary)" : statsSummary)
                                .font(.caption)
                            if isSyncing || isProviderSyncQueueActive {
                                // Tappable: "Syncing…" is the moment you want to see what's
                                // actually being worked, and the queue is otherwise two taps
                                // away in the More menu.
                                Button { showingQueue = true } label: {
                                    HStack(spacing: 4) {
                                        ProgressView().controlSize(.small)
                                        Text("Syncing…").font(.caption)
                                    }
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                            }
                            if isUploading {
                                ProgressView().controlSize(.small)
                                Text("Uploading…").font(.caption)
                            }
                        }
                        if let uploadMessage {
                            Text(uploadMessage).font(.caption)
                        }
                        // Under the stats rather than in the empty state: a folder with
                        // forty episodes in it is also where you'd want to add the
                        // forty-first, and the menu that does it is three dots in a corner.
                        if canUpload {
                            Text("To add podcasts, open the ⋯ menu and pick Upload from Files — they go into this folder and into your library.")
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        // Room to scroll the stats line clear of the docked now-playing bar. As scroll
        // content rather than row padding: padding the footer stretched the *row*, and a
        // list draws a separator at the bottom of a row — which put a hairline across
        // empty space below the last folder.
        .contentMargins(.bottom, 72, for: .scrollContent)
        .listSectionSeparator(.hidden, edges: .bottom)
        .navigationTitle(title ?? record.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // Sync Now and the frequency picker used to live here. They're
                    // decisions about a *connection*, not about the folder you happen to
                    // have open, so they sit on the source's own row in the Remote
                    // section — visible without opening anything.
                    Text("Last synced: \(record.lastSyncedAt.map(formattedDate) ?? "Never")")
                    Button {
                        showingQueue = true
                    } label: {
                        Label("Queue", systemImage: "list.bullet.rectangle")
                    }
                    // Uploading, not importing-in-place: the episode goes into the folder
                    // being browsed, so it's backed up and on every other device, and the
                    // library picks it up from there like anything else in the bucket.
                    if canUpload {
                        Button {
                            showingUploadPicker = true
                        } label: {
                            Label("Upload from Files", systemImage: "square.and.arrow.up")
                        }
                        .disabled(isUploading)
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
        .onChange(of: isProviderSyncQueueActive) { wasActive, isActive in
            // Only the footer's synced numbers depend on the queue — the listing above it
            // is live and owes the queue nothing.
            if wasActive && !isActive { loadStats() }
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
        .sheet(item: $previewingFile) { file in
            FilePreviewSheet(file: file, record: record)
        }
        .sheet(isPresented: $showingQueue) {
            NavigationStack { SyncQueueView() }
        }
        .fileImporter(
            isPresented: $showingUploadPicker,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            Task { await upload(result) }
        }
    }

    /// Sidecars fold into a caption under the episode they belong to rather than standing
    /// as rows of their own — a folder of 37 episodes lists 37 rows instead of ~150,
    /// and the caption turns what was noise into an answer: which episodes have a
    /// transcript and which don't.
    @ViewBuilder
    private func fileRow(_ group: RemoteFileGroup) -> some View {
        let file = group.file
        let kind = FileKind(path: file.path)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Button {
                    open(file, kind: kind)
                } label: {
                    HStack {
                        Label(file.name, systemImage: kind.symbol)
                            // Only an episode reads as the main event; everything else is
                            // context, not something the user came here to tap.
                            .foregroundStyle(kind.isPlayable ? .primary : .secondary)
                            .fontWeight(file.path == highlight ? .semibold : .regular)
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
            sidecarCaption(group)
        }
        // Tinted, not selected: the row the File card sent you to, so you can see which
        // of forty near-identical filenames was meant without it looking tappable-er.
        .listRowBackground(
            file.path == highlight ? Color.accentColor.opacity(0.12) : Color.clear
        )
        .id(file.path)
    }

    /// Each extension is its own small button, so opening a transcript still works — that
    /// was a tap on its own row before this folded them in.
    @ViewBuilder
    private func sidecarCaption(_ group: RemoteFileGroup) -> some View {
        if !group.sidecars.isEmpty {
            HStack(spacing: 6) {
                ForEach(group.sidecars) { sidecar in
                    Button {
                        open(sidecar, kind: FileKind(path: sidecar.path))
                    } label: {
                        Text(Self.sidecarLabel(sidecar))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .overlay {
                                Capsule().strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1)
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(loadingFileID != nil)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 28)
            .padding(.vertical, 2)
        } else if showsMissingTranscripts, FileKind(path: group.file.path).isPlayable {
            // Only worth saying where some episodes here do have one. In a folder with no
            // transcripts at all, the absence is already obvious and this would just be
            // the same line under every row.
            Text("no transcript")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.leading, 28)
        }
    }

    /// What distinguishes one sidecar from another is its extension — and, when the
    /// basename carries more than the episode's, the bit in between: `ep-01.zh-CN.vtt`
    /// reads as `zh-CN.vtt`, which is the thing worth knowing when there are two.
    private static func sidecarLabel(_ file: CloudFile) -> String {
        let name = (file.name as NSString).deletingPathExtension
        let ext = (file.name as NSString).pathExtension.lowercased()
        let qualifier = (name as NSString).pathExtension
        return qualifier.isEmpty ? ext : "\(qualifier).\(ext)"
    }

    private var fileGroups: [RemoteFileGroup] { RemoteFileGroup.group(files) }

    /// True once at least one episode in this folder has a transcript beside it.
    private var showsMissingTranscripts: Bool {
        fileGroups.contains { $0.hasTranscript }
    }

    /// Whether this connection has any not-yet-finished sync queue job — covers both a
    /// queued per-file import and a whole-bucket `syncNow()` run, since both now leave
    /// their in-flight files in the same `syncJobs` table. Read off the manager's SQL-backed
    /// set rather than `jobs`, which is only the visible page.
    private var isProviderSyncQueueActive: Bool {
        queueManager.activeProviderIDs.contains(record.id)
    }

    /// Leads with what's actually in the folder right now, because that's what the list
    /// above it is showing; what this device has synced is the follow-up, not the headline.
    /// Reading "No episodes synced yet" under a list of files was the old version's fault.
    private var statsSummary: String {
        var parts: [String] = []
        if !files.isEmpty {
            let bytes = files.compactMap(\.sizeBytes).reduce(Int64(0), +)
            // Counted the way the list above reads: one per episode, with the sidecars
            // folded in as a qualifier. "148 files" in a 37-episode folder was true and
            // useless.
            let episodes = files.filter { FileKind(path: $0.path).isPlayable }.count
            let sidecars = files.count - episodes
            var here = episodes > 0
                ? "\(episodes) episode\(episodes == 1 ? "" : "s") here"
                : "\(files.count) file\(files.count == 1 ? "" : "s") here"
            if episodes > 0, sidecars > 0 { here += " · \(sidecars) sidecar\(sidecars == 1 ? "" : "s")" }
            if bytes > 0 { here += " · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))" }
            parts.append(here)
        }
        if !folders.isEmpty {
            parts.append("\(folders.count) folder\(folders.count == 1 ? "" : "s")")
        }
        if let stats, stats.count > 0 {
            parts.append("\(stats.count) synced")
            if stats.lostCount > 0 { parts.append("\(stats.lostCount) missing since last sync") }
        }
        return parts.isEmpty ? "Nothing in this folder." : parts.joined(separator: " · ")
    }

    /// One listing request for this one folder, straight to the provider. Deliberately
    /// nothing to do with syncing or the queue: listing keys is cheap and immediate, while
    /// the queue is about pulling each file's metadata into the library — a different job
    /// with a different cost. Falls back to synced local rows only when the provider can't
    /// be reached.
    private func load() async {
        isLoadingListing = true
        defer { isLoadingListing = false }
        do {
            let provider = try ProviderManager.shared.provider(for: record)
            let listing = try await provider.listDirectory(atFolder: folder)
            folders = listing.folders
            files = listing.files
            // Only offered where a write would actually land: a read-only key pair, or a
            // source with no folder to write into, doesn't get the menu item.
            canUpload = provider.isWritable
            isShowingSyncedFallback = false
            errorMessage = nil
            return
        } catch {
            // Worth showing: at this level a failure is a credentials/permissions problem
            // far more often than an empty folder, and silently falling back to local rows
            // made the two look identical.
            errorMessage = NetworkMonitor.shared.isConnected
                ? "Couldn't list this folder: \(describeCloudError(error))"
                : "You're offline — showing what's already synced."
        }
        loadSynced()
    }

    private func loadSynced() {
        isShowingSyncedFallback = true
        guard let listing = try? trackStore.directoryListing(providerID: record.id, pathPrefix: folder ?? rootFolder) else {
            folders = []
            files = []
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
        stats = try? trackStore.stats(forProvider: record.id, pathPrefix: folder ?? rootFolder)
    }

    private var rootFolder: String? { ProviderManager.shared.rootFolder(for: record) }

    private func syncNow() async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            syncMessage = try await SyncQueueManager.shared.sync(providerRecord: record).summary
            record.lastSyncedAt = Date()
            // Anything new the sync just pulled in is now local, so redraw this level.
            await load()
            loadStats()
        } catch {
            syncMessage = describeCloudError(error)
        }
    }

    private func formattedDate(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }

    /// Plays a file like any other synced episode — importing it first (and persisting
    /// that) if it isn't already known, rather than requiring a sync to happen first.
    /// Audio plays, text opens, everything else can only be inspected — this app doesn't
    /// pretend a backup or a cover image is an episode.
    private func open(_ file: CloudFile, kind: FileKind) {
        if kind.isPlayable {
            Task { await play(file) }
        } else if kind.isReadableAsText {
            previewingFile = file
        } else {
            showingFileInfo = file
        }
    }

    /// Writes the picked episodes into the folder on screen and queues each one, then
    /// redraws — the new rows come from the bucket's own listing, so what's shown is what
    /// actually landed.
    private func upload(_ result: Result<[URL], Error>) async {
        guard case .success(let urls) = result else {
            if case .failure(let error) = result { uploadMessage = error.localizedDescription }
            return
        }
        guard let provider = try? ProviderManager.shared.provider(for: record) else {
            uploadMessage = "Couldn't connect to this source."
            return
        }
        isUploading = true
        defer { isUploading = false }
        let outcome = await EpisodeUpload(
            provider: provider, providerID: record.id, folder: folder
        ).run(urls, avoiding: Set(files.map(\.name) + folders.map { ($0 as NSString).lastPathComponent }))
        uploadMessage = outcome.summary
        await load()
        loadStats()
    }

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
        let knownQueue = files
            .filter { FileKind(path: $0.path).isPlayable }
            .compactMap { try? trackStore.find(providerID: record.id, filePath: $0.path) }
        PlaybackEngine.shared.open(track: track, queue: knownQueue.isEmpty ? [track] : knownQueue)
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
                LabeledContent("Kind", value: FileKind(path: file.path).displayName)
                Section {
                    Text(FileKind(path: file.path).isPlayable
                         ? "Tapping this file plays it directly — if it isn't already synced, it's imported first so future syncs recognize it."
                         : "Not an audio file, so it's never synced as an episode. It's listed because it's in this folder.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(FileKind(path: file.path).displayName)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}
