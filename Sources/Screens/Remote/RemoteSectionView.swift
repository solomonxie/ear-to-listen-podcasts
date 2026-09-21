import SwiftUI

/// Embeddable "Remote" section for the single-page root layout — real cloud sources,
/// each linking to `RemoteBrowserView` for browsing/syncing/playing. "Continue
/// Listening" lives at the top of Home instead of here, since it's about the library
/// as a whole, not specifically about remote connections.
struct RemoteSectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var syncQueue = SyncQueueManager.shared
    @ObservedObject private var autoBackup = AutoBackup.shared
    @State private var showingAddSource = false
    @State private var showingSyncQueue = false
    @State private var syncingProviderIDs: Set<String> = []
    @State private var syncMessages: [String: String] = [:]
    @State private var openFrequency: String?

    private let providerStore = ProviderStore(dbQueue: DatabaseManager.shared.dbQueue)

    /// Every bucket, whichever cloud it's in — local files and the demo content have
    /// their own homes in Settings.
    private var remoteProviders: [ProviderRecord] {
        viewModel.providers.filter { $0.cloudKind != nil }
    }

    var body: some View {
        // Rows inherit `.sectionRow()`; headings and hints opt out explicitly.
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Remote").sectionTitle()
                Spacer()
                Button { showingAddSource = true } label: { Image(systemName: "plus.circle.fill") }
            }
            .padding(.horizontal)

            // Syncing only reads file listings/metadata — the audio itself downloads on
            // demand when you actually listen, not during a sync.
            Text("Sync only fetches metadata — episodes download when you listen.")
                .sectionHint()
                .padding(.horizontal)

            if remoteProviders.isEmpty {
                Text("No remote sources yet. Add a bucket — S3, Tencent COS, Alibaba OSS, Azure or Google Cloud — to browse and sync episodes from.")
                    .sectionHint()
                    .padding(.horizontal)
            } else {
                VStack(spacing: 0) {
                    ForEach(remoteProviders) { record in
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
                        if record.id != remoteProviders.last?.id {
                            Divider().padding(.leading, 68)
                        }
                    }
                }
                .padding(.horizontal)

            }
        }
        .sheet(isPresented: $showingAddSource) {
            NavigationStack { AddCloudSourceView(viewModel: viewModel) }
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
        // Listing is quick now, the importing isn't — so the spinner follows the queue,
        // not just this button's own call. Only the listing disables the button though:
        // a bucket that stopped at the ceiling has to stay tappable while the queue works.
        let isListing = syncingProviderIDs.contains(record.id)
        let isSyncing = isListing || syncQueue.activeProviderIDs.contains(record.id)
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
                .disabled(isListing)

                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        openFrequency = openFrequency == record.id ? nil : record.id
                    }
                } label: {
                    Label(SyncFrequency(minutes: record.syncFrequencyMinutes).buttonLabel,
                          systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                // Same row as the two controls that feed it. The count is global — one
                // queue serves every connection — and so is the screen it opens.
                Button { showingSyncQueue = true } label: {
                    Label("Queue (\(syncQueue.activeCount, format: .number.grouping(.never)))",
                          systemImage: syncQueue.isPaused ? "pause.circle" : "tray.full")
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

            // Unfolds under the pill that opened it rather than floating a menu over the
            // row — the connection being changed stays on screen.
            if openFrequency == record.id {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(SyncFrequency.allCases) { option in
                        Button {
                            frequency(for: record).wrappedValue = option
                            withAnimation(.easeOut(duration: 0.18)) { openFrequency = nil }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .opacity(option.minutes == record.syncFrequencyMinutes ? 1 : 0)
                                Text(option.displayName).font(.footnote)
                                Spacer()
                            }
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 4)
            }

            // A row of its own with an ordinary switch: pressed into the pill row beside
            // two buttons, an on/off setting read as a third button.
            if record.isActive {
                Toggle("Auto sync app data to this bucket", isOn: $autoBackup.isEnabled)
                    .font(.subheadline)
                Text(appDataHint).sectionHint()
            }
            if let message = syncMessages[record.id] {
                Text(message).sectionHint()
            }
        }
    }

    /// An upload nobody can see is just an unexplained network bill, so say what it does
    /// and when it last did it.
    private var appDataHint: LocalizedStringKey {
        guard autoBackup.isEnabled else {
            return "App data isn't kept here — it stays on this device."
        }
        if let error = autoBackup.lastError {
            return "Last app-data backup failed: \(error)"
        }
        guard let lastBackupAt = autoBackup.lastBackupAt else {
            return "One zip of your playlists, edits and transcripts. Never your episode audio."
        }
        return "Replaced when it changes. Last: \(lastBackupAt.formatted(date: .abbreviated, time: .shortened))."
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
            syncMessages[record.id] = try await syncQueue.sync(providerRecord: record).summary
            viewModel.load()
            syncQueue.refresh()
        } catch {
            syncMessages[record.id] = describeCloudError(error)
        }
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
                // Which cloud, not just "a cloud": five backends look identical in a list
                // otherwise, and the folder path below only names the bucket.
                .overlay {
                    Text(record.cloudKind?.shortName ?? "")
                        .font(.caption2.weight(.bold))
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(.white)
                }
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
        .onAppear { path = ProviderManager.shared.displayPath(for: record) }
    }
}
