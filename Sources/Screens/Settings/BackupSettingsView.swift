import SwiftUI
import UniformTypeIdentifiers

struct BackupSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var autoBackup = AutoBackup.shared
    @State private var exportDocument: BackupDocument?
    @State private var showingExportPicker = false
    @State private var showingImportPicker = false
    @State private var pendingImport: URL?
    /// What's inside the file just picked, read while the dialog asking about it is up.
    @State private var pendingPreview: SettingsViewModel.BackupPreview?

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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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
            .settingsCard()
            }
            .sectionRow()
            .padding(.vertical)
            .padding(.bottom, 72)
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("Backup & Restore")
        .navigationBarTitleDisplayMode(.inline)
    }
}
