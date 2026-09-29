import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Decides whether artwork bytes are a whole image, before they are kept. A cover that was only partly there
/// (Music can hand out what it has while a download is still running) must be asked for again, not cached.
///
/// It reads the container only: no pixels are decoded. ImageIO's status can't settle this by itself, because it
/// reports a PNG or a JPEG that is cut off in its pixel data as "complete". So those two, the formats covers
/// come in, must also end the way their format ends.
enum ArtworkCompleteness {
    /// A PNG's last chunk is IEND: its type, then its CRC, which is always the same because the chunk has no data.
    private static let pngEnd = Data([0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
    /// A JPEG ends with the EOI marker.
    private static let jpegEnd = Data([0xFF, 0xD9])
    /// How many bytes from the end the end marker may start: some files carry a little padding after it.
    private static let tailLength = 512

    /// True when `data` is a bitmap image (a type that conforms to `public.image`, which a PDF doesn't) that
    /// ImageIO reads as complete, and that ends where its format says it does.
    static func isComplete(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String),
              type.conforms(to: .image),
              CGImageSourceGetStatus(source) == .statusComplete,
              // A GIF or a TIFF that is cut off is reported as having no image at all.
              CGImageSourceGetCount(source) > 0 else { return false }
        return endsAsItShould(data, as: type)
    }

    /// PNG and JPEG must end with their end marker. Other formats have nothing more to check.
    private static func endsAsItShould(_ data: Data, as type: UTType) -> Bool {
        let tail = data.suffix(tailLength)
        if type.conforms(to: .png) { return tail.range(of: pngEnd) != nil }
        if type.conforms(to: .jpeg) { return tail.range(of: jpegEnd) != nil }
        return true
    }
}
