import SwiftUI

/// Overall sync queue across every provider — pause/resume, clear, and tune concurrency
/// live on the "Queue" header itself rather than as a separate settings block, since
/// they act on the same list right below them.
struct SyncQueueView: View {
    @ObservedObject private var manager = SyncQueueManager.shared

    var body: some View {
        List {
            if manager.isPaused || manager.isFull || manager.notice != nil {
                Section {
                    if manager.isPaused {
                        Label(
                            "Paused. Nothing is being added to the queue and nothing is being processed.",
                            systemImage: "pause.circle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    } else if manager.isFull {
                        Label(
                            "Queue full (\(manager.capacity)). Files past this point come in as room frees up.",
                            systemImage: "exclamationmark.circle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    }
                    if let notice = manager.notice {
                        Text(notice).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
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
                    // Waiting-vs-ceiling rather than the total: the cap is on unfinished
                    // work, and a pile of finished rows shouldn't read as nearly full.
                    Text("Queue (\(manager.activeCount)/\(manager.capacity))")
                    Spacer()
                    Button {
                        manager.setPaused(!manager.isPaused)
                    } label: {
                        Label(manager.isPaused ? "Resume" : "Pause", systemImage: manager.isPaused ? "play.fill" : "pause.fill")
                            .labelStyle(.iconOnly)
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
        .navigationTitle("Queue")
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
            HStack(spacing: 6) {
                Text((job.stage ?? .queued).displayName).font(.caption).foregroundStyle(.secondary)
                ProgressView().controlSize(.small)
            }
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
