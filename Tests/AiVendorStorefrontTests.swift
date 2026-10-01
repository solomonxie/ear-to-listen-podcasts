import GRDB
import XCTest
@testable import EarToListen

final class AiVendorStorefrontTests: XCTestCase {
    func testChinaStorefrontOffersOnlyLicensedVendorsAndCustom() {
        let china = AiVendor.allCases.filter { $0.isOffered(inChina: true) }
        XCTAssertEqual(Set(china), [.deepSeek, .qwen, .moonshot, .zhipu, .doubao, .custom])
        XCTAssertEqual(AiVendor.allCases.filter { $0.isOffered(inChina: false) }, AiVendor.allCases)
    }

    /// A key saved before the storefront changed stays in the database but isn't listed.
    func testSavedKeyForAHiddenVendorIsNotReturned() throws {
        let dbQueue = try DatabaseQueue()
        try Migrations.migrator().migrate(dbQueue)
        try dbQueue.write { db in
            try AiKey(id: "a", vendor: .openAI, position: 0, createdAt: Date()).insert(db)
            try AiKey(id: "b", vendor: .qwen, position: 1, createdAt: Date()).insert(db)
        }
        let store = AiKeyStore(dbQueue: dbQueue)
        XCTAssertEqual(try store.all(inChina: true).map(\.id), ["b"])
        XCTAssertEqual(try store.all(inChina: false).map(\.id), ["a", "b"])
    }

    func testEveryCompatibleVendorHasAnEndpointAndDefaultModel() {
        for vendor in AiVendor.allCases where ![.openAI, .anthropic, .google, .custom].contains(vendor) {
            XCTAssertNotNil(OpenAICompatibleChatClient.Config.forVendor(vendor), vendor.rawValue)
            XCTAssertFalse(vendor.defaultModel.isEmpty, vendor.rawValue)
        }
    }

    func testCustomEndpointAcceptsABaseOrTheFullPath() {
        let endpoint = OpenAICompatibleChatClient.Config.customEndpoint
        XCTAssertEqual(endpoint("https://api.example.com/v1")?.absoluteString, "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(endpoint(" https://api.example.com/v1/ ")?.absoluteString, "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(
            endpoint("https://api.example.com/v1/chat/completions")?.absoluteString,
            "https://api.example.com/v1/chat/completions"
        )
        XCTAssertEqual(endpoint("http://192.168.1.5:8080")?.absoluteString, "http://192.168.1.5:8080/chat/completions")
        XCTAssertNil(endpoint("api.example.com/v1"))
        XCTAssertNil(endpoint("ftp://api.example.com"))
        XCTAssertNil(endpoint(""))
    }

    func testCustomKeyIsNamedByItsHost() {
        let key = AiKey(id: "c", vendor: .custom, position: 0, createdAt: Date(), baseURL: "https://llm.example.cn/v1")
        XCTAssertEqual(key.displayName, "llm.example.cn")
    }
}
