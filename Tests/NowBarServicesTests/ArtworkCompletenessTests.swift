import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import NowBarServices

/// Images to cut up.
private enum Samples {
    /// A 64 x 64 image of noise in the format `type` names ("public.png"…). Noise, so that the pixel data is most
    /// of the file and the file can be cut in the middle of it.
    static func noisyImage(as type: String, size: Int = 64) -> Data {
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        var seed: UInt64 = 7
        for row in 0..<size {
            for column in 0..<size {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let pixel = pixels + row * context.bytesPerRow + column * 4
                pixel[0] = UInt8(truncatingIfNeeded: seed >> 33)
                pixel[1] = UInt8(truncatingIfNeeded: seed >> 41)
                pixel[2] = UInt8(truncatingIfNeeded: seed >> 49)
                pixel[3] = 255
            }
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static var png: Data { noisyImage(as: "public.png") }
    static var jpeg: Data { noisyImage(as: "public.jpeg") }

    /// A valid one-page PDF, which ImageIO can render as a bitmap if it is asked to.
    static func pdf() -> Data {
        let content = "0.9 0.2 0.3 rg 10 10 80 80 re f"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Contents 4 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
        ]
        var file = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(file.utf8.count)
            file += "\(index + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = file.utf8.count
        file += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { file += String(format: "%010d 00000 n \n", offset) }
        file += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(file.utf8)
    }

    /// The first `length` bytes of `data`.
    static func cut(_ data: Data, to length: Int) -> Data {
        Data(data.prefix(length))
    }

    /// Where to cut a file: inside its header, at a quarter, half and nine tenths of it, and just short of its end.
    static func cuts(of data: Data) -> [Int] {
        [20, data.count / 4, data.count / 2, data.count * 9 / 10, data.count - 12, data.count - 2, data.count - 1]
    }
}

/// Artwork is only cached when it is a whole image, so a cover that was still being downloaded is asked for again.
/// ImageIO's own status says "complete" for a PNG or a JPEG that is cut off in its pixel data, so those two are
/// also checked for their end marker. Nothing here decodes a pixel.
@Suite struct ArtworkCompletenessTests {
    @Test func acceptsWholeImages() {
        for type in ["public.png", "public.jpeg", "public.tiff", "com.compuserve.gif", "com.microsoft.bmp"] {
            #expect(ArtworkCompleteness.isComplete(Samples.noisyImage(as: type)), "\(type)")
        }
    }

    @Test func rejectsAPNGThatIsCutOffAnywhere() {
        let png = Samples.png
        for length in Samples.cuts(of: png) {
            #expect(!ArtworkCompleteness.isComplete(Samples.cut(png, to: length)), "PNG cut to \(length) of \(png.count) bytes")
        }
    }

    @Test func rejectsAJPEGThatIsCutOffAnywhere() {
        let jpeg = Samples.jpeg
        for length in Samples.cuts(of: jpeg) {
            #expect(!ArtworkCompleteness.isComplete(Samples.cut(jpeg, to: length)), "JPEG cut to \(length) of \(jpeg.count) bytes")
        }
    }

    @Test func rejectsAGIFOrATIFFThatIsCutOffInItsImageData() {
        // ImageIO reports these as having no image at all.
        for type in ["com.compuserve.gif", "public.tiff"] {
            let image = Samples.noisyImage(as: type)
            for length in [image.count / 4, image.count / 2] {
                #expect(!ArtworkCompleteness.isComplete(Samples.cut(image, to: length)), "\(type) cut to \(length) of \(image.count) bytes")
            }
        }
    }

    @Test func aFileWithPaddingAfterItsEndMarkerIsWhole() {
        for image in [Samples.png, Samples.jpeg] {
            #expect(ArtworkCompleteness.isComplete(image + Data(count: 16)))                          // zero padding
            #expect(ArtworkCompleteness.isComplete(image + Data(repeating: 0x0A, count: 100)))        // a stray tail
        }
    }

    @Test func aPDFIsNotAnImage() {
        // ImageIO would render its first page, but it is a document, not a bitmap type.
        let pdf = Samples.pdf()
        #expect(pdf.starts(with: Data("%PDF".utf8)))
        #expect(!ArtworkCompleteness.isComplete(pdf))
    }

