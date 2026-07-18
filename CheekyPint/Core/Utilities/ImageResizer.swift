import UIKit

/// Downscale + JPEG-encode a picked image before upload (master prompt §31 — resized image
/// uploads). Keeps avatars small and cheap to fetch.
enum ImageResizer {
    static func jpeg(from image: UIImage, maxDimension: CGFloat = 512, quality: CGFloat = 0.8) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}
