import SwiftUI

enum MockData {
    static let speakers: [Speaker] = [
        Speaker(id: "alex-chen", name: "Alex Chen", bio: "Co-host of Deep Dive, covering on-device AI and developer tools."),
        Speaker(id: "priya-rao", name: "Priya Rao", bio: "Co-host of Deep Dive; also guests on Mind Wide Open."),
        Speaker(id: "jordan-lee", name: "Jordan Lee", bio: "Co-host of Retrospective, a weekly history show."),
        Speaker(id: "morgan-diaz", name: "Morgan Diaz", bio: "Co-host of Retrospective."),
        Speaker(id: "casey-kim", name: "Casey Kim", bio: "Host of Daily Brief and co-host of Comedy Hour."),
        Speaker(id: "sam-ortiz", name: "Sam Ortiz", bio: "Host of Mind Wide Open and co-host of Comedy Hour."),
    ]

    static let topics: [Topic] = [
        Topic(id: "technology", name: "Technology", color: .blue),
        Topic(id: "ai", name: "AI", color: .indigo),
        Topic(id: "history", name: "History", color: .brown),
        Topic(id: "news", name: "News", color: .red),
        Topic(id: "science", name: "Science", color: .teal),
        Topic(id: "comedy", name: "Comedy", color: .orange),
    ]

    static let shows: [PodcastShow] = [
        PodcastShow(
            id: "deep-dive", title: "Deep Dive",
            speakerIDs: ["alex-chen", "priya-rao"], year: 2024,
            topicIDs: ["technology", "ai"],
            summary: "Weekly conversations about on-device AI and developer tools.",
            artColor: .blue, symbol: "cpu"
        ),
        PodcastShow(
            id: "retrospective", title: "Retrospective",
            speakerIDs: ["jordan-lee", "morgan-diaz"], year: 2023,
            topicIDs: ["history"],
            summary: "A weekly look back at the history behind everyday things.",
            artColor: .brown, symbol: "clock.arrow.circlepath"
        ),
        PodcastShow(
            id: "daily-brief", title: "Daily Brief",
            speakerIDs: ["casey-kim"], year: 2024,
            topicIDs: ["news"],
            summary: "A short daily rundown of local-first and independent tech news.",
            artColor: .red, symbol: "newspaper.fill"
        ),
        PodcastShow(
            id: "mind-wide-open", title: "Mind Wide Open",
            speakerIDs: ["sam-ortiz", "priya-rao"], year: 2022,
            topicIDs: ["science"],
            summary: "Long-form interviews about how the brain works.",
            artColor: .teal, symbol: "brain.head.profile"
        ),
        PodcastShow(
            id: "comedy-hour", title: "Comedy Hour",
            speakerIDs: ["sam-ortiz", "casey-kim"], year: 2021,
            topicIDs: ["comedy"],
            summary: "Improvised riffs on the week's most ridiculous headlines.",
            artColor: .orange, symbol: "face.smiling.fill"
        ),
    ]

