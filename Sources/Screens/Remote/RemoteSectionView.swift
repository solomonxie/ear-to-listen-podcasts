import SwiftUI

/// Embeddable "Remote" section for the single-page root layout — real S3 sources,
/// each linking to `RemoteSourceDetailView` for sync controls and storage stats.
struct RemoteSectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showingAddS3 = false
    @State private var recentTracks: [Track] = []
    @State private var isShowingPlayer = false

    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)

    private var s3Providers: [ProviderRecord] {
        viewModel.providers.filter { $0.type == S3Provider.providerType }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !recentTracks.isEmpty {
                Text("Continue Listening").font(.title3.bold()).padding(.horizontal)
                VStack(spacing: 0) {
                    ForEach(recentTracks) { track in
                        Button {
                            PlaybackEngine.shared.play(track: track)
                            isShowingPlayer = true
                        } label: {
                            RecentTrackRow(track: track)
                        }
                        .buttonStyle(.plain)
                        if track.id != recentTracks.last?.id {
                            Divider().padding(.leading, 68)
                        }
                    }
                }
                .padding(.horizontal)
            }

            HStack {
                Text("Remote").font(.title3.bold())
                Spacer()
                Button { showingAddS3 = true } label: { Image(systemName: "plus.circle.fill") }
            }
            .padding(.horizontal)

            if s3Providers.isEmpty {
                Text("No remote sources yet. Add an S3 bucket to browse and sync episodes from.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                VStack(spacing: 0) {
                    ForEach(s3Providers) { record in
                        NavigationLink {
                            RemoteSourceDetailView(record: record)
                        } label: {
                            RemoteSourceRow(record: record)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                viewModel.delete(record)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        if record.id != s3Providers.last?.id {
                            Divider().padding(.leading, 68)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .sheet(isPresented: $showingAddS3) {
            NavigationStack { AddS3ProviderView(viewModel: viewModel) }
        }
        .sheet(isPresented: $isShowingPlayer) {
            RealPlayerView()
        }
        .onAppear(perform: reloadRecentTracks)
        .onChange(of: isShowingPlayer) { _, isShowing in
            if !isShowing { reloadRecentTracks() }
        }
    }

    private func reloadRecentTracks() {
        recentTracks = (try? trackStore.recentlyPlayed()) ?? []
    }
}

private struct RecentTrackRow: View {
    let track: Track
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.gradient)
                .frame(width: 44, height: 44)
                .overlay { Image(systemName: "play.circle.fill").foregroundStyle(.white) }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let positionMs = track.positionMs, let durationMs = track.durationMs, durationMs > 0 {
                    ProgressView(value: Double(positionMs), total: Double(durationMs))
                }
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

private struct RemoteSourceRow: View {
    let record: ProviderRecord
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.gradient)
                .frame(width: 44, height: 44)
                .overlay { Image(systemName: "cloud.fill").foregroundStyle(.white) }
            VStack(alignment: .leading, spacing: 2) {
                Text(record.label).font(.subheadline.weight(.semibold))
                Text(record.isActive ? "Active" : "Inactive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
