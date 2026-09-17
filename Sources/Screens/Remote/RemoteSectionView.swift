import SwiftUI

/// Embeddable "Remote" section for the single-page root layout — real S3 sources,
/// each linking to `RemoteBrowserView` for browsing/syncing/playing. "Continue
/// Listening" lives at the top of Home instead of here, since it's about the library
/// as a whole, not specifically about remote connections.
struct RemoteSectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var syncQueue = SyncQueueManager.shared
    @State private var showingAddS3 = false
    @State private var showingSyncQueue = false
    @State private var syncingProviderIDs: Set<String> = []
    @State private var syncMessages: [String: String] = [:]

    private let providerStore = ProviderStore(dbQueue: DatabaseManager.shared.dbQueue)

    private var s3Providers: [ProviderRecord] {
        viewModel.providers.filter { $0.type == S3Provider.providerType }
    }

    var body: some View {
        // Rows inherit `.sectionRow()`; headings and hints opt out explicitly.
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Remote").sectionTitle()
                Spacer()
                Button { showingAddS3 = true } label: { Image(systemName: "plus.circle.fill") }
            }
            .padding(.horizontal)

            // Syncing only reads file listings/metadata — the audio itself downloads on
            // demand when you actually listen, not during a sync.
            Text("Sync only fetches metadata — episodes download when you listen.")
                .sectionHint()
                .padding(.horizontal)

            if s3Providers.isEmpty {
                Text("No remote sources yet. Add an S3 bucket to browse and sync episodes from.")
                    .sectionHint()
                    .padding(.horizontal)
            } else {
                VStack(spacing: 0) {
                    ForEach(s3Providers) { record in
                        VStack(alignment: .leading, spacing: 8) {
                            NavigationLink {
                                RemoteBrowserView(record: record, viewModel: viewModel)
                            } label: {
                                RemoteSourceRow(record: record)
                            }
                            .buttonStyle(.plain)
                            // Deleting lives in the bucket's own settings menu (inside
                            // RemoteBrowserView) instead of a second tap target right next
                            // to the disclosure chevron, where it's too easy to hit by mistake.
                            .contextMenu {
                                Button(role: .destructive) {
                                    viewModel.delete(record)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            syncControls(for: record)
                        }
                        .padding(.bottom, 6)
                        if record.id != s3Providers.last?.id {
                            Divider().padding(.leading, 68)
                        }
                    }
                }
                .padding(.horizontal)

                // The sync queue is global across every connection, not per-bucket, so its
                // status lives here once rather than behind each bucket's own menu.
                Button { showingSyncQueue = true } label: {
                    HStack {
                        Text(syncQueueSummary)
                        Image(systemName: "chevron.right")
                    }
                    .sectionHint()
                }
                .padding(.horizontal)
            }
        }
        .sheet(isPresented: $showingAddS3) {
            NavigationStack { AddS3ProviderView(viewModel: viewModel) }
        }
        .sheet(isPresented: $showingSyncQueue) {
            NavigationStack { SyncQueueView() }
        }
        .sectionRow()
        .onAppear {
            syncQueue.refresh()
        }
    }

    /// How often a source syncs, and syncing it now, sit on the source itself rather than
    /// inside the folder browser it opens. Both are things you decide *about* a connection
    /// while looking at your list of connections — nothing about them needs a folder to be
    /// open first, and burying them two taps deep made them feel like advanced settings.
    @ViewBuilder
    private func syncControls(for record: ProviderRecord) -> some View {
        let isSyncing = syncingProviderIDs.contains(record.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    Task { await syncNow(record) }
                } label: {
                    HStack(spacing: 5) {
                        // A spinner rather than a third word: "Syncing…" and "Sync Now"
                        // are different widths, and a button that resizes as you press it
                        // shoves whatever is beside it sideways.
                        if isSyncing {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text(isSyncing ? "Syncing" : "Sync Now")
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isSyncing)

                Menu {
                    Picker("Sync frequency", selection: frequency(for: record)) {
                        ForEach(SyncFrequency.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                } label: {
                    Label(SyncFrequency(minutes: record.syncFrequencyMinutes).shortName,
                          systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer(minLength: 0)
            }
            // Both labels are single-line and sized to their text, so neither wraps to a
            // second line inside its own pill.
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)

            if let message = syncMessages[record.id] {
                Text(message).sectionHint()
            }
        }
    }

    /// Persisting happens in the setter: an `onChange` on a view inside a menu only fires
    /// while that menu is still open.
    private func frequency(for record: ProviderRecord) -> Binding<SyncFrequency> {
        Binding(
            get: { SyncFrequency(minutes: record.syncFrequencyMinutes) },
            set: { newValue in
                try? providerStore.updateSyncFrequency(id: record.id, minutes: newValue.minutes)
                viewModel.load()
            }
        )
    }

    private func syncNow(_ record: ProviderRecord) async {
        syncingProviderIDs.insert(record.id)
        defer { syncingProviderIDs.remove(record.id) }
        do {
            let result = try await SyncEngine().sync(providerRecord: record)
            var message = "Added \(result.added), \(result.lost) missing, \(result.totalFiles) files found."
            if result.stoppedAtQueueLimit {
                message += " Stopped at the queue limit — sync again to carry on."
            }
            syncMessages[record.id] = message
            viewModel.load()
            syncQueue.refresh()
        } catch {
            syncMessages[record.id] = describeAWSError(error)
        }
    }

    private var syncQueueSummary: String {
        // Counted in SQL, not off `jobs` — that's only the visible page.
        let pending = syncQueue.activeCount
        guard pending > 0 else { return "Sync queue: idle" }
        let state = syncQueue.isPaused ? "paused" : "\(syncQueue.concurrency) at a time"
        return "Sync queue: \(pending) pending · \(state)"
    }
}

private struct RemoteSourceRow: View {
    let record: ProviderRecord
    @State private var path: String?

    /// Whether it's on, and when it last ran, on one line — the controls below this row
    /// need the width more than a second status line does.
    private var status: String {
        let state = record.isActive ? "Active" : "Inactive"
        guard let lastSyncedAt = record.lastSyncedAt else { return "\(state) · never synced" }
        return "\(state) · synced \(lastSyncedAt.formatted(.relative(presentation: .named)))"
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.gradient)
                .frame(width: 44, height: 44)
                .overlay { Image(systemName: "cloud.fill").foregroundStyle(.white) }
            VStack(alignment: .leading, spacing: 2) {
                Text(record.label).font(.subheadline.weight(.semibold))
                // Lets two connections to the same bucket (different folders) be told apart.
                if let path {
                    Text(path).sectionRowSecondary()
                }
                Text(status)
                    .sectionRowSecondary()
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onAppear { path = ProviderManager.shared.s3DisplayPath(for: record) }
    }
}
