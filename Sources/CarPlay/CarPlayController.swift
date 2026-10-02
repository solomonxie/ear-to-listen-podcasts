import CarPlay
import Combine
import UIKit

/// Everything on the car screen: three tabs of lists and the shared Now Playing page.
/// A second remote for `PlaybackEngine`, never a second player.
///
/// Every list on screen is registered with the function that builds it, so one refresh
/// rebuilds whatever is showing, pushed pages included, in place.
@MainActor
final class CarPlayController: NSObject {
    private let interface: CPInterfaceController
    private let engine = PlaybackEngine.shared
    private let library = CarLibrary()
    private var snapshot = CarLibrary.Snapshot()
    private var lists: [LiveList] = []
    private var subscriptions: Set<AnyCancellable> = []
    private var refreshTask: Task<Void, Never>?
    private var bookmarkFlash: Task<Void, Never>?

    private struct LiveList {
        weak var template: CPListTemplate?
        let build: @MainActor () async -> [CPListSection]
    }

    private var limit: Int { Int(CPListTemplate.maximumItemCount) }
    private var imageSize: CGSize { CPListItem.maximumImageSize }

    init(interface: CPInterfaceController) {
        self.interface = interface
    }

    func start() {
        let tabs = CPTabBarTemplate(templates: [listenNowTab(), libraryTab(), bookmarksTab()])
        interface.setRootTemplate(tabs, animated: false, completion: nil)
        configureNowPlaying()
        observe()
        Task { await refresh() }
    }

    func stop() {
        subscriptions.removeAll()
        refreshTask?.cancel()
        bookmarkFlash?.cancel()
        CPNowPlayingTemplate.shared.remove(self)
    }

    // MARK: Refresh

    private func observe() {
        let center = NotificationCenter.default
        Publishers.Merge(
            center.publisher(for: .libraryDidChange).map { _ in () },
            center.publisher(for: .bookmarksDidChange).map { _ in () }
        )
        .merge(with: engine.$currentTrack.map { $0?.id }.removeDuplicates().dropFirst().map { _ in () })
        .merge(with: engine.$isPlaying.removeDuplicates().dropFirst().map { _ in () })
        .sink { [weak self] in MainActor.assumeIsolated { self?.refreshSoon() } }
        .store(in: &subscriptions)

        engine.$lastError.compactMap { $0 }
            .sink { [weak self] message in MainActor.assumeIsolated { self?.showError(message) } }
            .store(in: &subscriptions)
    }

    /// `libraryDidChange` fires per imported file; one rebuild per burst.
    private func refreshSoon() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func refresh() async {
        snapshot = await library.snapshot()
        lists.removeAll { $0.template == nil }
        for list in lists {
            let sections = await list.build()
            list.template?.updateSections(sections)
        }
    }

    private func register(_ template: CPListTemplate, build: @escaping @MainActor () async -> [CPListSection]) {
        lists.append(LiveList(template: template, build: build))
    }

    private func push(title: String, build: @escaping @MainActor () async -> [CPListSection]) {
        let template = CPListTemplate(title: title, sections: [])
        register(template, build: build)
        interface.pushTemplate(template, animated: true, completion: nil)
        Task { template.updateSections(await build()) }
    }

    // MARK: Tabs

    private func listenNowTab() -> CPListTemplate {
        let template = CPListTemplate(title: String(localized: "Listen Now"), sections: [])
        template.tabTitle = String(localized: "Listen Now")
        template.tabImage = UIImage(systemName: "play.circle")
        template.emptyViewTitleVariants = [String(localized: "No episodes yet")]
        template.emptyViewSubtitleVariants = [String(localized: "Add a source on your iPhone.")]
        register(template) { [weak self] in
            guard let self else { return [] }
            let resume = Array(snapshot.continueListening.prefix(limit / 2))
            let later = Array(snapshot.listenLater.prefix(limit - resume.count))
            var sections: [CPListSection] = []
            if !resume.isEmpty {
                // Just the episode: the engine queues its collection around it.
                let items = resume.map { track in episodeItem(track) { [track] } }
                sections.append(CPListSection(items: items, header: String(localized: "Continue Listening"), sectionIndexTitle: nil))
            }
            if !later.isEmpty {
                let items = later.map { track in episodeItem(track) { later } }
                sections.append(CPListSection(items: items, header: String(localized: "Listen Later"), sectionIndexTitle: nil))
            }
            return sections
        }
        return template
    }

