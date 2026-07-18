import SwiftUI

/// Full-screen beer overflow shown after a normal pint log. The sheet saves immediately; this
/// overlay is the reward: beer rushes in from every edge and stamps the group-chat score.
struct PintPourView: View {
    var onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var flood = false
    @State private var foam = false
    @State private var textIn = false
    @State private var bubbles = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.38)
                    .ignoresSafeArea()
                    .onTapGesture { onFinished() }

                overflow(in: geo.size)
                foamSplashes(in: geo.size)
                bubbleField(in: geo.size)

                Text("+1 succelance")
                    .font(.system(size: 44, weight: .black, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.72)
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .scaleEffect(textIn ? 1 : 0.74)
                    .opacity(textIn ? 1 : 0)
            }
            .ignoresSafeArea()
        }
        .accessibilityElement()
        .accessibilityLabel("Plus one succelance")
        .accessibilityAddTraits(.isModal)
        .onAppear(perform: play)
    }

    private func overflow(in size: CGSize) -> some View {
        ZStack {
            beerPanel
                .frame(width: size.width, height: size.height)
                .scaleEffect(x: 1, y: flood ? 1 : 0.001, anchor: .top)

            beerPanel
                .frame(width: size.width, height: size.height)
                .scaleEffect(x: 1, y: flood ? 1 : 0.001, anchor: .bottom)

            beerPanel
                .frame(width: size.width, height: size.height)
                .scaleEffect(x: flood ? 1 : 0.001, y: 1, anchor: .leading)

            beerPanel
                .frame(width: size.width, height: size.height)
                .scaleEffect(x: flood ? 1 : 0.001, y: 1, anchor: .trailing)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private var beerPanel: some View {
        LinearGradient(
            colors: [
                Color(red: 0.74, green: 0.42, blue: 0.08).opacity(0.96),
                Theme.Palette.beer,
                Color(red: 1.0, green: 0.78, blue: 0.24).opacity(0.98),
            ],
            startPoint: .bottom,
            endPoint: .top
        )
        .overlay {
            LinearGradient(
                colors: [.white.opacity(0.24), .clear, .white.opacity(0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private func foamSplashes(in size: CGSize) -> some View {
        ZStack {
            foamBar(width: size.width * 0.86)
                .offset(y: foam ? -size.height * 0.43 : -size.height * 0.62)
            foamBar(width: size.width * 0.78)
                .offset(y: foam ? size.height * 0.43 : size.height * 0.62)

            ForEach(FoamDrop.seeds) { drop in
                Circle()
                    .fill(Color(red: 1.0, green: 0.96, blue: 0.82).opacity(drop.opacity))
                    .frame(width: drop.size, height: drop.size)
                    .offset(
                        x: (drop.x - 0.5) * size.width,
                        y: foam ? (drop.y - 0.5) * size.height : drop.startOffset(in: size)
                    )
                    .scaleEffect(foam ? 1 : 0.55)
            }
        }
    }

    private func foamBar(width: CGFloat) -> some View {
        Capsule()
            .fill(Color(red: 1.0, green: 0.96, blue: 0.82))
            .frame(width: width, height: 30)
            .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
    }

    private func bubbleField(in size: CGSize) -> some View {
        ForEach(Bubble.seeds) { bubble in
            Circle()
                .fill(.white.opacity(0.42))
                .frame(width: bubble.size, height: bubble.size)
                .offset(
                    x: (bubble.x - 0.5) * size.width,
                    y: bubbles ? (bubble.y - 0.62) * size.height : (bubble.y - 0.2) * size.height
                )
                .opacity(bubbles ? 0 : 0.95)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: bubble.duration).delay(bubble.delay),
                    value: bubbles
                )
        }
    }

    private func play() {
        if reduceMotion {
            flood = true
            foam = true
            textIn = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) { onFinished() }
            return
        }

        withAnimation(.easeOut(duration: 0.55)) { flood = true }
        withAnimation(.spring(response: 0.48, dampingFraction: 0.58).delay(0.12)) { foam = true }
        withAnimation(.easeIn(duration: 0.05).delay(0.18)) { bubbles = true }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.52).delay(0.22)) { textIn = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.65) { onFinished() }
    }
}

private struct FoamDrop: Identifiable {
    let id = UUID()
    let x: CGFloat
    let y: CGFloat
    let size: CGFloat
    let opacity: Double

    func startOffset(in size: CGSize) -> CGFloat {
        y < 0.5 ? -size.height * 0.55 : size.height * 0.55
    }

    static let seeds: [FoamDrop] = [
        FoamDrop(x: 0.10, y: 0.18, size: 44, opacity: 0.92),
        FoamDrop(x: 0.28, y: 0.09, size: 28, opacity: 0.82),
        FoamDrop(x: 0.54, y: 0.14, size: 38, opacity: 0.90),
        FoamDrop(x: 0.80, y: 0.10, size: 32, opacity: 0.84),
        FoamDrop(x: 0.92, y: 0.24, size: 48, opacity: 0.88),
        FoamDrop(x: 0.14, y: 0.76, size: 52, opacity: 0.88),
        FoamDrop(x: 0.36, y: 0.88, size: 34, opacity: 0.82),
        FoamDrop(x: 0.66, y: 0.84, size: 42, opacity: 0.90),
        FoamDrop(x: 0.88, y: 0.78, size: 30, opacity: 0.84),
    ]
}

private struct Bubble: Identifiable {
    let id = UUID()
    let x: CGFloat
    let y: CGFloat
    let size: CGFloat
    let delay: Double
    let duration: Double

    static let seeds: [Bubble] = [
        Bubble(x: 0.12, y: 0.70, size: 8, delay: 0.05, duration: 0.90),
        Bubble(x: 0.20, y: 0.54, size: 13, delay: 0.12, duration: 1.05),
        Bubble(x: 0.31, y: 0.82, size: 7, delay: 0.18, duration: 0.86),
        Bubble(x: 0.42, y: 0.63, size: 11, delay: 0.08, duration: 1.00),
        Bubble(x: 0.55, y: 0.76, size: 9, delay: 0.16, duration: 0.92),
        Bubble(x: 0.68, y: 0.58, size: 14, delay: 0.10, duration: 1.08),
        Bubble(x: 0.76, y: 0.86, size: 8, delay: 0.22, duration: 0.88),
        Bubble(x: 0.88, y: 0.66, size: 12, delay: 0.14, duration: 0.96),
    ]
}
