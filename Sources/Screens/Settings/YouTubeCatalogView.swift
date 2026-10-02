import SwiftUI

/// The YouTube catalog, as the bucket has it: every YouTube episode and where its files
/// go. Opening the page uploads it first if it changed, so what's listed is what the
/// bucket's `youtube-catalog.json` says.
struct YouTubeCatalogView: View {
    @State private var state: YouTubeCatalog.State?
    @State private var isUploading = false

    var body: some View {
        List {
            Section {
                status
            }
            if let state {
                Section {
                    if state.videos.isEmpty {
                        Text("No YouTube videos yet.").foregroundStyle(.secondary)
                    }
                    ForEach(state.videos, id: \.videoID) { entry in
                        row(entry)
                    }
                } header: {
                    Text("\(state.videos.count) videos")
                }
            }
        }
        .navigationTitle("YouTube Catalog")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh(upload: false) }
        .refreshable { await refresh(upload: false) }
    }

    @ViewBuilder private var status: some View {
        if let state {
            if let key = state.key {
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        state.isUploaded ? "In sync with the bucket" : "Not uploaded yet",
                        systemImage: state.isUploaded ? "checkmark.icloud" : "icloud.slash"
                    )
                    .foregroundStyle(state.isUploaded ? Color.green : Color.orange)
                    Text(key).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    if let uploadedAt = state.uploadedAt {
                        Text("Uploaded \(uploadedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button {
                    Task { await refresh(upload: true) }
                } label: {
                    HStack {
                        Label("Upload now", systemImage: "arrow.up.circle")
                        if isUploading { Spacer(); ProgressView() }
                    }
                }
                .disabled(isUploading)
            } else {
                Text("Connect a bucket to keep the catalog in it, beside the backups.")
                    .foregroundStyle(.secondary)
            }
        } else {
            ProgressView()
        }
    }

    private func row(_ entry: YouTubeCatalog.Entry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.title).font(.subheadline.weight(.semibold))
            Text("\(entry.speaker) · \(entry.album)").font(.caption).foregroundStyle(.secondary)
            Text(entry.transcriptPath).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            Text(entry.audioPath).font(.caption2.monospaced()).foregroundStyle(.tertiary)
        }
        .textSelection(.enabled)
        .contextMenu {
            Button("Copy Transcript Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = entry.transcriptPath }
            Button("Copy Audio Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = entry.audioPath }
            Link(destination: YouTubeVideo.watchURL(id: entry.videoID)) {
                Label("Open in YouTube", systemImage: "arrow.up.forward.app")
            }
        }
    }

    /// Uploads first when the catalog changed (or always, for Upload now), then lists it.
    private func refresh(upload force: Bool) async {
        isUploading = true
        await YouTubeCatalog.publishIfChanged(force: force)
        isUploading = false
        state = await Task.detached(priority: .userInitiated) { YouTubeCatalog.state() }.value
    }
}
