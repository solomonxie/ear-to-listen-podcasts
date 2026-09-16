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

            if s3Providers.isEmpty {
                Text("No remote sources yet. Add an S3 bucket to browse and sync episodes from.")
                    .sectionHint()
                    .padding(.horizontal)
            } else {
                VStack(spacing: 0) {
                    ForEach(s3Providers) { record in
                        HStack(spacing: 4) {
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
                        }
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

    private var syncQueueSummary: String {
        let pending = syncQueue.jobs.filter { $0.status == .pending || $0.status == .running }.count
        guard pending > 0 else { return "Sync queue: idle" }
        let state = syncQueue.isPaused ? "paused" : "\(syncQueue.concurrency) at a time"
        return "Sync queue: \(pending) pending · \(state)"
    }
}

private struct RemoteSourceRow: View {
    let record: ProviderRecord
    @State private var path: String?

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.gradient)
                .frame(width: 44, height: 44)
                .overlay { Image(systemName: "cloud.fill").foregroundStyle(.white) }
            VStack(alignment: .leading, spacing: 2) {
                Text(record.label).font(.subheadline.weight(.semibold))
                // Lets two connections to the same bucket (different prefixes) be told apart.
                if let path {
                    Text(path).sectionRowSecondary()
                }
                Text(record.isActive ? "Active" : "Inactive")
                    .sectionRowSecondary()
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onAppear { path = ProviderManager.shared.s3DisplayPath(for: record) }
    }
}
