import SwiftUI
import UniformTypeIdentifiers

/// Embeddable "Settings" section for the single-page root layout. Remote (S3) sources
/// live in `RemoteSectionView`; this covers on-device storage and app-wide settings.
struct SettingsSectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @EnvironmentObject private var library: MockLibraryStore
    @State private var showingResetConfirmation = false
    @State private var showingFileImporter = false
    @State private var isImporting = false
    @State private var importMessage: String?

    private var localProviders: [ProviderRecord] {
        viewModel.providers.filter { $0.type == LocalFilesProvider.providerType }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Settings").font(.title3.bold()).padding(.horizontal)

            VStack(alignment: .leading, spacing: 8) {
                Text("ON-DEVICE STORAGE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Button {
                    showingFileImporter = true
                } label: {
                    if isImporting {
                        Label {
                            Text("Importing…")
                        } icon: {
                            ProgressView()
                        }
                    } else {
                        Label("Add Local Files", systemImage: "iphone")
                    }
                }
                .disabled(isImporting)
                .fileImporter(
                    isPresented: $showingFileImporter,
                    allowedContentTypes: [.audio],
                    allowsMultipleSelection: true
                ) { result in
                    Task { await handleImport(result) }
                }

                ForEach(localProviders) { record in
                    HStack {
                        Label(record.label, systemImage: "iphone")
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
                Text("Picks specific audio files and copies them into the app's on-device storage, then syncs them in.")
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

    private func handleImport(_ result: Result<[URL], Error>) async {
        switch result {
        case .failure(let error):
            importMessage = error.localizedDescription
        case .success(let urls):
            isImporting = true
            defer { isImporting = false }

            let destination = LocalFilesProvider.musicDirectory
            try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

            var copied = 0
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }
                let target = destination.appendingPathComponent(url.lastPathComponent)
                do {
                    if FileManager.default.fileExists(atPath: target.path) {
                        try FileManager.default.removeItem(at: target)
                    }
                    try FileManager.default.copyItem(at: url, to: target)
                    copied += 1
                } catch {
                    continue
                }
            }

            if localProviders.isEmpty {
                viewModel.addLocalProvider()
            }
            if let record = viewModel.providers.first(where: { $0.type == LocalFilesProvider.providerType }) {
                _ = try? await SyncEngine().sync(providerRecord: record)
            }
            importMessage = copied == 0
                ? "No files were imported."
                : "Imported \(copied) file\(copied == 1 ? "" : "s")."
        }
    }
}
