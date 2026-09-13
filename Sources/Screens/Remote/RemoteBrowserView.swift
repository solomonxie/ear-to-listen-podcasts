import SwiftUI

/// Real folder-style browsing over a remote source, one directory level at a time —
/// recurses by pushing itself with the tapped subfolder's path. Each level can be
/// synced on its own via the sync queue, without pulling in the rest of the bucket.
struct RemoteBrowserView: View {
    let record: ProviderRecord
    var folder: String?
    var title: String?

    @State private var folders: [String] = []
    @State private var files: [CloudFile] = []
    @State private var errorMessage: String?
    @State private var showingFileInfo: CloudFile?
    @State private var showingQueue = false

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.orange)
            }
            ForEach(folders, id: \.self) { name in
                NavigationLink {
                    RemoteBrowserView(record: record, folder: childPath(name), title: name)
                } label: {
                    Label(name, systemImage: "folder.fill")
                }
            }
            ForEach(files) { file in
                Button {
                    showingFileInfo = file
                } label: {
                    HStack {
                        Label(file.name, systemImage: "waveform")
                        Spacer()
                        if let sizeBytes = file.sizeBytes {
                            Text(Self.formattedSize(sizeBytes))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .navigationTitle(title ?? record.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await syncThisFolder() }
                } label: {
                    Label("Sync Folder", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        }
        .task { await load() }
        .sheet(item: $showingFileInfo) { file in
            FileInfoSheet(file: file)
        }
        .sheet(isPresented: $showingQueue) {
            NavigationStack { SyncQueueView() }
        }
    }

    private func childPath(_ name: String) -> String {
        guard let folder, !folder.isEmpty else { return name }
        return folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }

    private func load() async {
        guard let provider = try? ProviderManager.shared.provider(for: record) else {
            errorMessage = "Couldn't connect to this source."
            return
        }
        guard let listing = try? await provider.listDirectory(atFolder: folder) else {
            errorMessage = "Couldn't list files."
            return
        }
        folders = listing.folders
        files = listing.files
    }

    /// Enqueues just the files directly in this folder (not subfolders) into the sync queue.
    private func syncThisFolder() async {
        await SyncQueueManager.shared.enqueueFolder(providerID: record.id, folder: folder)
        showingQueue = true
    }

    static func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct FileInfoSheet: View {
    let file: CloudFile

    var body: some View {
        NavigationStack {
            List {
                LabeledContent("File", value: file.name)
                if let sizeBytes = file.sizeBytes {
                    LabeledContent("Size", value: RemoteBrowserView.formattedSize(sizeBytes))
                }
                if let modifiedAt = file.modifiedAt {
                    LabeledContent("Modified", value: modifiedAt.formatted())
                }
                Section {
                    Text("Would be imported as a new episode on next sync — its file hash is checked against local metadata first, so anything already known doesn't get rebuilt.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Episode file")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}
