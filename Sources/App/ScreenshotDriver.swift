#if SCREENSHOTS
import SwiftUI
import GRDB

/// Screenshot builds only: `-screen home|terms|settings|album|speaker|playlist|player|transcript`.
@MainActor
enum ScreenshotDriver {
    static func run(path: Binding<NavigationPath>, openPlayer: (PlayerLanding?) -> Void) async {
        guard let screen = UserDefaults.standard.string(forKey: "screen") else { return }
        if !DemoMode.isOn { try? DemoMode.enter() }
        try? await Task.sleep(for: .seconds(6))
        let db = DatabaseManager.shared.dbQueue
        switch screen {
        case "terms": path.wrappedValue.append(HomeRoute.allTerms)
        case "settings": path.wrappedValue.append(HomeRoute.settings)
        case "album": if let a = try? await db.read({ try Album.fetchOne($0) }) { path.wrappedValue.append(HomeRoute.album(a.id)) }
        case "speaker": if let a = try? await db.read({ try Artist.fetchOne($0) }) { path.wrappedValue.append(HomeRoute.speaker(a.id)) }
        case "playlist": if let p = try? await db.read({ try Playlist.fetchOne($0) }) { path.wrappedValue.append(HomeRoute.playlist(p.id)) }
        case "player", "transcript":
            guard let t = try? await db.read({ try Track.fetchOne($0) }) else { return }
            PlaybackEngine.shared.play(track: t)
            openPlayer(screen == "transcript" ? .following : nil)
        default: break
        }
    }
}
#endif
