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

    /// An episode with no picture of its own shows its album's, and takes the album's
    /// seed with it — so a collection without artwork is still one colour down the list
    /// rather than a different generated tile per row.
    ///
    /// The album is looked up when the caller hasn't got one to hand (`LibraryNames` holds
    /// them all in memory, so it costs nothing). Leaving that to each call site is what
    /// had the player showing one colour for an episode and Home another.
    @MainActor
    init(track: Track, album: Album? = nil, cornerRadius: CGFloat = 10, symbolSize: CGFloat = 24) {
        let collection = album ?? LibraryNames.shared.album(track.albumID)
        let ownArtwork = track.artworkFileName?.nilIfEmpty
        self.init(
            fileName: ownArtwork ?? collection?.artworkFileName?.nilIfEmpty,
            seed: ownArtwork == nil ? (collection?.id ?? track.id) : track.id,
            cornerRadius: cornerRadius, symbolSize: symbolSize
        )
    }

    init(album: Album, cornerRadius: CGFloat = 14, symbolSize: CGFloat = 48) {
        self.init(
            fileName: album.artworkFileName, seed: album.id, symbol: "square.stack.fill",
            cornerRadius: cornerRadius, symbolSize: symbolSize
        )
    }

    /// Built on a `Color.clear` the overlay fills, so the tile is exactly the size it was
    /// given. `scaledToFill` on the image alone reports the *filled* size as its own —
    /// a square picture in a frame that isn't square laid itself out square and drew past
    /// the frame, over whatever was next to it: the episode title under Now Playing's
    /// artwork, the neighbouring card on Home's shelf.
    var body: some View {
        Color.clear
            .overlay {
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
