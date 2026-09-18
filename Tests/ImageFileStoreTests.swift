import ImageIO
import UIKit
import XCTest
@testable import EarToListen

final class ImageFileStoreTests: XCTestCase {
    private var store: ImageFileStore!

    override func setUp() {
        super.setUp()
        store = ImageFileStore(folderName: "TestImages-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: store.directory)
        super.tearDown()
    }

    /// The bug this guards: a picked photo used to be decoded whole and redrawn to shrink
    /// it, which killed the app on a real phone's 12-megapixel pictures.
    func testSavesAPhotoShrunkToTheLongEdge() async throws {
        let fileName = try await store.save(jpeg(width: 4032, height: 3024), maxDimension: 800)
        let url = try XCTUnwrap(store.url(for: fileName))
        let size = try pixelSize(of: url)
        XCTAssertEqual(max(size.width, size.height), 800)
        XCTAssertEqual(size.width / size.height, 4032.0 / 3024.0, accuracy: 0.01)
    }

    func testLeavesASmallPhotoAlone() async throws {
        let fileName = try await store.save(jpeg(width: 320, height: 240), maxDimension: 800)
        let size = try pixelSize(of: try XCTUnwrap(store.url(for: fileName)))
        XCTAssertEqual(size, CGSize(width: 320, height: 240))
    }

    /// The picker's own route in: the photo stays a file, so nothing holds the original.
    func testSavesAPhotoFromAFileWithoutReadingItWhole() async throws {
        let source = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).jpg")
        try jpeg(width: 4032, height: 3024).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let fileName = try await store.save(contentsOf: source, maxDimension: 800)
        let size = try pixelSize(of: try XCTUnwrap(store.url(for: fileName)))
        XCTAssertEqual(max(size.width, size.height), 800)
    }

    func testRejectsSomethingThatIsntAnImage() async {
        do {
            _ = try await store.save(Data("not a picture".utf8), maxDimension: 800)
            XCTFail("expected a failure")
        } catch {}
    }

    private func jpeg(width: Int, height: Int) throws -> Data {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
    }

    private func pixelSize(of url: URL) throws -> CGSize {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return CGSize(
            width: try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int),
            height: try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        )
    }
}
