import SwiftUI
import UniformTypeIdentifiers

/// Embeddable "Settings" section for the single-page root layout. Remote (S3) sources
/// live in `RemoteSectionView`; this covers on-device storage and app-wide settings.
struct SettingsSectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var autoBackup = AutoBackup.shared
    @ObservedObject private var transcript = TranscriptRunner.shared
    @EnvironmentObject private var language: AppLanguageStore
    @State private var showingResetConfirmation = false
    @State private var showingRemoveDemoConfirmation = false
    @State private var hasDemoData = DemoDataSeeder.isLoaded
    @State private var showingFilePicker = false
    @State private var isScanning = false
    @State private var importMessage: String?
    @State private var exportDocument: BackupDocument?
    @State private var showingExportPicker = false
    @State private var showingImportPicker = false
    @State private var pendingImport: URL?
    @State private var showingAddAiKey = false

    /// Says which of the four reasons an iCloud folder can be unusable applies, because
    /// they need four different things said — and the explanation *replaces* the location
    /// line rather than piling up next to it.
    private var cloudDriveHint: LocalizedStringKey {
        switch autoBackup.cloudDriveStatus {
        case .notEntitled: return "This build of the app isn't signed for iCloud."
        case .driveOff: return "iCloud Drive is off on this device."
        case .notReady: return "Setting up your iCloud folder — try again shortly."
        case .ready: break
        }
        if let error = autoBackup.cloudDriveError {
            return "Last backup to iCloud failed: \(error)"
        }
        // Slashes, not arrows: it's where the file sits, and an arrow reads as a
        // sequence of taps — which is what the directions line below it actually is.
        guard autoBackup.isCloudDriveEnabled else {
            return "Files / iCloud Drive / Ear to Listen. Switch on to keep a copy that outlives deleting the app."
        }
        guard let lastBackupAt = autoBackup.lastCloudDriveBackupAt else {
            return "Files / iCloud Drive / Ear to Listen · \(BackupArchiveName.current())"
        }
        return "Files / iCloud Drive / Ear to Listen · \(BackupArchiveName.current()) · Last: \(lastBackupAt.formatted(date: .abbreviated, time: .shortened))"
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
                SectionHeading(
                    title: "SYNC & BACKUP",
                    info: "Every copy holds your playlists, source list, transcripts and corrections, and any speaker or episode edits with their images — a .zip, never your episode files. Keys never leave this device, including in backups. One archive a day (20260918-ear-to-listen.zip): iCloud keeps the last ten, the bucket keeps every one of them, and this phone keeps a week's worth in Files where you can drag one out — those go when the app does, so they're for undoing a mistake, not for a lost phone. Deleting and reinstalling the app puts it back by itself: iCloud first, then the bucket if it's keeping app data. It's a backup, not a link between phones — restoring builds a fresh library from the archive and keeps the one it replaced for a week. Playlist tracks, edits and transcripts re-link themselves as the files they name come back in on the next sync."
                )

                // A destination is one switch and nothing else: on means every change
                // goes there, off means none do. iCloud comes first — it's the only one
                // with nothing to set up.
                Toggle(isOn: $autoBackup.isCloudDriveEnabled) {
                    Label("iCloud Drive", systemImage: "icloud")
                }
                .disabled(!autoBackup.cloudDriveStatus.isReady)
                Text(cloudDriveHint)
                    .sectionHint()
                // Directions only for the one state the listener can act on, spelled out
                // in full — the setting is four levels down, under their own name.
                if autoBackup.cloudDriveStatus == .driveOff {
                    Text("Settings → your name → iCloud → iCloud Drive → turn on")
                        .sectionHint()
                        .foregroundStyle(Color.accentColor)
                }

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
                    defaultFilename: BackupArchiveName.base()
                ) { _ in exportDocument = nil }

                Button {
                    showingImportPicker = true
                } label: {
                    Label("Import Library Data", systemImage: "square.and.arrow.down")
                }
                .fileImporter(isPresented: $showingImportPicker, allowedContentTypes: [.zip]) { result in
                    if case .success(let url) = result {
                        pendingImport = url
                    }
                }
                // Asked here, with the file already picked, and saying what it does rather
                // than "are you sure": a restore replaces the library, and the answer
                // depends on knowing the old one is kept.
                .confirmationDialog(
                    "Restore from this file?",
                    isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }),
                    presenting: pendingImport
                ) { url in
                    Button("Restore") {
                        pendingImport = nil
                        viewModel.importSnapshot(from: url)
                    }
                    Button("Cancel", role: .cancel) { pendingImport = nil }
                } message: { _ in
                    Text("It becomes your library. The one here now is kept on this phone for a week — you can put it back.")
                }

                if let backupStatusMessage = viewModel.backupStatusMessage {
                    Text(backupStatusMessage)
                        .sectionHint()
                }

                // Only while the replaced library is still on the phone. Not a destination
                // and not offered beside one — it's the way back from a restore, and it
                // goes away with the copy it points at.
                if let replacedAt = viewModel.replacedLibraryAt {
                    Button {
                        viewModel.undoRestore()
                    } label: {
                        Label(
                            "Undo restore — put back \(replacedAt.formatted(date: .abbreviated, time: .shortened))",
                            systemImage: "arrow.uturn.backward"
                        )
                    }
                }
            }
            .padding(.horizontal)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionHeading(
                        title: "AI KEYS",
                        info: "Used to guess better titles and show names during sync, and to transcribe an episode on playback. Sent straight from this device to the chosen vendor — never stored or seen by us, and never included in backups. Add more than one to fall back automatically if one hits a rate limit."
                    )
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
                Text("Better titles during sync, and transcription on playback.")
                    .sectionHint()
                ForEach(Array(viewModel.aiKeys.enumerated()), id: \.element.id) { index, key in
                    HStack {
                        // The key's own page: what it's been asked, what came back, and
                        // what that cost. A request count alone explains nothing.
                        NavigationLink {
                            AiKeyDetailView(key: key)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(key.vendor.displayName).font(.subheadline)
                                Text("\(key.requestCount) request\(key.requestCount == 1 ? "" : "s") sent")
                                    .sectionRowSecondary()
                            }
                        }
                        .buttonStyle(.plain)
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
                SectionHeading(
                    title: "TRANSCRIPTS",
                    info: "Transcribing spends battery on this device, or money through an AI key, so it's off unless asked for. With this on, opening an episode with no transcript starts an on-device pass over the whole of it in the background; you can stop it from that episode's own page, and the AI recogniser is always asked for by hand. Transcripts already made, and any transcript file sitting beside the audio, are shown either way."
                )
                Toggle("Transcribe every episode automatically", isOn: $transcript.startsAutomatically)
                Text(transcript.startsAutomatically ? "On for every episode." : "Only the episodes you ask for.")
                    .sectionHint()
            }
            .padding(.horizontal)

            // Down here because it's set once and never thought about again, unlike the
            // groups above it — but above Add Episodes, which is where you go to *do*
            // something rather than to configure one.
            VStack(alignment: .leading, spacing: 8) {
                SectionHeading(
                    title: "LANGUAGE",
                    info: "Applies right away, without a relaunch. \u{201C}Same as device\u{201D} follows your phone's own language setting. Each option is written in its own language, so it stays readable while the app is still showing the other one."
                )
                // A menu `Picker` outside a `Form` drops its own label and indents what's
                // left, so the row read as a stray "System" sitting off the margin. The
                // heading names it, and the choice is written into the button.
                Menu {
                    Picker("Language", selection: $language.language) {
                        ForEach(AppLanguage.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                } label: {
                    Text("\(language.language.displayName) ▾")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal)

            // Both ways of putting episodes in the library that aren't a remote source —
            // your own files, or the samples — as two links, not two sections.
            VStack(alignment: .leading, spacing: 8) {
                SectionHeading(
                    title: "ADD EPISODES",
                    info: "Files you pick are read where they sit — nothing is copied into the app, and nothing is uploaded. Pick a whole folder and everything under it is scanned; pick episodes one by one and only those are added. The sample library is a few short clips bundled with the app, for looking around before you connect anything; it never loads on its own."
                )

                Button {
                    showingFilePicker = true
                } label: {
                    if isScanning {
                        Label { Text("Importing…") } icon: { ProgressView() }
                    } else {
                        Text("Import podcasts from Files")
                    }
                }
                .disabled(isScanning)
                .fileImporter(
                    isPresented: $showingFilePicker,
                    allowedContentTypes: [.audio, .folder],
                    allowsMultipleSelection: true
                ) { result in
                    Task { await handleFilePick(result) }
                }
                Text("Read where they sit, never copied.")
                    .sectionHint()

                // Only what's already here: the rows exist to switch a source off or throw
                // it away, and there's nothing to say when there are none.
                ForEach(localProviders) { record in
                    HStack {
                        Text(record.label)
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

                HStack(spacing: 12) {
                    Button {
                        if hasDemoData { showingResetConfirmation = true } else { loadDemoData() }
                    } label: {
                        Text(hasDemoData ? "Reset sample library" : "Load sample library")
                    }
                    // Beside it rather than under: same sample data, opposite intent —
                    // put it back, or be rid of it.
                    if hasDemoData {
                        Button("Remove", role: .destructive) {
                            showingRemoveDemoConfirmation = true
                        }
                        .sectionRowSecondary()
                    }
                }
                Text("A few sample shows and clips to look around with.")
                    .sectionHint()
            }
            .padding(.horizontal)
        }
        .sectionRow()
        // The docked mini player sits over the end of the page, and Settings is the end
        // of the page — without this the last group is half a bar short of readable.
        .padding(.bottom, 72)
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

    /// One picker for both: a folder becomes a source of its own, while loose episodes all
    /// join the single "Files" source, so importing twice doesn't split a library in two.
    private func handleFilePick(_ result: Result<[URL], Error>) async {
        guard case .success(let urls) = result else {
            if case .failure(let error) = result { importMessage = error.localizedDescription }
            return
        }
        isScanning = true
        defer { isScanning = false }

        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let files = urls.filter { !folders.contains($0) }
        var records = folders.compactMap { viewModel.addLocalProvider(folderURL: $0) }
        if !files.isEmpty, let record = viewModel.addPickedFiles(files) {
            records.append(record)
        }
        guard !records.isEmpty else {
            importMessage = "Couldn't read what you picked."
            return
        }

        var found = 0
        for record in records {
            found += (try? await SyncEngine().sync(providerRecord: record))?.totalFiles ?? 0
        }
        importMessage = "Found \(found) file\(found == 1 ? "" : "s")."
    }
}