    private func libraryTab() -> CPListTemplate {
        let template = CPListTemplate(title: String(localized: "Library"), sections: [])
        template.tabTitle = String(localized: "Library")
        template.tabImage = UIImage(systemName: "square.stack")
        register(template) { [weak self] in
            guard let self else { return [] }
            let rows = [
                menuItem(String(localized: "Favorites"), symbol: "heart") { [weak self] in
                    self?.pushEpisodes(String(localized: "Favorites")) { self?.snapshot.favorites ?? [] }
                },
                menuItem(String(localized: "Downloaded"), symbol: "arrow.down.circle") { [weak self] in
                    self?.pushEpisodes(String(localized: "Downloaded")) { self?.snapshot.downloaded ?? [] }
                },
                menuItem(String(localized: "Playlists"), symbol: "music.note.list") { [weak self] in self?.pushPlaylists() },
                menuItem(String(localized: "Collections"), symbol: "square.stack") { [weak self] in self?.pushCollections() },
                menuItem(String(localized: "Speakers"), symbol: "person.wave.2") { [weak self] in self?.pushSpeakers() },
            ]
            return [CPListSection(items: rows)]
        }
        return template
    }

    private func bookmarksTab() -> CPListTemplate {
        let template = CPListTemplate(title: String(localized: "Bookmarks"), sections: [])
        template.tabTitle = String(localized: "Bookmarks")
        template.tabImage = UIImage(systemName: "bookmark")
        template.emptyViewTitleVariants = [String(localized: "No bookmarks yet")]
        template.emptyViewSubtitleVariants = [String(localized: "Tap the bookmark while playing to mark a moment.")]
        register(template) { [weak self] in
            guard let self else { return [] }
            let items: [CPListItem] = snapshot.bookmarks.prefix(limit).compactMap { mark in
                guard let track = self.snapshot.tracksByID[mark.trackID] else { return nil }
                let said = mark.note?.nilIfEmpty ?? mark.transcriptText?.nilIfEmpty
                let item = CPListItem(text: "\(Scrubber.formatted(mark.position)) · \(track.title)", detailText: said)
                setImage(of: item, for: track)
                item.handler = { [weak self] _, completion in
                    MainActor.assumeIsolated {
                        self?.engine.play(track: track, queue: [track], startingAt: mark.position)
                        self?.showNowPlaying()
                    }
                    completion()
                }
                return item
            }
            return items.isEmpty ? [] : [CPListSection(items: items)]
        }
        return template
    }

    // MARK: Library pages

    private func pushPlaylists() {
        push(title: String(localized: "Playlists")) { [weak self] in
            guard let self else { return [] }
            let items = snapshot.playlists.prefix(limit).map { playlist in
                let item = CPListItem(text: playlist.name, detailText: nil, image: UIImage(systemName: "music.note.list"))
                item.accessoryType = .disclosureIndicator
                item.handler = selecting { [weak self] in
                    self?.pushEpisodes(playlist.name, anchorsAtUnplayed: true) {
                        await self?.library.episodes(of: .playlist(playlist.id)) ?? []
                    }
                }
                return item
            }
            return [CPListSection(items: items)]
        }
    }

    private func pushCollections() {
        push(title: String(localized: "Collections")) { [weak self] in
            guard let self else { return [] }
            let items = snapshot.collections.prefix(limit).map { album in
                let speaker = album.artistID.flatMap { self.snapshot.speakerNames[$0] }
                let item = CPListItem(text: album.name, detailText: speaker)
                item.accessoryType = .disclosureIndicator
                let size = imageSize
                Task { item.setImage(await CarArtwork.image(for: album, size: size)) }
                item.handler = selecting { [weak self] in
                    self?.pushEpisodes(album.name, anchorsAtUnplayed: true) {
                        await self?.library.episodes(of: .collection(album.id)) ?? []
                    }
                }
                return item
            }
            return [CPListSection(items: items)]
        }
    }

    private func pushSpeakers() {
        push(title: String(localized: "Speakers")) { [weak self] in
            guard let self else { return [] }
            let items = snapshot.speakers.prefix(limit).map { artist in
                let item = CPListItem(text: artist.name, detailText: nil)
                item.accessoryType = .disclosureIndicator
                let size = imageSize
                Task { item.setImage(await CarArtwork.image(forSpeaker: artist, size: size)) }
                item.handler = selecting { [weak self] in self?.pushSpeaker(artist) }
                return item
            }
            return [CPListSection(items: items)]
        }
    }

    private func pushSpeaker(_ artist: Artist) {
        pushEpisodes(artist.name) { [weak self] in
            await self?.library.episodes(of: .speaker(artist.id)) ?? []
        }
    }

    /// An episode list. The whole list is the queue; only a window of it is shown.
    private func pushEpisodes(
        _ title: String, anchorsAtUnplayed: Bool = false,
        load: @escaping @MainActor () async -> [Track]
    ) {
        push(title: title) { [weak self] in
            guard let self else { return [] }
            let tracks = await load()
            let firstUnplayed = anchorsAtUnplayed ? tracks.firstIndex { $0.listenedAt == nil } : nil
            let shown = CarLibrary.window(tracks.count, firstUnplayed: firstUnplayed, limit: limit)
            let items = tracks[shown].map { track in episodeItem(track) { tracks } }
            let header = shown.count < tracks.count
                ? String(localized: "Showing \(shown.lowerBound + 1)–\(shown.upperBound) of \(tracks.count)")
                : nil
            return [CPListSection(items: items, header: header, sectionIndexTitle: nil)]
        }
    }

