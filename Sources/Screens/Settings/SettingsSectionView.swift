import SwiftUI
import UniformTypeIdentifiers

/// Embeddable "Settings" section for the single-page root layout. Remote (S3) sources
/// live in `RemoteSectionView`; this covers on-device storage and app-wide settings.
struct SettingsSectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var autoBackup = AutoBackup.shared
    @EnvironmentObject private var language: AppLanguageStore
    @State private var showingResetConfirmation = false
    @State private var showingRemoveDemoConfirmation = false
    @State private var hasDemoData = DemoDataSeeder.isLoaded
    @State private var showingFolderPicker = false
    @State private var isScanning = false
    @State private var importMessage: String?
    @State private var exportDocument: BackupDocument?
    @State private var showingExportPicker = false
    @State private var showingImportPicker = false
    @State private var showingAddAiKey = false
    @State private var showingDownloads = false

    /// On by default once a bucket is connected, so say what it's doing and when it last
    /// did it — an automatic upload nobody can see is just an unexplained network bill.
    private var autoBackupHint: String {
        guard autoBackup.isEnabled else {
            return "Off — your playlists, edits and transcripts stay on this device until you back up by hand."
        }
        if let error = autoBackup.lastError {
            return "Last automatic backup failed: \(error)"
        }
        guard let lastBackupAt = autoBackup.lastBackupAt else {
            return "Uploads your app data to the connected bucket when it changes, at most every 15 minutes. Your episode files are never uploaded."
        }
        return "Uploaded when it changes, at most every 15 minutes. Last: \(lastBackupAt.formatted(date: .abbreviated, time: .shortened))."
    }

    private func loadDemoData() {
        try? DemoDataSeeder.load()
        hasDemoData = DemoDataSeeder.isLoaded
    }

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
                        Label("Scan local folder for podcasts", systemImage: "folder.badge.plus")
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
                    .sectionHint()
            }
            .padding(.horizontal)

            VStack(alignment: .leading, spacing: 8) {
                Text("LANGUAGE").sectionHeading()
                // A menu-style picker: one row showing the current choice, options on tap.
                // Three of them don't warrant a pushed page.
                Picker("Language", selection: $language.language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.menu)
                Text("Applies right away. \"System\" follows your device's language setting.")
                    .sectionHint()
            }
            .padding(.horizontal)

            VStack(alignment: .leading, spacing: 8) {
                Text("STORAGE").sectionHeading()
                Button {
                    showingDownloads = true
                } label: {
                    Label("Downloaded Episodes", systemImage: "arrow.down.circle")
                }
                Text("Episodes download automatically the first time you play them, for offline replay. Remove one here to free up space — it re-downloads next time you play it.")
                    .sectionHint()
            }
            .padding(.horizontal)
            .sheet(isPresented: $showingDownloads) {
                NavigationStack { DownloadsView() }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("AI KEYS").sectionHeading()
                    Spacer()
                    // The fallback order only matters with more than one key, but the
                    // control stays put either way so it doesn't appear out of nowhere.
                    Button {
                        viewModel.setAiKeyStrategy(viewModel.aiKeyStrategy == .sequential ? .roundRobin : .sequential)
                    } label: {
                        Text("\(viewModel.aiKeyStrategy.displayName) ▾").font(.caption.weight(.semibold))
                    }
                    .disabled(viewModel.aiKeys.count < 2)
                }
                Text("Used to guess better titles/show names during sync, and to transcribe an episode on playback. Sent straight from this device to the chosen vendor — never stored or seen by us, and never included in backups. Add more than one to fall back automatically if one hits a rate limit.")
                    .sectionHint()
                ForEach(Array(viewModel.aiKeys.enumerated()), id: \.element.id) { index, key in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key.vendor.displayName).font(.subheadline)
                            Text("\(key.requestCount) request\(key.requestCount == 1 ? "" : "s") sent")
                                .sectionRowSecondary()
                        }
                        Spacer()
                        if viewModel.aiKeys.count > 1 {
                            Button { viewModel.moveAiKey(key, direction: -1) } label: { Image(systemName: "chevron.up") }
                                .disabled(index == 0)
                            Button { viewModel.moveAiKey(key, direction: 1) } label: { Image(systemName: "chevron.down") }
                                .disabled(index == viewModel.aiKeys.count - 1)
                        }
                        // An explicit menu rather than only a long-press context menu —
                        // deleting a key shouldn't be a hidden gesture.
                        Menu {
                            Button(role: .destructive) {
                                viewModel.removeAiKey(key)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    showingAddAiKey = true
                } label: {
                    Label("Add AI Key", systemImage: "plus.circle")
                }
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

                Toggle("Keep the bucket up to date", isOn: $autoBackup.isEnabled)
                    .disabled(!viewModel.hasActiveRemoteProvider)
                Text(autoBackupHint)
                    .sectionHint()
                if viewModel.isBackupBusy {
                    ProgressView()
                } else if let backupStatusMessage = viewModel.backupStatusMessage {
                    Text(backupStatusMessage)
                        .sectionHint()
                }
                Text("Export/Backup save your playlists, source list, transcripts and corrections, and any speaker or episode edits with their images — as a .zip (not your episode files, not credentials). Restoring re-links playlist tracks that are already synced on this device; anything not synced yet is skipped until the next sync.")
                    .sectionHint()
            }
            .padding(.horizontal)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Button {
                        if hasDemoData { showingResetConfirmation = true } else { loadDemoData() }
                    } label: {
                        Label(
                            hasDemoData ? "Reset Sample Library" : "Load Sample Library",
                            systemImage: hasDemoData ? "arrow.counterclockwise" : "square.and.arrow.down"
                        )
                    }
                    // Sits beside it rather than in its own group: same sample data,
                    // opposite intent — put it back, or be rid of it.
                    if hasDemoData {
                        Button("Remove sample library", role: .destructive) {
                            showingRemoveDemoConfirmation = true
                        }
                        .sectionRowSecondary()
                    }
                }
                Text("A few sample shows, speakers, and playlists with three short clips, for looking around before you connect anything. Never loaded on its own — nothing appears in your library that you didn't put there. Removing it leaves only what you've synced.")
                    .sectionHint()
            }
            .padding(.horizontal)
        }
        .sectionRow()
        .alert("Reset Sample Library?", isPresented: $showingResetConfirmation) {
            Button("Reset", role: .destructive) { loadDemoData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This puts back the sample shows, speakers, and playlists.")
        }
        .alert("Remove Sample Library?", isPresented: $showingRemoveDemoConfirmation) {
            Button("Remove", role: .destructive) {
                try? DemoDataSeeder.removeAll()
                hasDemoData = DemoDataSeeder.isLoaded
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears the sample shows, speakers, albums and playlists. Your own synced episodes and sources stay. You can load the samples again later.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { _ in
            hasDemoData = DemoDataSeeder.isLoaded
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
