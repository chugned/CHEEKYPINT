import SwiftUI

/// A remote image backed by the shared, de-duplicating `ImageLoader`.
///
/// Deliberately mirrors `AsyncImage`'s phase-based shape so call sites read the same, but routes
/// through `ImageLoader` so repeated URLs collapse into one download and one decode.
/// Kept out of `RemoteImage` itself: as a nested type of a generic it would be spelled
/// `RemoteImage<Content>.Phase`, so the compiler could not infer `Content` from the closure.
enum RemoteImagePhase {
    case loading
    case success(Image)
    case failure
}

struct RemoteImage<Content: View>: View {
    let url: URL?
    @ViewBuilder let content: (RemoteImagePhase) -> Content

    @State private var phase: RemoteImagePhase = .loading

    var body: some View {
        content(phase)
            .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            phase = .failure
            return
        }
        phase = .loading
        if let image = await ImageLoader.shared.image(for: url) {
            phase = .success(Image(uiImage: image))
        } else {
            phase = .failure
        }
    }
}
