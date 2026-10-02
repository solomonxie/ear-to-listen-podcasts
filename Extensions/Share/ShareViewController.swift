import UIKit
import UniformTypeIdentifiers

/// "Ear to Listen" in another app's share sheet. Takes the link, says so, and goes —
/// the episode itself is made by the app the next time it's opened.
final class ShareViewController: UIViewController {
    private let message = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 16
        message.numberOfLines = 0
        message.textAlignment = .center
        message.font = .preferredFont(forTextStyle: .headline)
        message.text = String(localized: "Adding…")
        [card, message].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        view.addSubview(card)
        card.addSubview(message)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.8),
            message.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            message.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
            message.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            message.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task {
            let link = await sharedLink()
            if let link, Self.isYouTube(link) {
                ShareInbox.add(link)
                message.text = String(localized: "Added to Ear to Listen. It's in the YouTube playlist next time you open the app.")
            } else {
                message.text = String(localized: "Only YouTube links can be added.")
            }
            try? await Task.sleep(for: .seconds(1.6))
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    /// The YouTube link among what was shared — browsers send the page's URL, often with
    /// its title as text beside it, and the YouTube app sends the link as both.
    private func sharedLink() async -> String? {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        var candidates: [String] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                candidates.append(url.absoluteString)
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
               let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                candidates += text.matches(of: /https?:\/\/\S+/).map { String($0.output) }
            }
        }
        return candidates.lazy.map(Self.unwrapped).first(where: Self.isYouTube)
    }

    /// A Google result link (`google.com/url?q=…`) carries the page it points to.
    private static func unwrapped(_ link: String) -> String {
        guard let components = URLComponents(string: link), components.host?.contains("google.") == true,
              components.path == "/url",
              let target = components.queryItems?.first(where: { $0.name == "q" || $0.name == "url" })?.value
        else { return link }
        return target
    }

    private static func isYouTube(_ link: String) -> Bool {
        guard let host = URL(string: link)?.host?.lowercased() else { return false }
        return host == "youtu.be" || host.hasSuffix("youtube.com")
    }
}
