import SwiftUI

/// Every provider's sync work in one list: imports, bucket scans and tag reads. A status
/// card on top (state, what's left, pause, speed); the list below, with its two clean-up
/// actions on its own header.
struct SyncQueueView: View {
    @ObservedObject private var manager = SyncQueueManager.shared
    @State private var confirmingRemoveAll = false

    var body: some View {
        List {
            Section {
                statusCard
                HStack {
                    Label("Speed", systemImage: "gauge.with.dots.needle.33percent")
                    Spacer()
                    Text("\(manager.concurrency) at a time").foregroundStyle(.secondary).monospacedDigit()
                    Stepper("Speed", value: $manager.concurrency, in: 1...8).labelsHidden()
                }
                if let notice = manager.notice {
                    Text(notice).font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section {
                if manager.jobs.isEmpty {
                    Text("Nothing queued. Sync a folder, or upload episodes to one, to add files here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.jobs) { job in
                        SyncJobRow(job: job, providerLabel: manager.providerLabels[job.providerID]) {
                            manager.retry(job)
                        }
                    }
                }
            } header: {
                HStack(spacing: 16) {
                    Text("Latest \(manager.jobs.count)")
                    Spacer()
                    Button("Remove done") { manager.clearSynced() }
                    Button("Remove all", role: .destructive) { confirmingRemoveAll = true }
                        .foregroundStyle(.red)
                }
                .font(.footnote)
                .textCase(nil)
                .disabled(manager.jobs.isEmpty)
            }
        }
        .navigationTitle("Queue")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove every row from the queue?", isPresented: $confirmingRemoveAll, titleVisibility: .visible) {
            Button("Remove all", role: .destructive) { manager.clearQueue() }
        } message: {
            Text("Entries still waiting for their tags come back as room frees up. Pause first to stop everything.")
        }
        .onAppear { manager.refresh() }
    }

    private var state: (title: String, symbol: String, tint: Color) {
        if manager.isPaused { return ("Paused", "pause.circle.fill", .orange) }
        if manager.activeCount > 0 { return ("Syncing", "arrow.triangle.2.circlepath.circle.fill", .accentColor) }
        return ("Up to date", "checkmark.circle.fill", .green)
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: state.symbol)
                .font(.title)
                .foregroundStyle(state.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title).font(.headline)
                Text(summary).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                manager.setPaused(!manager.isPaused)
            } label: {
                Image(systemName: manager.isPaused ? "play.fill" : "pause.fill")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.accentColor.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel(manager.isPaused ? "Resume" : "Pause")
        }
        .padding(.vertical, 4)
    }

    private var summary: String {
        var parts: [String] = []
        parts.append("\(manager.activeCount) in queue")
        if manager.tagsRemaining > 0 { parts.append("\(manager.tagsRemaining) awaiting tags") }
        return parts.joined(separator: " · ")
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

