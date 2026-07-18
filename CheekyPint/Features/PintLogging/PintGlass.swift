import SwiftUI

/// The tapered pint-glass silhouette (wider at the rim), shared by the Home log button and the
/// pour celebration so they always look like the same glass.
struct PintGlassShape: Shape {
    func path(in rect: CGRect) -> Path {
        let topInset = rect.width * 0.05
        let bottomInset = rect.width * 0.15
        let r: CGFloat = min(14, rect.width * 0.08)
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

extension ShapeStyle where Self == LinearGradient {
    /// The succulent golden-beer gradient (brighter through the middle), used for fills.
    static var beerGradient: LinearGradient {
        LinearGradient(
            colors: [Theme.Palette.beer.opacity(0.95),
                     Theme.Palette.beer,
                     Color(red: 0.98, green: 0.80, blue: 0.30)],
            startPoint: .bottom, endPoint: .top)
    }
}

/// A static, succulent pint — golden beer, a cream foam head, and a glass shine. This is the
/// face of the Home "Log a pint" button, so the button itself is a proper pint.
struct PintGlass: View {
    /// How full the glass is, 0…1.
    var fill: CGFloat = 0.82
    /// Rim + shine stroke colour (defaults to a bright glass white).
    var edge: Color = .white

    var body: some View {
        ZStack {
            GeometryReader { geo in
                let h = geo.size.height
                let beerH = h * fill
                ZStack(alignment: .bottom) {
                    Rectangle()
                        .fill(.beerGradient)
                        .frame(height: beerH)
                        .overlay(alignment: .top) {
                            Capsule()
                                .fill(Color(red: 0.99, green: 0.98, blue: 0.94))
                                .frame(height: max(14, h * 0.12))
                                .offset(y: -max(7, h * 0.06))
                                .opacity(beerH > 16 ? 1 : 0)
                        }
                }
                .frame(width: geo.size.width, height: h, alignment: .bottom)
            }
            .clipShape(PintGlassShape())

            // Glass edges + a soft inner rim highlight.
            PintGlassShape().stroke(edge.opacity(0.95), lineWidth: 4)
            PintGlassShape().stroke(edge.opacity(0.22), lineWidth: 10).blur(radius: 4)

            // A fixed diagonal gloss so the static glass still looks wet.
            PintGlassShape()
                .fill(LinearGradient(colors: [.white.opacity(0.45), .clear],
                                     startPoint: .topLeading, endPoint: .center))
                .opacity(0.6)
        }
        .accessibilityHidden(true)
    }
}
