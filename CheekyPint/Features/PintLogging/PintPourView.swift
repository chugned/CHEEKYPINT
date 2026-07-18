import SwiftUI

/// A succulent "pour" celebration shown after logging a pint (a normal one — the welfare path
/// suppresses this per master prompt §3.6/§3.7). A glass fills with golden beer, a foam head
/// settles, bubbles rise, and a glossy shine sweeps across. Honours Reduce Motion by settling
/// straight to a full, still pint.
struct PintPourView: View {
    var onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var fill: CGFloat = 0        // 0…1 how full the glass is
    @State private var foamIn = false
    @State private var rise = false
    @State private var shineX: CGFloat = -1
    @State private var textIn = false

    private let glassSize = CGSize(width: 190, height: 280)
    private let targetFill: CGFloat = 0.82

    var body: some View {
        ZStack {
            // Dimmed, tappable backdrop.
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture { onFinished() }

            VStack(spacing: Theme.Spacing.xl) {
                glass
                Text("Pint logged. Cheers.")
                    .font(Theme.Typography.title)
                    .foregroundStyle(.white)
                    .opacity(textIn ? 1 : 0)
                    .offset(y: textIn ? 0 : 8)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Pint logged. Cheers.")
        .accessibilityAddTraits(.isModal)
        .onAppear(perform: play)
    }

    private var glass: some View {
        ZStack {
            // Beer + foam, clipped to the glass silhouette.
            GeometryReader { geo in
                let h = geo.size.height
                let beerH = h * fill
                ZStack(alignment: .bottom) {
                    // Beer body — a warm gold gradient, brighter through the middle.
                    LinearGradient(
                        colors: [Theme.Palette.beer.opacity(0.95),
                                 Theme.Palette.beer,
                                 Color(red: 0.98, green: 0.80, blue: 0.30)],
                        startPoint: .bottom, endPoint: .top)
                        .frame(height: beerH)
                        .overlay(alignment: .top) { foamHead.opacity(beerH > 24 ? 1 : 0) }
                        .overlay { bubbles(in: CGSize(width: geo.size.width, height: beerH)) }
                }
                .frame(width: geo.size.width, height: h, alignment: .bottom)
            }
            .clipShape(GlassShape())

            // Glass edges + a soft rim highlight.
            GlassShape().stroke(.white.opacity(0.9), lineWidth: 5)
            GlassShape().stroke(.white.opacity(0.25), lineWidth: 12).blur(radius: 6)

            // Glossy shine sweeping across the glass.
            shine
        }
        .frame(width: glassSize.width, height: glassSize.height)
        .shadow(color: Theme.Palette.beer.opacity(0.5), radius: 30, y: 12)
    }

    private var foamHead: some View {
        Capsule()
            .fill(Color(red: 0.99, green: 0.98, blue: 0.94))
            .frame(height: 26)
            .scaleEffect(x: foamIn ? 1 : 0.7, y: foamIn ? 1 : 0.4, anchor: .center)
            .offset(y: -13)
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    }

    private func bubbles(in size: CGSize) -> some View {
        ForEach(Bubble.seeds, id: \.id) { seed in
            Circle()
                .fill(.white.opacity(0.5))
                .frame(width: seed.size, height: seed.size)
                .offset(x: (seed.x - 0.5) * size.width,
                        y: rise ? -size.height * seed.travel : size.height * 0.35)
                .opacity(rise ? 0 : 0.9)
                .animation(reduceMotion ? nil :
                    .easeOut(duration: 1.1).delay(seed.delay).repeatCount(1, autoreverses: false), value: rise)
        }
    }

    private var shine: some View {
        GlassShape()
            .fill(
                LinearGradient(colors: [.clear, .white.opacity(0.55), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .mask(GlassShape())
            .offset(x: shineX * glassSize.width)
            .opacity(0.8)
    }

    private func play() {
        // Haptic is already fired on save; here we drive the visuals.
        if reduceMotion {
            fill = targetFill; foamIn = true; textIn = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { onFinished() }
            return
        }
        withAnimation(.easeOut(duration: 0.9)) { fill = targetFill }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.55).delay(0.55)) { foamIn = true }
        withAnimation(.easeIn(duration: 0.05)) { rise = true }
        withAnimation(.linear(duration: 1.1).delay(0.2)) { shineX = 1 }
        withAnimation(.easeOut(duration: 0.4).delay(0.85)) { textIn = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) { onFinished() }
    }
}

/// A simple tapered pint-glass silhouette (wider at the rim).
private struct GlassShape: Shape {
    func path(in rect: CGRect) -> Path {
        let topInset = rect.width * 0.05
        let bottomInset = rect.width * 0.15
        let r: CGFloat = 14
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + topInset + r, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - topInset - r, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - topInset, y: rect.minY + r),
                       control: CGPoint(x: rect.maxX - topInset, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - bottomInset, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - bottomInset - r, y: rect.maxY),
                       control: CGPoint(x: rect.maxX - bottomInset, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + bottomInset + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + bottomInset, y: rect.maxY - r),
                       control: CGPoint(x: rect.minX + bottomInset, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + topInset, y: rect.minY + r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + topInset + r, y: rect.minY),
                       control: CGPoint(x: rect.minX + topInset, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

private struct Bubble: Identifiable {
    let id = UUID()
    let x: CGFloat       // 0…1 horizontal position
    let size: CGFloat
    let delay: Double
    let travel: CGFloat  // fraction of beer height to rise

    static let seeds: [Bubble] = [
        Bubble(x: 0.30, size: 10, delay: 0.15, travel: 0.75),
        Bubble(x: 0.55, size: 7, delay: 0.35, travel: 0.85),
        Bubble(x: 0.70, size: 12, delay: 0.05, travel: 0.7),
        Bubble(x: 0.45, size: 6, delay: 0.5, travel: 0.9),
        Bubble(x: 0.62, size: 9, delay: 0.25, travel: 0.8),
    ]
}
