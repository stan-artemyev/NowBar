import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Decodes artwork off the main thread and shrinks oversized images to what the panel can show.
///
/// The bytes come from a track's own metadata, so they are untrusted: whatever isn't a readable bitmap image
/// (garbage, a PDF, a picture that claims a huge size) gives nil, and the panel shows its placeholder.
enum ArtworkDecoder {
    /// 272 pt at 2x, with a little headroom.
    static let maxPixelSize = 640
    /// The most pixels a source image may have along either side. A small file can declare a canvas of billions
    /// of pixels, which would expand into gigabytes when decoded.
    static let maxSourceDimension = 10_000

    static func decode(_ data: Data?) async -> NSImage? {
        guard let data, !data.isEmpty else { return nil }
        let cgImage = await Task.detached(priority: .userInitiated) { makeCGImage(from: data) }.value
        guard let cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    nonisolated static func makeCGImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), isBitmapImage(source),
              isWithinSizeLimit(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// ImageIO also renders the first page of a PDF, and artwork is never a document: only image types pass.
    private nonisolated static func isBitmapImage(_ source: CGImageSource) -> Bool {
        guard let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String) else { return false }
        return type.conforms(to: .image)
    }

    /// Whether the size that ImageIO's `properties` for an image give, read from its header before any pixels
    /// are decoded, is within `maxSourceDimension` on both sides. Properties without a width and a height can't
    /// be checked, so they don't pass.
    nonisolated static func isWithinSizeLimit(_ properties: [CFString: Any]?) -> Bool {
        guard let properties,
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return width <= maxSourceDimension && height <= maxSourceDimension
    }
}
