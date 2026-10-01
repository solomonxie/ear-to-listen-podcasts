import SwiftUI

/// A speaker's profile photo, or a generated portrait when there isn't one: a gradient and
/// pattern from the speaker's id with their initials on it, so every speaker is told apart at
/// a glance and keeps the same look. Shared by Home's shelf card, the detail header, and the
/// edit screen's picker so all three show the same thing.
struct SpeakerAvatar: View {
    let photoFileName: String?
    let seed: String
    let name: String
    var size: CGFloat = 90

    @State private var image: UIImage?

    init(artist: Artist, size: CGFloat = 90) {
        photoFileName = artist.photoFileName
        seed = artist.id
        self.name = artist.name
        self.size = size
    }

    var body: some View {
        placeholder
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .task(id: photoFileName) { await load() }
    }

    private var placeholder: some View {
        let style = CoverStyle(seed: seed)
        return ZStack {
            LinearGradient(colors: [style.top, style.bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
            Canvas { context, canvasSize in style.drawMotif(in: &context, size: canvasSize) }
            Text(GeneratedCover.initials(of: name))
                .font(.system(size: size * 0.36, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                .padding(size * 0.12)
        }
    }

    private func load() async {
        guard let url = ImageFileStore.speakerPhotos.url(for: photoFileName) else {
            image = nil
            return
        }
        image = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }.value
    }
}
