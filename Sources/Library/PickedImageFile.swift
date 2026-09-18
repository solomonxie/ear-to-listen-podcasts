import CoreTransferable
import UniformTypeIdentifiers

/// A photo picked from the library, handed over as a file on disk rather than as bytes.
///
/// `loadTransferable(type: Data.self)` pulls the whole original into memory first — tens
/// of megabytes for one modern photo, before anything has had the chance to shrink it —
/// and on a phone that is enough to be killed mid-pick. A file costs nothing to hold, and
/// `ImageFileStore` reads it straight through ImageIO at the size it actually wants.
///
/// The copy is the caller's to delete: the URL the picker hands over is only valid inside
/// the transfer.
struct PickedImageFile: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let copy = URL.temporaryDirectory.appending(path: "\(UUID().uuidString)-\(received.file.lastPathComponent)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedImageFile(url: copy)
        }
    }

    func discard() {
        try? FileManager.default.removeItem(at: url)
    }
}
