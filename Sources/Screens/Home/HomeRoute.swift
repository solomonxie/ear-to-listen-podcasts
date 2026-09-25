import SwiftUI

/// Where a card on Home goes, as a value in the stack's path rather than a view held by
/// the card itself.
///
/// `NavigationLink { SomeView() }` inside a `ForEach` over the library ties the open page
/// to the identity of the row that opened it. Home's shelves are rebuilt every time
/// anything posts `libraryDidChange` — a sync landing, an edit saved, or the term page's
/// own recount, which fires while you are reading that very page. A rebuild underneath an
/// open page leaves its back button pressing against a link being re-made in the same
/// frame: the page pops and is pushed straight back, which reads as a ‹ that does nothing
/// at all and a page with no way out.
///
/// A value in the path doesn't care what the shelf does afterwards. Same reason the
/// player routes through `PlayerRoute`.
enum HomeRoute: Hashable {
    case album(String)
    case speaker(String)
    case playlist(String)
    case fixedPlaylist(FixedPlaylist)
    case year(Int)
    case term(String)
    case allTerms
    case topic(String)
}
