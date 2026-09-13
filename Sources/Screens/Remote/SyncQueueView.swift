import SwiftUI

/// Overall sync queue across every provider — pause/resume, clear, and tune concurrency.
struct SyncQueueView: View {
    @ObservedObject private var manager = SyncQueueManager.shared

    var body: some View {
        List {
            Section {
                Toggle("Paused", isOn: Binding(
                    get: { manager.isPaused },
                    set: { manager.setPaused($0) }
                ))
                Stepper("Speed: \(manager.concurrency) at a time", value: $manager.concurrency, in: 1...8)
                Button("Clear Queue", role: .destructive) { manager.clearQueue() }
            }

            if manager.jobs.isEmpty {
                Section {
                    Text("Nothing queued. Sync a folder from a remote source to add files here.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Queue (\(manager.jobs.count))") {
                    ForEach(manager.jobs) { job in
                        SyncJobRow(job: job)
                    }
                }
            }
        }
        .navigationTitle("Sync Queue")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { manager.refresh() }
    }
}

private struct SyncJobRow: View {
    let job: SyncJob

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.displayName).font(.subheadline).lineLimit(1)
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
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        }
    }
}
