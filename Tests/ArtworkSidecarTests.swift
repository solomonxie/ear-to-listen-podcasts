import GRDB
import UIKit
import XCTest
@testable import EarToListen

private struct ImageProvider: CloudProvider {
    let type = "test-image"
    func listFiles(inFolder folderID: String?) async throws -> [CloudFile] { [] }
    func metadata(forFileID fileID: String) async throws -> CloudFile { throw CocoaError(.fileNoSuchFile) }
    func streamURL(forFileID fileID: String) async throws -> URL { URL(fileURLWithPath: "/dev/null") }
    func testConnection() async -> ConnectionTestResult { ConnectionTestResult(isSuccess: true, message: nil) }
    func download(fileID: String) async throws -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }
}

final class ArtworkSidecarTests: XCTestCase {
    private func file(_ path: String) -> CloudFile {
        CloudFile(id: path, name: (path as NSString).lastPathComponent, path: path, sizeBytes: 1, mimeType: nil, modifiedAt: nil)
    }

    func testFindPairsEpisodeImagesAndFolderCovers() {
        let found = ArtworkSidecar.find(in: [
            file("show/ep-01.mp3"), file("show/ep-01.jpg"),
            file("show/ep-02.mp3"),
            file("show/folder.png"), file("show/cover.jpg"),
            file("other/notes.jpg"),
        ])
        XCTAssertEqual(found.episodes, ["show/ep-01.mp3": "show/ep-01.jpg"])
        XCTAssertEqual(found.folders, ["show": "show/cover.jpg"])
    }

    func testCoverPathAndEpisodePath() {
        XCTAssertEqual(ArtworkSidecar.coverPath(inFolder: "a/b"), "a/b/cover.jpg")
        XCTAssertEqual(ArtworkSidecar.coverPath(inFolder: ""), "cover.jpg")
        XCTAssertEqual(ArtworkSidecar.episodePath(forAudioPath: "a/ep.m4a"), "a/ep.jpg")
    }

    func testOwnedFoldersSkipsFoldersSharedWithAnotherAlbum() {
        let owned = ArtworkSidecar.ownedFolders(of: "A", copies: [
            ("p", "solo/1.mp3", "A"), ("p", "solo/2.mp3", "A"),
            ("p", "mixed/1.mp3", "A"), ("p", "mixed/2.mp3", "B"),
            ("q", "solo/1.mp3", "A"),
        ])
        XCTAssertEqual(owned.map(\.providerID), ["p", "q"])
        XCTAssertEqual(owned.map(\.folder), ["solo", "solo"])
    }

    func testAdoptFillsOnlyUneditedItemsWithoutArtwork() async throws {
        let dbQueue = try DatabaseQueue()
        try Migrations.migrator().migrate(dbQueue)
        try await dbQueue.write { db in
            try ProviderRecord(id: "p", type: "test-image", label: "P", configJSON: "", isActive: true, createdAt: Date()).insert(db)
            try Album(id: "A", artistID: nil, name: "Show").insert(db)
            try Album(id: "E", artistID: nil, name: "Edited", metadataEditedAt: Date()).insert(db)
            for (id, path, album) in [("t1", "show/1.mp3", "A"), ("t2", "show/2.mp3", "A"), ("t3", "edited/1.mp3", "E")] {
                let track = Track(id: id, providerID: "p", artistID: nil, albumID: album, filePath: path, title: id, durationMs: nil, contentHash: nil, updatedAt: Date())
                try track.insert(db)
                try TrackFile(primaryOf: track).insert(db)
            }
        }
        let found = ArtworkSidecar.find(in: [
            file("show/1.mp3"), file("show/1.jpg"), file("show/2.mp3"), file("show/cover.jpg"),
            file("edited/1.mp3"), file("edited/cover.jpg"),
        ])
        await ArtworkSidecar.adopt(found, providerID: "p", provider: ImageProvider(), dbQueue: dbQueue)

        let (t1, t2, a, e) = try await dbQueue.read { db in
            (try Track.fetchOne(db, key: "t1"), try Track.fetchOne(db, key: "t2"),
             try Album.fetchOne(db, key: "A"), try Album.fetchOne(db, key: "E"))
        }
        XCTAssertNotNil(t1?.artworkFileName)
        XCTAssertNil(t2?.artworkFileName)
        XCTAssertNotNil(a?.artworkFileName)
        XCTAssertNil(e?.artworkFileName)
        for name in [t1?.artworkFileName, a?.artworkFileName] { ImageFileStore.artwork.remove(name) }
    }
}
