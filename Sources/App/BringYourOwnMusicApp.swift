import SwiftUI

@main
struct BringYourOwnMusicApp: App {
    init() {
        CloudProviderRegistry.shared.register(type: S3Provider.providerType) { try S3Provider(config: $0) }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
