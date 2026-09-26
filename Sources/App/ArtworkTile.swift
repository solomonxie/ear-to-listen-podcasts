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

    /// The generated tile is the base and the picture is laid over it, rather than the
    /// picture being the view.
    ///
    /// Two reasons. `scaledToFill` on the image alone reports the *filled* size as its
    /// own, so a square picture in a frame that isn't square laid itself out square and
    /// drew past the frame — over the episode title under Now Playing's artwork, over the
    /// neighbouring card on Home's shelf. A greedy base takes exactly the size it was
    /// given and the clip does the rest. And whatever happens to the picture — file gone,
    /// bytes unreadable, nothing decoded yet — what's underneath is a coloured tile rather
    /// than a hole the background shows through.
    var body: some View {
        Rectangle()
            .fill(LibraryArt.color(for: seed).gradient)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: symbol ?? LibraryArt.symbol(for: seed))
                        .font(.system(size: symbolSize))
                        .foregroundStyle(.white)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .task(id: fileName) { await load() }
    }

    /// Read and decoded off the main thread. It is an 800pt JPEG on the player page and
    /// one per row in a list, and doing either where the frames are drawn is a page that
    /// hitches as its pictures arrive.
    private func load() async {
        guard let url = ImageFileStore.artwork.url(for: fileName) else {
            image = nil
            return
        }
        image = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }.value
    }
}
