import SwiftUI

/// Shows a non-audio file's contents, for the times a bucket holds something that isn't an
/// episode — a transcript sidecar, a backup, a stray note.
///
/// The extension decides whether to *offer* a preview; the bytes decide what's actually
/// shown. A file named `.json` that turns out to be a zip gets said so rather than rendered
/// as several screens of mojibake.
struct FilePreviewSheet: View {
    let file: CloudFile
    let record: ProviderRecord

    /// Enough to read, not enough to stall on someone's 40 MB export.
    private static let maximumBytes = 256 * 1024

    @State private var text: String?
    @State private var message: String?
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if let text {
                    ScrollView {
                        Text(text)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                } else {
                    ContentUnavailableView {
                        Label("Can't show this one", systemImage: FileKind(path: file.path).symbol)
                    } description: {
                        Text(message ?? "This file isn't readable as text.")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await load() }
    }

    private func load() async {
        defer { isLoading = false }
        guard let provider = try? ProviderManager.shared.provider(for: record),
              let url = try? await provider.streamURL(forFileID: file.path) else {
            message = "Couldn't reach this source."
            return
        }
        guard let data = await contents(of: url) else {
            message = "Couldn't read this file."
            return
        }
        if let described = Self.describeBinary(data) {
            message = described
            return
        }
        guard let decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            message = "This file isn't text."
            return
        }
        text = data.count >= Self.maximumBytes
            ? decoded + "\n\n… truncated — showing the first \(Self.maximumBytes / 1024) KB."
            : decoded
    }

    private func contents(of url: URL) async -> Data? {
        if url.isFileURL {
            return try? Data(contentsOf: url).prefix(Self.maximumBytes)
        }
        var request = URLRequest(url: url)
        // Ask for only what's shown — a range request beats downloading a whole archive to
        // look at its first screen.
        request.setValue("bytes=0-\(Self.maximumBytes - 1)", forHTTPHeaderField: "Range")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode,
              status == 200 || status == 206 else { return nil }
        return data
    }

    /// Recognises the handful of formats that get mistaken for text, by magic number
    /// rather than by name.
    static func describeBinary(_ data: Data) -> String? {
        let signatures: [(bytes: [UInt8], label: String)] = [
            ([0x50, 0x4B, 0x03, 0x04], "a zip archive"),
            ([0x1F, 0x8B], "a gzip archive"),
            ([0x89, 0x50, 0x4E, 0x47], "a PNG image"),
            ([0xFF, 0xD8, 0xFF], "a JPEG image"),
            ([0x49, 0x44, 0x33], "an MP3 file"),
        ]
        let head = [UInt8](data.prefix(4))
        for signature in signatures where head.starts(with: signature.bytes) {
            return "This is \(signature.label), whatever its name says — there's nothing to read here."
        }
        // A null byte in the first chunk means binary, near enough.
        return data.prefix(1024).contains(0) ? "This file is binary, not text." : nil
    }
}
