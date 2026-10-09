import SwiftUI

/// The phone's copy of the episode, and a way to drop it to save space.
struct EpisodeAudioSection: View {
    let track: Track
    @State private var cachedBytes: Int64?

    var body: some View {
        Section("Audio") {
            if let cachedBytes {
                Button("Remove Download from Phone (\(ByteCountFormatter.string(fromByteCount: cachedBytes, countStyle: .file)))", systemImage: "iphone.slash") {
                    Task {
                        await AudioCache.shared.invalidate(providerID: track.providerID, filePath: track.filePath)
                        await reload()
                    }
                }
            } else {
                Label("Not downloaded to this phone", systemImage: "icloud")
                    .foregroundStyle(.secondary)
            }
        }
        .task { await reload() }
    }

    private func reload() async {
        cachedBytes = await AudioCache.shared.cachedSize(providerID: track.providerID, filePath: track.filePath)
    }
}