    static let episodes: [PodcastEpisode] = [
        PodcastEpisode(
            id: "ep-tech-1", showID: "deep-dive", title: "On-Device AI, For Real This Time",
            publishedYear: 2024, durationSeconds: 29,
            summary: "Alex and Priya on why small local models change what a podcast app can build.",
            audioFileName: "ep-tech-1",
            transcript: [
                TranscriptLine(startSeconds: 0.00, speaker: "Alex Chen", text: "Welcome back to Deep Dive. I'm Alex Chen."),
                TranscriptLine(startSeconds: 3.43, speaker: "Priya Rao", text: "And I'm Priya Rao. Today we're talking about on-device AI."),
                TranscriptLine(startSeconds: 7.22, speaker: "Alex Chen", text: "The big shift is models small enough to run locally, so nothing leaves your phone."),
                TranscriptLine(startSeconds: 12.52, speaker: "Priya Rao", text: "Which matters a lot once you're piping in personal data, like a podcast library."),
                TranscriptLine(startSeconds: 17.07, speaker: "Alex Chen", text: "Exactly. That's the whole idea behind Bring Your Own Podcasts. Your files, your metadata, your device."),
                TranscriptLine(startSeconds: 25.69, speaker: "Priya Rao", text: "Alright, that's our show for today. Thanks for listening."),
            ]
        ),
        PodcastEpisode(
            id: "ep-tech-0", showID: "deep-dive", title: "Why Local-First Won",
            publishedYear: 2024, durationSeconds: 1860,
            summary: "A look at the apps that made local-first storage mainstream.",
            audioFileName: nil, transcript: []
        ),
        PodcastEpisode(
            id: "ep-history-1", showID: "retrospective", title: "A Short History of the Podcast",
            publishedYear: 2023, durationSeconds: 25,
            summary: "Jordan and Morgan trace the format back to RSS feeds and the first iPod.",
            audioFileName: "ep-history-1",
            transcript: [
                TranscriptLine(startSeconds: 0.00, speaker: "Jordan Lee", text: "This is Retrospective. I'm Jordan Lee."),
                TranscriptLine(startSeconds: 3.11, speaker: "Morgan Diaz", text: "And I'm Morgan Diaz. This week: the history of the podcast format."),
                TranscriptLine(startSeconds: 7.33, speaker: "Jordan Lee", text: "It really started with RSS feeds in the early 2000s, before anyone called it a podcast."),
                TranscriptLine(startSeconds: 14.19, speaker: "Morgan Diaz", text: "The name itself is a mashup of iPod and broadcast, which feels almost quaint now."),
                TranscriptLine(startSeconds: 18.96, speaker: "Jordan Lee", text: "Funny how the medium outlived the device it was named after."),
                TranscriptLine(startSeconds: 22.60, speaker: "Morgan Diaz", text: "That's it for today. See you next week."),
            ]
        ),
        PodcastEpisode(
            id: "ep-history-0", showID: "retrospective", title: "The First Radio Broadcast",
            publishedYear: 2023, durationSeconds: 1620,
            summary: "How early radio set the template every audio format since has copied.",
            audioFileName: nil, transcript: []
        ),
        PodcastEpisode(
            id: "ep-news-1", showID: "daily-brief", title: "Local-First Is Having a Moment",
            publishedYear: 2024, durationSeconds: 12,
            summary: "Casey on why more apps are keeping data on your own storage.",
            audioFileName: "ep-news-1",
            transcript: [
                TranscriptLine(startSeconds: 0.00, speaker: "Casey Kim", text: "You're listening to Daily Brief. I'm Casey Kim."),
                TranscriptLine(startSeconds: 2.74, speaker: "Casey Kim", text: "Today's top story: local-first apps are having a moment."),
                TranscriptLine(startSeconds: 6.08, speaker: "Casey Kim", text: "More people want their data to live on their own storage, not a vendor's server."),
                TranscriptLine(startSeconds: 10.19, speaker: "Casey Kim", text: "That's a wrap for today's brief."),
            ]
        ),
        PodcastEpisode(
            id: "ep-science-0", showID: "mind-wide-open", title: "How Memory Actually Works",
            publishedYear: 2022, durationSeconds: 2760,
            summary: "Sam and guest Priya Rao on memory consolidation during sleep.",
            audioFileName: nil, transcript: []
        ),
        PodcastEpisode(
            id: "ep-comedy-0", showID: "comedy-hour", title: "The Group Chat Episode",
            publishedYear: 2021, durationSeconds: 2100,
            summary: "Sam and Casey riff on group chat etiquette.",
            audioFileName: nil, transcript: []
        ),
    ]

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        DateComponents(calendar: .current, year: year, month: month, day: day).date!
    }

    static let albums: [PodcastAlbum] = [
        PodcastAlbum(
            id: "album-best-of-2024", title: "Best of 2024",
            speakerIDs: ["alex-chen", "priya-rao", "casey-kim"],
            description: "A compilation of the year's standout episodes, pulled from across every show.",
            releaseDate: date(2024, 12, 20),
            episodeIDs: ["ep-tech-1", "ep-news-1"],
            artColor: .purple, symbol: "star.fill"
        ),
        PodcastAlbum(
            id: "album-origins", title: "Origins",
            speakerIDs: ["jordan-lee", "morgan-diaz"],
            description: "A special release tracing where our favorite formats began.",
            releaseDate: date(2023, 9, 14),
            episodeIDs: ["ep-history-1", "ep-history-0"],
            artColor: .brown, symbol: "book.closed.fill"
        ),
    ]

    static let defaultPlaylists: [PlaylistUI] = [
        PlaylistUI(id: "pl-commute", name: "Commute Mix", episodeIDs: ["ep-tech-1", "ep-news-1"], coverColors: [.blue, .red]),
        PlaylistUI(id: "pl-longform", name: "Weekend Longform", episodeIDs: ["ep-science-0", "ep-history-0"], coverColors: [.teal, .brown]),
        PlaylistUI(id: "pl-quick", name: "Quick Hits", episodeIDs: ["ep-news-1", "ep-tech-1", "ep-history-1"], coverColors: [.orange, .indigo]),
    ]

}

