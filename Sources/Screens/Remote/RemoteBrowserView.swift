import SwiftUI

/// Folder-style browsing over a remote source. Recurses by pushing itself
/// with the tapped folder's children — the nav stack's back button doubles
/// as the breadcrumb trail.
struct RemoteBrowserView: View {
    let sourceName: String
    var entries: [RemoteEntry] = MockData.remoteTree
    var title: String?

    @State private var showingFileInfo: RemoteEntry?

    var body: some View {
        List(entries) { entry in
            switch entry {
            case .folder(_, let name, let children):
                NavigationLink {
                    RemoteBrowserView(sourceName: sourceName, entries: children, title: name)
                } label: {
                    Label(name, systemImage: "folder.fill")
                }
            case .file(_, let name, let sizeBytes, _):
                Button {
                    showingFileInfo = entry
                } label: {
                    HStack {
                        Label(name, systemImage: "waveform")
                        Spacer()
                        Text(Self.formattedSize(sizeBytes))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .navigationTitle(title ?? sourceName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $showingFileInfo) { entry in
            FileInfoSheet(entry: entry)
        }
    }

    static func formattedSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

private struct FileInfoSheet: View {
    let entry: RemoteEntry

    var body: some View {
        NavigationStack {
            if case .file(_, let name, let size, let modified) = entry {
                List {
                    LabeledContent("File", value: name)
                    LabeledContent("Size", value: RemoteBrowserView.formattedSize(size))
                    LabeledContent("Modified", value: modified)
                    Section {
                        Text("Would be imported as a new episode on next sync — its file hash is checked against local metadata first, so anything already known doesn't get rebuilt.")
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Episode file")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .presentationDetents([.medium])
    }
}
