import SwiftUI

/// Overall sync queue across every provider — pause/resume, clear, and tune concurrency
/// live on the "Queue" header itself rather than as a separate settings block, since
/// they act on the same list right below them.
struct SyncQueueView: View {
    @ObservedObject private var manager = SyncQueueManager.shared

    var body: some View {
        List {
            Section {
                if manager.jobs.isEmpty {
                    Text("Nothing queued. Sync a folder from a remote source to add files here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.jobs) { job in
                        SyncJobRow(job: job, providerLabel: manager.providerLabels[job.providerID]) {
                            manager.retry(job)
                        }
                    }
                    if manager.hasMore {
                        Button {
                            manager.loadMore()
                        } label: {
                            Text("Load \(manager.totalCount - manager.jobs.count) more…")
                                .font(.subheadline)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Queue (\(manager.totalCount))")
                    Spacer()
                    Button {
                        manager.setPaused(!manager.isPaused)
                    } label: {
                        Image(systemName: manager.isPaused ? "play.fill" : "pause.fill")
                    }
                    Menu {
                        Stepper("Speed: \(manager.concurrency) at a time", value: $manager.concurrency, in: 1...8)
                        Divider()
                        Button("Clear Synced") { manager.clearSynced() }
                        Button("Clear Queue", role: .destructive) { manager.clearQueue() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                .textCase(nil)
            }
        }
        .navigationTitle("Sync Queue")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { manager.refresh() }
    }
}

private struct SyncJobRow: View {
    let job: SyncJob
    let providerLabel: String?
    let onRetry: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.displayName).font(.subheadline).lineLimit(1)
                if let providerLabel {
                    Text(providerLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                if job.status == .failed, let errorMessage = job.errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.orange).lineLimit(1)
                }
            }
            Spacer()
            statusView
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch job.status {
        case .pending:
            Text("Waiting").font(.caption).foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Button(action: onRetry) {
                Label("Retry", systemImage: "arrow.clockwise.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
        }
    }
}
