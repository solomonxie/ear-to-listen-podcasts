import SwiftUI

/// A speaker's profile photo (or the person-icon placeholder when there isn't one),
/// loaded off `ImageFileStore.speakerPhotos` by filename. Shared by Home's shelf card, the detail
/// header, and the edit screen's picker so all three show the same thing.
struct SpeakerAvatar: View {
    let photoFileName: String?
    var size: CGFloat = 90

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(Color.secondary.opacity(0.3))
        .clipShape(Circle())
        .task(id: photoFileName) { load() }
    }

    private func load() {
        guard let url = ImageFileStore.speakerPhotos.url(for: photoFileName), let data = try? Data(contentsOf: url) else {
            image = nil
            return
        }
        image = UIImage(data: data)
    }
}
