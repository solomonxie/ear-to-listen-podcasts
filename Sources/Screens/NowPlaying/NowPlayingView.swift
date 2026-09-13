import SwiftUI

struct NowPlayingView: View {
    @EnvironmentObject private var playback: PlaybackMockState
    @EnvironmentObject private var library: MockLibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .details
    @State private var showingUpNext = false

    private enum Tab: String, CaseIterable {
        case details = "Details"
        case transcript = "Transcript"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let episode = playback.currentEpisode {
                    let show = library.show(episode.showID)

                    RoundedRectangle(cornerRadius: 16)
                        .fill((show?.artColor ?? .gray).gradient)
                        .frame(height: 220)
                        .overlay { Image(systemName: show?.symbol ?? "mic.fill").font(.system(size: 64)).foregroundStyle(.white) }
                        .padding(.horizontal)

                    VStack(spacing: 4) {
                        Text(episode.title).font(.title3.bold()).multilineTextAlignment(.center)
                        Text(show?.title ?? "").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)

                    Slider(
                        value: Binding(get: { playback.progress }, set: { playback.seek(to: $0) }),
                        in: 0...max(playback.duration, 1)
                    )
                    .padding(.horizontal)

                    HStack(spacing: 48) {
                        Button { playback.skipToPrevious() } label: { Image(systemName: "backward.fill").font(.title) }
                        Button { playback.toggle() } label: {
                            Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 56))
                        }
                        Button { playback.skipToNext() } label: { Image(systemName: "forward.fill").font(.title) }
                    }

                    Picker("View", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    switch tab {
                    case .details:
                        ScrollView {
                            Text(episode.summary)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                        }
                    case .transcript:
                        TranscriptView(episode: episode, currentLineID: playback.currentTranscriptLineID)
                    }

                    Button {
                        showingUpNext = true
                    } label: {
                        Label("Up Next (\(playback.queue.count, format: .number.grouping(.never)))", systemImage: "list.bullet")
                    }
                    .padding(.bottom)
                } else {
                    Spacer()
                    ContentUnavailableView("Nothing playing", systemImage: "mic.slash")
                    Spacer()
                }
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $showingUpNext) {
                UpNextView()
            }
        }
    }
}

private struct TranscriptView: View {
    let episode: PodcastEpisode
    let currentLineID: Double?

    var body: some View {
        if episode.transcript.isEmpty {
            ContentUnavailableView("No transcript for this episode", systemImage: "text.bubble")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(episode.transcript) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.speaker).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(line.text)
                                    .font(line.id == currentLineID ? .body.weight(.semibold) : .body)
                                    .foregroundStyle(line.id == currentLineID ? .primary : .secondary)
                            }
                            .id(line.id)
                        }
                    }
                    .padding(.horizontal)
                }
                .onChange(of: currentLineID) { _, newValue in
                    guard let newValue else { return }
                    withAnimation { proxy.scrollTo(newValue, anchor: .center) }
                }
            }
        }
    }
}

private struct UpNextView: View {
    @EnvironmentObject private var playback: PlaybackMockState

    var body: some View {
        NavigationStack {
            List(playback.queue) { episode in
                Button {
                    playback.play(episode, queue: playback.queue)
                } label: {
                    HStack {
                        if episode.id == playback.currentEpisode?.id {
                            Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
                        }
                        EpisodeRow(episode: episode)
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
