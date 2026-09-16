import SwiftUI
import UniformTypeIdentifiers

/// Wraps a `LibrarySnapshot` zip archive (`BackupService.archive`/`unarchive`) for
/// `.fileExporter`/`.fileImporter` (Export/Import Library Data in `SettingsSectionView`).
struct BackupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.zip]

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