    @Test func rejectsWhatIsNotAnImage() {
        #expect(!ArtworkCompleteness.isComplete(Data()))
        #expect(!ArtworkCompleteness.isComplete(Data("not an image".utf8)))
        #expect(!ArtworkCompleteness.isComplete(Data([0x89, 0x50, 0x4E, 0x47])))   // a PNG's first four bytes
        #expect(!ArtworkCompleteness.isComplete(Data(repeating: 0xFF, count: 1_000)))
    }
}

/// What the controller does with the bytes Music sends. Nothing here talks to Music: `acceptArtwork` only looks at
/// the bytes and fills the cache.
@MainActor
@Suite struct ArtworkIntakeTests {
    let controller = AppleMusicController()

    @Test func keepsAWholeImage() async {
        let png = Samples.png
        #expect(await controller.acceptArtwork(png, for: "a") == png)
        #expect(controller.artworkCache.order == ["a"])
    }

    @Test func doesNotCacheAnImageThatIsCutOff() async {
        for image in [Samples.png, Samples.jpeg] {
            let cut = Samples.cut(image, to: image.count / 2)
            #expect(await controller.acceptArtwork(cut, for: "a") == nil)
        }
        #expect(controller.artworkCache.count == 0)
    }

    @Test func aCoverThatWasCutOffIsCachedOnceItIsWhole() async {
        // Music hands out half a cover while it is still downloading, and the whole one afterwards.
        let png = Samples.png
        #expect(await controller.acceptArtwork(Samples.cut(png, to: png.count / 2), for: "a") == nil)
        #expect(controller.artworkCache.count == 0)   // so it will be asked for again

        #expect(await controller.acceptArtwork(png, for: "a") == png)
        #expect(controller.artworkCache.order == ["a"])
    }

    @Test func doesNotCacheAPDF() async {
        #expect(await controller.acceptArtwork(Samples.pdf(), for: "a") == nil)
        #expect(controller.artworkCache.count == 0)
    }

    @Test func doesNotCacheOversizedData() async {
        let tooBig = Data(count: AppleMusicController.maxArtworkBytes + 1)
        #expect(await controller.acceptArtwork(tooBig, for: "a") == nil)
        #expect(await controller.acceptArtwork(Data(), for: "a") == nil)
        #expect(controller.artworkCache.count == 0)
    }

    @Test func checksTheSizeBeforeAnythingIsParsed() async {
        let log = CheckLog()
        let tooBig = Data(count: AppleMusicController.maxArtworkBytes + 1)
        #expect(await controller.acceptArtwork(tooBig, for: "a", checking: { _ in log.record(); return true }) == nil)
        #expect(log.calls.isEmpty)   // never looked at
    }

    @Test func checksOffTheMainThread() async {
        // The main thread also serves the media key tap, so it must not be the one that reads the bytes.
        let log = CheckLog()
        let png = Samples.png
        #expect(await controller.acceptArtwork(png, for: "a", checking: { _ in log.record(); return true }) == png)
        #expect(log.calls == [false], "the check ran once, off the main thread")
    }

    @Test func aRefusedCoverLeavesWhatIsCachedAlone() async {
        let png = Samples.png
        _ = await controller.acceptArtwork(png, for: "a")
        #expect(await controller.acceptArtwork(Samples.cut(png, to: 100), for: "b") == nil)
        #expect(controller.artworkCache.order == ["a"])
    }

    @Test func theCacheKeepsAtMostEightCoversSoItsMemoryIsBounded() {
        #expect(controller.artworkCache.capacity == 8)
        #expect(controller.artworkCache.capacity * AppleMusicController.maxArtworkBytes == 80 * 1024 * 1024)
    }
}

/// Records, from whichever thread the check runs on, whether it ran on the main thread.
private final class CheckLog: @unchecked Sendable {
    private let lock = NSLock()
    private var onMain: [Bool] = []

    func record() {
        lock.lock()
        onMain.append(Thread.isMainThread)
        lock.unlock()
    }

    /// One entry per call: whether that call ran on the main thread.
    var calls: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return onMain
    }
}
