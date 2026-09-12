import SwiftUI

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = "" {
        didSet { search() }
    }
    @Published var results: [Track] = []

    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)

    private func search() {
        results = (try? trackStore.search(query)) ?? []
    }
}

struct SearchView: View {
    @StateObject private var viewModel = SearchViewModel()
    @EnvironmentObject private var playback: PlaybackEngine

    var body: some View {
        NavigationStack {
            List(viewModel.results) { track in
                Button(track.title) {
                    playback.play(track: track, queue: viewModel.results)
                }
            }
            .navigationTitle("Search")
            .searchable(text: $viewModel.query)
        }
    }
}
