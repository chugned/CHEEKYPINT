import Foundation

extension Array where Element: Identifiable {
    /// Appends `newElements`, skipping any whose `id` is already present — either already in
    /// `self` (a row repeated across pages) or repeated within `newElements` itself (a row repeated
    /// within one page).
    ///
    /// Both keyset-paged readers in the feed need exactly this. `feed_page` and
    /// `post_comments_page` can each repeat a tied `(created_at, id)` boundary row across two pages
    /// by design — the migrations say so explicitly, and describe the failure mode as "recoverable
    /// client-side", which is only true if the client actually dedupes. `FeedViewModel.loadMore()`
    /// and `PostCommentsViewModel.loadMore()` had a private copy each; they encode one shared fact
    /// about how the server pages, so they are one function.
    ///
    /// Order-preserving and stable: the first occurrence of an id wins, so an already-displayed row
    /// keeps its position rather than being moved by a later repeat.
    mutating func appendDeduplicated(_ newElements: [Element]) {
        var seenIDs = Set(map(\.id))
        for element in newElements where !seenIDs.contains(element.id) {
            append(element)
            seenIDs.insert(element.id)
        }
    }
}