    // MARK: Items

    private func episodeItem(_ track: Track, queue: @escaping @MainActor () -> [Track]) -> CPListItem {
        let speaker = track.artistID.flatMap { snapshot.speakerNames[$0] }
        let item = CPListItem(text: track.title, detailText: CarLibrary.detail(for: track, speaker: speaker))
        item.isPlaying = engine.currentTrack?.id == track.id
        item.playingIndicatorLocation = .trailing
        if let progress = CarLibrary.progress(of: track) { item.playbackProgress = progress }
        if snapshot.isCloud(track) { item.accessoryType = .cloud }
        setImage(of: item, for: track)
        item.handler = selecting { [weak self] in
            self?.engine.play(track: track, queue: queue())
            self?.showNowPlaying()
        }
        return item
    }

    private func menuItem(_ title: String, symbol: String, action: @escaping @MainActor () -> Void) -> CPListItem {
        let item = CPListItem(text: title, detailText: nil, image: UIImage(systemName: symbol))
        item.accessoryType = .disclosureIndicator
        item.handler = selecting(action)
        return item
    }

    private func setImage(of item: CPListItem, for track: Track) {
        let album = track.albumID.flatMap { snapshot.albumsByID[$0] }
        let size = imageSize
        Task { item.setImage(await CarArtwork.image(for: track, album: album, size: size)) }
    }

    /// CarPlay calls row handlers on the main thread but doesn't say so to the compiler.
    private func selecting(
        _ action: @escaping @MainActor () -> Void
    ) -> (any CPSelectableListItem, @escaping () -> Void) -> Void {
        { _, completion in
            MainActor.assumeIsolated { action() }
            completion()
        }
    }

    // MARK: Now Playing

    private func configureNowPlaying() {
        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.isUpNextButtonEnabled = true
        nowPlaying.upNextTitle = String(localized: "Up Next")
        nowPlaying.isAlbumArtistButtonEnabled = true
        nowPlaying.add(self)
        nowPlaying.updateNowPlayingButtons([bookmarkButton(filled: false)])
    }

    private func showNowPlaying() {
        guard interface.topTemplate !== CPNowPlayingTemplate.shared else { return }
        interface.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    /// A mark has no count badge or toast here, as the template has neither: the glyph
    /// fills for a moment, and that is the receipt.
    private func bookmarkButton(filled: Bool) -> CPNowPlayingImageButton {
        let image = UIImage(systemName: filled ? "bookmark.fill" : "bookmark") ?? UIImage()
        return CPNowPlayingImageButton(image: image) { [weak self] _ in
            MainActor.assumeIsolated { self?.markMoment() }
        }
    }

    private func markMoment() {
        guard let track = engine.currentTrack, MomentMark.add(to: track, at: engine.currentTime) != nil else { return }
        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.updateNowPlayingButtons([bookmarkButton(filled: true)])
        bookmarkFlash?.cancel()
        bookmarkFlash = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            nowPlaying.updateNowPlayingButtons([bookmarkButton(filled: false)])
        }
    }

    private func pushUpNext() {
        push(title: String(localized: "Up Next")) { [weak self] in
            guard let self else { return [] }
            let queue = engine.queue
            let current = engine.currentTrack.flatMap { now in queue.firstIndex { $0.id == now.id } }
            let shown = CarLibrary.window(queue.count, firstUnplayed: current, limit: limit)
            let items = queue[shown].map { track in episodeItem(track) { queue } }
            return [CPListSection(items: items)]
        }
    }

    // MARK: Errors

    private func showError(_ message: String) {
        guard interface.presentedTemplate == nil else { return }
        let text = NetworkMonitor.shared.isConnected
            ? message
            : String(localized: "This episode isn't downloaded. Connect to the internet to play it.")
        let ok = CPAlertAction(title: String(localized: "OK"), style: .cancel) { [weak self] _ in
            MainActor.assumeIsolated { self?.interface.dismissTemplate(animated: true, completion: nil) }
        }
        interface.presentTemplate(CPAlertTemplate(titleVariants: [text], actions: [ok]), animated: true, completion: nil)
    }
}

extension CarPlayController: CPNowPlayingTemplateObserver {
    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        MainActor.assumeIsolated { pushUpNext() }
    }

    nonisolated func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        MainActor.assumeIsolated {
            guard let id = engine.currentTrack?.artistID,
                  let artist = snapshot.speakers.first(where: { $0.id == id }) else { return }
            pushSpeaker(artist)
        }
    }
}
