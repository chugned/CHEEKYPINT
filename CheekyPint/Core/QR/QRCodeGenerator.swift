import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Generates a crisp QR code image for a deep link. Uses Core Image (no dependency). The QR
/// only ever encodes an opaque token URL — never personal data (master prompt §8).
enum QRCodeGenerator {
    static func image(for url: URL, scale: CGFloat = 12) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// SwiftUI wrapper that renders a friend/session QR with the pub palette.
struct QRCodeView: View {
    let url: URL
    var body: some View {
        Group {
            if let image = QRCodeGenerator.image(for: url) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(Theme.Spacing.md)
                    .background(.white, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                    .accessibilityLabel("Your CheekyPint friend QR code")
            } else {
                StatusView(systemImage: "qrcode", title: "Couldn't create your code", message: "Try again in a moment.")
            }
        }
    }
}
