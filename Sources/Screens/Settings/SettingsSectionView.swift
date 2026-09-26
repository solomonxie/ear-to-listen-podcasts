import SwiftUI
import UniformTypeIdentifiers

/// Embeddable "Settings" section for the single-page root layout. Everywhere episodes
/// come from — buckets and folders off this device alike — lives in
/// `SourcesSectionView`; this covers backups, AI keys and app-wide settings.
struct SettingsSectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var autoBackup = AutoBackup.shared
    @EnvironmentObject private var language: AppLanguageStore
    @State private var openPicker: String?
    @State private var exportDocument: BackupDocument?
    @State private var showingExportPicker = false
    @State private var showingImportPicker = false
    @State private var pendingImport: URL?
    /// What's inside the file just picked, read while the dialog asking about it is up.
    @State private var pendingPreview: SettingsViewModel.BackupPreview?
    @State private var showingAddAiKey = false
    @State private var showingRemoveAllConfirmation = false

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

    /// What's in the archive first, then what restoring it does. The counts are the whole
    /// reason this dialog exists: two copies of a library differ by what they hold, and
    /// nothing in a file name or its size says which one is the one with your notes in it.
    private var importMessage: String {
        guard let pendingPreview else {
            return "It becomes your library. The one here now is kept on this phone for a week — you can put it back."
        }
        var lines = [pendingPreview.contents]
        if let exportedAt = pendingPreview.exportedAt {
            lines.append("Saved \(exportedAt.formatted(date: .abbreviated, time: .shortened))")
        }
        if pendingPreview.canRestore {
            lines.append("It becomes your library. The one here now is kept on this phone for a week — you can put it back.")
        }
        return lines.joined(separator: "\n\n")
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
                        pendingPreview = viewModel.preview(of: url)
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
                    // Not offered for an archive a restore would only refuse — one that
                    // isn't ours, or one holding an empty library.
                    if pendingPreview?.canRestore != false {
                        Button("Restore") {
                            pendingImport = nil
                            viewModel.importSnapshot(from: url)
                        }
                    }
                    Button("Cancel", role: .cancel) { pendingImport = nil }
                } message: { _ in
                    Text(importMessage)
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

            // Down here because it's set once and never thought about again, unlike the
            // groups above it.
            VStack(alignment: .leading, spacing: 8) {
                SectionHeading(
                    title: "LANGUAGE",
                    info: "Applies right away, without a relaunch. \u{201C}Same as device\u{201D} follows your phone's own language setting. Each option is written in its own language, so it stays readable while the app is still showing the other one."
                )
                // No label on the row: the heading two lines up already says "LANGUAGE",
                // and repeating it left the word and the answer at opposite edges of the
                // screen with a hand's width of nothing between them. The current choice
                // is the row.
                UnfoldingPicker(
                    title: "", id: "appLanguage", open: $openPicker,
                    selection: $language.language,
                    options: AppLanguage.allCases.map { UnfoldingPicker.Option($0, $0.displayName) },
                    valueAlignment: .leading
                )
            }
            .padding(.horizontal)

            // No way to add one from here any more: episodes go into a bucket now
            // ("Upload from Files" in the folder browser), so they're backed up and on
            // every device instead of living in one phone's Files app. These rows stay for
            // the sources picked before that, to switch one off or throw it away.

            Button("Remove All App Data", role: .destructive) {
                showingRemoveAllConfirmation = true
            }
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .confirmationDialog("Remove all app data?", isPresented: $showingRemoveAllConfirmation) {
                Button("Remove Everything", role: .destructive) {
                    Task { await viewModel.removeAllAppData() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes everything stored by the app on this device. A copy is saved first, by itself: into Files, and into iCloud Drive and your bucket wherever they're connected.")
            }
        }
        .sectionRow()
        // The docked mini player sits over the end of the page, and Settings is the end
        // of the page — without this the last group is half a bar short of readable.
        .padding(.bottom, 72)
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { _ in viewModel.errorMessage = nil }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

}
