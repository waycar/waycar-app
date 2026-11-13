import CoreGraphics
import Foundation
import ImageIO

/// A decoded preview, downsampled through ImageIO so a full-size image never
/// sits in memory. `@unchecked`: a `CGImage` is immutable.
struct ImageThumbnail: @unchecked Sendable {
    let image: CGImage

    /// Decodes `data` off the main actor at most `maxPixelSize` on its long
    /// side, orientation applied. Nil when it is not a decodable image or
    /// fails `ImageSourceBounds` (per-side and
    /// `ImagePreparer.maximumSourcePixelCount` limits).
    static func make(data: Data, maxPixelSize: Int) async -> ImageThumbnail? {
        await Task.detached(priority: .userInitiated) { () -> ImageThumbnail? in
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
            return downsampled(source, maxPixelSize: maxPixelSize)
        }.value
    }

    /// Decodes the file at `url`; see `make(data:maxPixelSize:)`.
    static func make(contentsOf url: URL, maxPixelSize: Int) async -> ImageThumbnail? {
        await Task.detached(priority: .userInitiated) { () -> ImageThumbnail? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
            return downsampled(source, maxPixelSize: maxPixelSize)
        }.value
    }

    private static var sourceOptions: CFDictionary {
        [kCGImageSourceShouldCache: false] as CFDictionary
    }

    private static func downsampled(_ source: CGImageSource, maxPixelSize: Int) -> ImageThumbnail? {
        guard
            ImageSourceBounds.boundedDimensions(
                of: source, maximumPixelCount: ImagePreparer.maximumSourcePixelCount) != nil
        else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return ImageThumbnail(image: image)
    }
}
