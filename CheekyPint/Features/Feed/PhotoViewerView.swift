import SwiftUI

/// Full-screen viewer opened by tapping a feed post's photo (`FeedPostCard.photo`). Unlike the
/// feed tile — a fixed-height `photoHeight` band cropped with `.scaledToFill` so every card in the
/// list is the same shape — this shows the **whole** image uncropped (`.scaledToFit`), with pinch
/// zoom, pan while zoomed, and double-tap to toggle between fit and a fixed zoom level.
///
/// Reuses `RemoteImage` (not a second fetch path): post photos live in a private Supabase Storage
/// bucket, fetched with the caller's bearer token via `ImageLoader`'s `tokenProvider`/
/// `allowedTokenHost` (`ImageLoader.swift`). By the time this view opens, the feed tile's own
/// `RemoteImage` has almost always already completed the fetch for this exact URL, so this second
/// `RemoteImage` instance typically resolves instantly from `ImageLoader`'s in-memory cache rather
/// than re-fetching — but it still handles all three phases honestly (loading/success/failure) in
/// case it hasn't, or the fetch fails independently.
///
/// **Zoom-vs-dismiss gesture resolution.** A single `DragGesture` drives both panning (while
/// zoomed) and swipe-to-dismiss (while at rest): `isZoomed` gates which behaviour a one-finger
/// drag produces (see `dragGesture(in:)`), so the two are mutually exclusive by construction —
/// never simultaneously live, nothing to arbitrate between two competing recognizers. Dismissal is
/// never gesture-only, though: VoiceOver users can't reliably perform a calibrated swipe-to-
/// dismiss, so an explicit, always-present `closeButton` is the primary, guaranteed-reachable way
/// out regardless of zoom state or accessibility technology.
struct PhotoViewerView: View {
    let imageURL: URL?
    let authorName: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Committed zoom/pan state (persists between gestures). The `@GestureState` deltas below are
    // transient, merged on top of these only while a gesture is actively live, and automatically
    // reset to their defaults the moment it ends — see `dragGesture(in:)`'s doc for why that reset
    // is exactly the "spring back to rest" behaviour a non-dismissing drag needs, for free.
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var magnifyDelta: CGFloat = 1
    @GestureState private var dragDelta: CGSize = .zero

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 5
    private let doubleTapScale: CGFloat = 2.5

    /// Whether the image is currently zoomed in, for gesture-routing purposes. A small epsilon
    /// rather than `scale == 1` exactly: floating-point round trips through repeated pinches can
    /// land `scale` a hair above 1 without the user perceiving any zoom at all.
    private var isZoomed: Bool { scale > 1.01 }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Theme.Palette.photoViewerBackground
                    .ignoresSafeArea()
                    .opacity(backgroundOpacity)

                RemoteImage(url: imageURL) { phase in
                    switch phase {
                    case .loading:
                        ProgressView()
                            .tint(Theme.Palette.photoViewerControl)
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(scale * magnifyDelta)
                            .offset(x: offset.width + dragDelta.width,
                                    y: offset.height + dragDelta.height)
                            .gesture(magnifyGesture(in: geometry.size))
                            .simultaneousGesture(dragGesture(in: geometry.size))
                            .onTapGesture(count: 2) { toggleZoom() }
                            .accessibilityLabel("Photo posted by \(authorName)")
                    case .failure:
                        unavailablePlaceholder
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack {
                    HStack {
                        Spacer(minLength: 0)
                        closeButton
                    }
                    Spacer(minLength: 0)
                }
                .padding(Theme.Spacing.md)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Full-screen photo viewer")
    }

    /// Dims the backdrop as the viewer is dragged toward dismissal, so the gesture reads as
    /// interactive rather than all-or-nothing. Only active while at rest (`!isZoomed`) — while
    /// zoomed, `offset`/`dragDelta` represent panning, not a dismiss attempt, so the backdrop
    /// stays fully opaque.
    private var backgroundOpacity: Double {
        guard !isZoomed else { return 1 }
        let verticalDrag = abs(offset.height + dragDelta.height)
        return Double(max(0.35, 1 - verticalDrag / 400))
    }

    private func magnifyGesture(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .updating($magnifyDelta) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                let target = min(max(scale * value.magnification, minScale), maxScale)
                withAnimation(reduceMotion ? nil : .interactiveSpring()) {
                    if target <= 1.01 {
                        scale = 1
                        offset = .zero
                    } else {
                        scale = target
                        offset = clampedOffset(offset, scale: scale, in: size)
                    }
                }
            }
    }

    /// Drives panning while zoomed and swipe-to-dismiss while at rest from the **same** gesture
    /// recognizer, branching on `isZoomed` — see the type's doc for why that's the deliberate
    /// resolution to zoom fighting dismissal, rather than two competing gesture recognizers.
    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($dragDelta) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                if isZoomed {
                    offset = clampedOffset(
                        CGSize(width: offset.width + value.translation.width,
                               height: offset.height + value.translation.height),
                        scale: scale, in: size)
                    return
                }
                // Not zoomed: a deliberate, far-enough downward drag dismisses. Anything smaller
                // (a stray touch, a hesitant partial drag) needs no explicit "spring back" code —
                // `dragDelta` is a `@GestureState`, reset to `.zero` automatically the instant the
                // gesture ends, and `offset` was never touched while at rest, so the image and
                // backdrop return to exactly where they started with nothing left to reconcile.
                let droppedFarEnough = value.translation.height > 120
                    || value.predictedEndTranslation.height > 300
                if droppedFarEnough {
                    dismiss()
                }
            }
    }

    private func toggleZoom() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75)) {
            if isZoomed {
                scale = 1
                offset = .zero
            } else {
                scale = doubleTapScale
            }
        }
    }

    /// Keeps a zoomed image's pan within a sensible range of its own bounds rather than letting it
    /// drift entirely off-screen. `(scale - 1) * size / 2` is an approximation (it assumes the
    /// fitted image roughly fills `size` on its dominant axis), not a pixel-exact bound derived
    /// from the image's actual aspect ratio — adequate for "sensible bounds", not claimed exact.
    private func clampedOffset(_ proposed: CGSize, scale: CGFloat, in size: CGSize) -> CGSize {
        guard scale > 1 else { return .zero }
        let maxX = size.width * (scale - 1) / 2
        let maxY = size.height * (scale - 1) / 2
        return CGSize(width: min(max(proposed.width, -maxX), maxX),
                      height: min(max(proposed.height, -maxY), maxY))
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Palette.photoViewerControl)
                .frame(width: Theme.minTapTarget, height: Theme.minTapTarget)
                .background(Theme.Palette.photoViewerBackground.opacity(0.4), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("photo-viewer-close")
        .accessibilityLabel("Close")
        .accessibilityHint("Closes the full-screen photo")
    }

    /// Mirrors `FeedPostCard.photoUnavailablePlaceholder`'s honest "this isn't available right
    /// now" treatment — not reused directly, since that property is private to `FeedPostCard` and
    /// styled with `Theme.Palette.textSecondary` (an adaptive light/dark colour), which reads far
    /// too dark against this viewer's fixed black backdrop. Same icon, same wording, same
    /// accessibility label; only the foreground colour and scale differ, for the larger canvas.
    private var unavailablePlaceholder: some View {
        VStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "photo")
                .font(.system(size: 40))
            Text("Photo unavailable")
                .font(Theme.Typography.body)
        }
        .foregroundStyle(Theme.Palette.photoViewerControl)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Photo could not be loaded")
    }
}
