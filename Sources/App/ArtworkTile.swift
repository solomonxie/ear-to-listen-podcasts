import SwiftUI

/// A picture for something in the library: whatever artwork the listener picked
/// (`ImageFileStore.artwork`), falling back to the generated `LibraryArt` tile. Shared by
/// Home's shelf cards, rows, the mini player, Now Playing and album pages so all of them
/// show the same thing.
struct ArtworkTile: View {
    let fileName: String?
    let seed: String
    var symbol: String?
    var cornerRadius: CGFloat = 10
    var symbolSize: CGFloat = 24

    @State private var image: UIImage?

    init(fileName: String?, seed: String, symbol: String? = nil, cornerRadius: CGFloat = 10, symbolSize: CGFloat = 24) {
        self.fileName = fileName
        self.seed = seed
        self.symbol = symbol
        self.cornerRadius = cornerRadius
        self.symbolSize = symbolSize
    }

    init(track: Track, cornerRadius: CGFloat = 10, symbolSize: CGFloat = 24) {
        self.init(fileName: track.artworkFileName, seed: track.id, cornerRadius: cornerRadius, symbolSize: symbolSize)
    }

    init(album: Album, cornerRadius: CGFloat = 14, symbolSize: CGFloat = 48) {
        self.init(
            fileName: album.artworkFileName, seed: album.id, symbol: "square.stack.fill",
            cornerRadius: cornerRadius, symbolSize: symbolSize
        )
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle()
                    .fill(LibraryArt.color(for: seed).gradient)
                    .overlay {
                        Image(systemName: symbol ?? LibraryArt.symbol(for: seed))
                            .font(.system(size: symbolSize))
                            .foregroundStyle(.white)
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: fileName) { load() }
    }

    private func load() {
        guard let url = ImageFileStore.artwork.url(for: fileName), let data = try? Data(contentsOf: url) else {
            image = nil
            return
        }
        image = UIImage(data: data)
    }
}
