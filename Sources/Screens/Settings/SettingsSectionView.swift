import SwiftUI
import UniformTypeIdentifiers

/// Embeddable "Settings" section for the single-page root layout. Remote (S3) sources
/// live in `RemoteSectionView`; this covers on-device storage and app-wide settings.
struct SettingsSectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showingResetConfirmation = false
    @State private var showingFolderPicker = false
    @State private var isScanning = false
    @State private var importMessage: String?
    @State private var exportDocument: BackupDocument?
    @State private var showingExportPicker = false
    @State private var showingImportPicker = false
    @State private var showingAddAiKey = false

    private var localProviders: [ProviderRecord] {
        viewModel.providers.filter { $0.type == LocalFilesProvider.providerType }
    }

    var body: some View {
        // Rows inherit `.sectionRow()`; headings and hints opt out explicitly. Without it
        // every Label falls back to `.body`, dwarfing its own section heading.
        VStack(alignment: .leading, spacing: 24) {
            Text("Settings").sectionTitle().padding(.horizontal)

            VStack(alignment: .leading, spacing: 8) {
                Text("LOCAL FOLDERS").sectionHeading()
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
                        .sectionHint()
                }
                Text("Scans a folder you pick on this device for audio files — they're read in place, never copied.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("AI FEATURES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if viewModel.aiKeys.count > 1 {
                        Button {
                            viewModel.setAiKeyStrategy(viewModel.aiKeyStrategy == .sequential ? .roundRobin : .sequential)
                        } label: {
                            Text("\(viewModel.aiKeyStrategy.displayName) ▾").font(.caption)
                        }
                    }
                }
                ForEach(Array(viewModel.aiKeys.enumerated()), id: \.element.id) { index, key in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key.vendor.displayName).font(.subheadline)
                            Text("\(key.requestCount) request\(key.requestCount == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if viewModel.aiKeys.count > 1 {
                            Button { viewModel.moveAiKey(key, direction: -1) } label: { Image(systemName: "chevron.up") }
                                .disabled(index == 0)
                            Button { viewModel.moveAiKey(key, direction: 1) } label: { Image(systemName: "chevron.down") }
                                .disabled(index == viewModel.aiKeys.count - 1)
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            viewModel.removeAiKey(key)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                Button {
                    showingAddAiKey = true
                } label: {
                    Label("Add AI Key", systemImage: "plus.circle")
                }
                Text("Optional — during sync, lets the app ask AI to guess better titles/show names from a file's path and existing tags (not its audio); OpenAI keys are also used to transcribe an episode's audio on playback, with the result saved on-device. Add more than one key (same or different vendor) to fall back automatically if one is rate-limited — Sequential keeps using the first working key; Round-robin spreads requests across all of them. Keys are stored only in this device's Keychain: we never see them or send them anywhere ourselves, they're used solely for direct requests from your device to that vendor.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .sheet(isPresented: $showingAddAiKey) {
                AddAiKeyView(viewModel: viewModel)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("SYNC & BACKUP").sectionHeading()

                Button {
                    exportDocument = viewModel.makeExportDocument()
                    showingExportPicker = exportDocument != nil
                } label: {
                    Label("Export Library Data", systemImage: "square.and.arrow.up")
                }
                .fileExporter(
                    isPresented: $showingExportPicker,
                    document: exportDocument,
                    contentType: .zip,
                    defaultFilename: "byop-backup"
                ) { _ in exportDocument = nil }

                Button {
                    showingImportPicker = true
                } label: {
                    Label("Import Library Data", systemImage: "square.and.arrow.down")
                }
                .fileImporter(isPresented: $showingImportPicker, allowedContentTypes: [.zip]) { result in
                    if case .success(let url) = result {
                        viewModel.importSnapshot(from: url)
                    }
                }

                Button {
                    viewModel.backupToRemote()
                } label: {
                    Label("Backup to Remote Now", systemImage: "arrow.clockwise.icloud")
                }
                .disabled(viewModel.isBackupBusy)

                Button {
                    viewModel.restoreFromRemote()
                } label: {
                    Label("Restore from Remote", systemImage: "icloud.and.arrow.down")
                }
                .disabled(viewModel.isBackupBusy)

                if !viewModel.hasActiveRemoteProvider {
                    Text("Backup/Restore need an active remote (S3) source — see the Remote tab.")
                        .sectionHint()
                }
                if viewModel.isBackupBusy {
                    ProgressView()
                } else if let backupStatusMessage = viewModel.backupStatusMessage {
                    Text(backupStatusMessage)
                        .sectionHint()
                }
                Text("Export/Backup save your playlists, source list, and any speaker bio/photo edits — as a .zip (not your episode files, not credentials). Restoring re-links playlist tracks that are already synced on this device; anything not synced yet is skipped until the next sync.")
                    .sectionHint()
            }
            .padding(.horizontal)

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    showingResetConfirmation = true
                } label: {
                    Label("Reset Demo Data", systemImage: "arrow.counterclockwise")
                }
                Text("Restores the sample shows, speakers, and playlists in case you deleted something while exploring. Doesn't touch your real remote/local sources.")
                    .sectionHint()
            }
            .padding(.horizontal)
        }
        .sectionRow()
        .alert("Reset Demo Data?", isPresented: $showingResetConfirmation) {
            Button("Reset", role: .destructive) { try? DemoDataSeeder.reseed() }
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
