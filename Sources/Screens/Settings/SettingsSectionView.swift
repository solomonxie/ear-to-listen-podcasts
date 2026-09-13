import SwiftUI
import UniformTypeIdentifiers

/// Embeddable "Settings" section for the single-page root layout. Remote (S3) sources
/// live in `RemoteSectionView`; this covers on-device storage and app-wide settings.
struct SettingsSectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @EnvironmentObject private var library: MockLibraryStore
    @State private var showingResetConfirmation = false
    @State private var showingFolderPicker = false
    @State private var isScanning = false
    @State private var importMessage: String?

    private var localProviders: [ProviderRecord] {
        viewModel.providers.filter { $0.type == LocalFilesProvider.providerType }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Settings").font(.title3.bold()).padding(.horizontal)

            VStack(alignment: .leading, spacing: 8) {
                Text("LOCAL FOLDERS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Button {
                    showingFolderPicker = true
                } label: {
                    if isScanning {
                        Label {
                            Text("Scanning…")
                        } icon: {
                            ProgressView()
                        }
                    } else {
                        Label("Add a Folder", systemImage: "folder.badge.plus")
                    }
                }
                .disabled(isScanning)
                .fileImporter(
                    isPresented: $showingFolderPicker,
                    allowedContentTypes: [.folder]
                ) { result in
                    Task { await handleFolderPick(result) }
                }

                ForEach(localProviders) { record in
                    HStack {
                        Label(record.label, systemImage: "folder")
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { record.isActive },
                            set: { _ in viewModel.toggleActive(record) }
                        ))
                        .labelsHidden()
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            viewModel.delete(record)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                if let importMessage {
                    Text(importMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("Scans a folder you pick on this device for audio files — they're read in place, never copied.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            VStack(alignment: .leading, spacing: 8) {
                Text("SYNC & BACKUP").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                comingSoonRow("Export Library Data", systemImage: "square.and.arrow.up")
                comingSoonRow("Import Library Data", systemImage: "square.and.arrow.down")
                comingSoonRow("Backup to Remote Now", systemImage: "arrow.clockwise.icloud")
                comingSoonRow("Restore from Remote", systemImage: "icloud.and.arrow.down")
            }
            .padding(.horizontal)

            VStack(alignment: .leading, spacing: 8) {
                Button(role: .destructive) {
                    showingResetConfirmation = true
                } label: {
                    Label("Reset Demo Data", systemImage: "arrow.counterclockwise")
                }
                Text("Restores the sample shows, speakers, and playlists in case you deleted something while exploring. Doesn't touch your real remote/local sources.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
        }
        .alert("Reset Demo Data?", isPresented: $showingResetConfirmation) {
            Button("Reset", role: .destructive) { library.resetToDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This puts back the sample shows, speakers, and playlists.")
        }
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { _ in viewModel.errorMessage = nil }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func comingSoonRow(_ title: String, systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text("Coming soon")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.secondary)
    }

    private func handleFolderPick(_ result: Result<URL, Error>) async {
        switch result {
        case .failure(let error):
            importMessage = error.localizedDescription
        case .success(let folderURL):
            isScanning = true
            defer { isScanning = false }

            guard let record = viewModel.addLocalProvider(folderURL: folderURL) else {
                importMessage = "Couldn't add that folder."
                return
            }
            let result = try? await SyncEngine().sync(providerRecord: record)
            importMessage = "Found \(result?.totalFiles ?? 0) file\(result?.totalFiles == 1 ? "" : "s")."
        }
    }
}