@MainActor
final class MockLibraryStore: ObservableObject {
    static let shared = MockLibraryStore()

    @Published private(set) var shows: [PodcastShow] = MockData.shows
    @Published private(set) var episodes: [PodcastEpisode] = MockData.episodes
    @Published private(set) var speakers: [Speaker] = MockData.speakers
    @Published private(set) var topics: [Topic] = MockData.topics
    @Published private(set) var albums: [PodcastAlbum] = MockData.albums
    @Published var playlists: [PlaylistUI] = MockData.defaultPlaylists
    @Published var savedShowIDs: Set<String> = ["deep-dive", "retrospective"]
    @Published var downloadedEpisodeIDs: Set<String> = ["ep-tech-1"]

    private init() {}

    func resetToDefaults() {
        shows = MockData.shows
        episodes = MockData.episodes
        speakers = MockData.speakers
        topics = MockData.topics
        albums = MockData.albums
        playlists = MockData.defaultPlaylists
        savedShowIDs = ["deep-dive", "retrospective"]
        downloadedEpisodeIDs = ["ep-tech-1"]
    }

    func show(_ id: String) -> PodcastShow? { shows.first { $0.id == id } }
    func speaker(_ id: String) -> Speaker? { speakers.first { $0.id == id } }
    func album(_ id: String) -> PodcastAlbum? { albums.first { $0.id == id } }
    func episodes(forShow showID: String) -> [PodcastEpisode] { episodes.filter { $0.showID == showID } }
    func episodes(forAlbum album: PodcastAlbum) -> [PodcastEpisode] {
        album.episodeIDs.compactMap { id in episodes.first { $0.id == id } }
    }
    func episodes(forSpeaker speakerID: String) -> [PodcastEpisode] {
        let showIDs = Set(shows.filter { $0.speakerIDs.contains(speakerID) }.map(\.id))
        return episodes.filter { showIDs.contains($0.showID) || $0.extraSpeakerIDs.contains(speakerID) }
    }
    func episodes(inPlaylist playlist: PlaylistUI) -> [PodcastEpisode] {
        playlist.episodeIDs.compactMap { id in episodes.first { $0.id == id } }
    }
    func albums(forSpeaker speakerID: String) -> [PodcastAlbum] {
        albums.filter { $0.speakerIDs.contains(speakerID) }
    }
    /// Whether a speaker is credited on an episode via its show, rather than a manual link.
    func isSpeakerCreditedViaShow(_ speakerID: String, episodeID: String) -> Bool {
        guard let episode = episodes.first(where: { $0.id == episodeID }),
              let show = show(episode.showID) else { return false }
        return show.speakerIDs.contains(speakerID)
    }

    func createPlaylist(name: String) {
        let palette: [Color] = [.blue, .purple, .teal, .orange, .pink]
        playlists.insert(PlaylistUI(id: UUID().uuidString, name: name, episodeIDs: [], coverColors: [palette.randomElement()!, palette.randomElement()!]), at: 0)
    }

    func deletePlaylist(id: String) {
        playlists.removeAll { $0.id == id }
    }

    func updateSpeaker(id: String, name: String, bio: String) {
        guard let index = speakers.firstIndex(where: { $0.id == id }) else { return }
        speakers[index].name = name
        speakers[index].bio = bio
    }

    func setSpeaker(_ speakerID: String, linkedToAlbum albumID: String, linked: Bool) {
        guard let index = albums.firstIndex(where: { $0.id == albumID }) else { return }
        if linked {
            if !albums[index].speakerIDs.contains(speakerID) { albums[index].speakerIDs.append(speakerID) }
        } else {
            albums[index].speakerIDs.removeAll { $0 == speakerID }
        }
    }

    func setSpeaker(_ speakerID: String, linkedToEpisode episodeID: String, linked: Bool) {
        guard let index = episodes.firstIndex(where: { $0.id == episodeID }) else { return }
        if linked {
            if !episodes[index].extraSpeakerIDs.contains(speakerID) { episodes[index].extraSpeakerIDs.append(speakerID) }
        } else {
            episodes[index].extraSpeakerIDs.removeAll { $0 == speakerID }
        }
    }
}
