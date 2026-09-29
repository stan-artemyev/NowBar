#!/usr/bin/env swift
//
// Draws the NowBar app icon and packs it into Resources/AppIcon.icns.
//
//     swift scripts/make-icon.swift
//
// The icon follows the macOS icon grid: a 1024x1024 canvas holding an 824x824 body
// (continuous corners, radius about 185) with a soft shadow in the margin. The body is
// the app's pink-to-red brand gradient with a white `music.note` SF Symbol on it and a
// faint strip along the top edge, a nod to the menu bar the app lives in.
//
// Intermediates go to .build-pkg/ (git-ignored):
//     .build-pkg/AppIcon-1024.png    the 1024x1024 master
//     .build-pkg/AppIcon.iconset/    every size iconutil expects
// and the finished icon is written to Resources/AppIcon.icns, which is committed so a
// normal build never has to run this script.
//
import AppKit
import SwiftUI  // only for RoundedRectangle(style: .continuous), which yields the real Apple corner curve

// MARK: - Design constants (1024-point icon grid, origin bottom-left)

let canvas: CGFloat = 1024
let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyCornerRadius: CGFloat = 185

/// Brand gradient, top to bottom (matches the panel's header glyph).
let gradientTop = CGColor(srgbRed: 0xFB / 255, green: 0x5C / 255, blue: 0x74 / 255, alpha: 1)      // #FB5C74
let gradientBottom = CGColor(srgbRed: 0xFA / 255, green: 0x24 / 255, blue: 0x3C / 255, alpha: 1)   // #FA243C

let symbolName = "music.note"
let symbolWeight = NSFont.Weight.semibold
/// Height of the note as a fraction of the body's height.
let symbolHeightFraction: CGFloat = 0.52
/// Height of the faint menu-bar strip along the top of the body.
let menuBarHeight: CGFloat = 76

// MARK: - Paths

/// The repository root: the parent of the directory this script lives in.
let repoRoot: URL = {
    let script = URL(fileURLWithPath: #filePath).standardizedFileURL   // relative paths resolve against the cwd
    let root = script.deletingLastPathComponent().deletingLastPathComponent()
    if FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) { return root }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}()
let workDir = repoRoot.appendingPathComponent(".build-pkg", isDirectory: true)
let iconsetDir = workDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let masterURL = workDir.appendingPathComponent("AppIcon-1024.png")
let icnsURL = repoRoot.appendingPathComponent("Resources/AppIcon.icns")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

// MARK: - Drawing

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func makeContext(pixels: Int) -> CGContext {
    guard let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("could not create a \(pixels)px bitmap context") }
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    return ctx
}

/// The note glyph rendered in white and cropped to its visible pixels, so it can be centered exactly
/// (an SF Symbol's own image bounds include padding that isn't symmetric around the ink).
func whiteSymbol() -> CGImage {
    guard
        let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil),
        let symbol = base.withSymbolConfiguration(.init(pointSize: 800, weight: symbolWeight))
    else { fail("SF Symbol \(symbolName) is not available on this system") }

    let pad: CGFloat = 40
    let width = Int(ceil(symbol.size.width + pad * 2))
    let height = Int(ceil(symbol.size.height + pad * 2))
    guard let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("could not create the symbol bitmap") }

    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    symbol.draw(in: CGRect(x: pad, y: pad, width: symbol.size.width, height: symbol.size.height))
    NSGraphicsContext.current = previous

    // Tint: keep the symbol's alpha, replace its colour with white.
    ctx.setBlendMode(.sourceIn)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // Crop to the pixels that were actually inked.
    guard let full = ctx.makeImage(), let data = ctx.data else { fail("could not read back the symbol") }
    let bytesPerRow = ctx.bytesPerRow
    let pixels = data.assumingMemoryBound(to: UInt8.self)
    var minX = width, maxX = -1, minY = height, maxY = -1
    for y in 0..<height {
        for x in 0..<width where pixels[y * bytesPerRow + x * 4 + 3] > 8 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY else { fail("the symbol rendered empty") }
    // CGImage.cropping uses a top-left origin, as does the row order scanned above.
    let inked = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    guard let cropped = full.cropping(to: inked) else { fail("could not crop the symbol") }
    return cropped
}

/// Draws the whole icon into `ctx`, which must be 1024x1024 with a bottom-left origin.
func drawIcon(in ctx: CGContext) {
    let body = RoundedRectangle(cornerRadius: bodyCornerRadius, style: .continuous).path(in: bodyRect).cgPath

    // 1. Soft drop shadow, cast by a solid fill of the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.28))
    ctx.addPath(body)
    ctx.setFillColor(gradientBottom)
    ctx.fillPath()
    ctx.restoreGState()

    // 2. Brand gradient, clipped to the body.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: colorSpace, colors: [gradientTop, gradientBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: bodyRect.midX, y: bodyRect.maxY),
        end: CGPoint(x: bodyRect.midX, y: bodyRect.minY),
        options: []
    )
    ctx.restoreGState()

    // 3. Menu-bar motif: a faint strip along the top edge, like a menu bar, with a hairline under it.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.13))
    ctx.fill(CGRect(x: bodyRect.minX, y: bodyRect.maxY - menuBarHeight, width: bodyRect.width, height: menuBarHeight))
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.22))
    ctx.fill(CGRect(x: bodyRect.minX, y: bodyRect.maxY - menuBarHeight - 3, width: bodyRect.width, height: 3))
    ctx.restoreGState()

    // 4. The note, centred in the space below the strip.
    let note = whiteSymbol()
    let noteHeight = bodyRect.height * symbolHeightFraction
    let noteWidth = noteHeight * CGFloat(note.width) / CGFloat(note.height)
    let areaMidY = (bodyRect.minY + bodyRect.maxY - menuBarHeight) / 2
    let noteRect = CGRect(
        x: bodyRect.midX - noteWidth / 2, y: areaMidY - noteHeight / 2,
        width: noteWidth, height: noteHeight
    )
    ctx.draw(note, in: noteRect)
}

func renderMaster() -> CGImage {
    let ctx = makeContext(pixels: Int(canvas))
    drawIcon(in: ctx)
    guard let image = ctx.makeImage() else { fail("could not render the master image") }
    return image
}

/// Scales the master down with high-quality interpolation.
func scaled(_ master: CGImage, to pixels: Int) -> CGImage {
    if pixels == master.width { return master }
    let ctx = makeContext(pixels: pixels)
    ctx.draw(master, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    guard let image = ctx.makeImage() else { fail("could not scale the icon to \(pixels)px") }
    return image
}

// MARK: - Output

func writePNG(_ image: CGImage, to url: URL, pointSize: Int) {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: pointSize, height: pointSize)   // records 72 or 144 dpi for @1x / @2x
    guard let data = rep.representation(using: .png, properties: [:]) else { fail("could not encode \(url.lastPathComponent)") }
    do { try data.write(to: url) } catch { fail("could not write \(url.path): \(error.localizedDescription)") }
}

/// Every file name and pixel size an .iconset needs.
let iconsetEntries: [(name: String, points: Int, scale: Int)] = [
    ("icon_16x16.png", 16, 1), ("icon_16x16@2x.png", 16, 2),
    ("icon_32x32.png", 32, 1), ("icon_32x32@2x.png", 32, 2),
    ("icon_128x128.png", 128, 1), ("icon_128x128@2x.png", 128, 2),
    ("icon_256x256.png", 256, 1), ("icon_256x256@2x.png", 256, 2),
    ("icon_512x512.png", 512, 1), ("icon_512x512@2x.png", 512, 2),
]

func run(_ tool: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    do { try process.run() } catch { fail("could not run \(tool): \(error.localizedDescription)") }
    process.waitUntilExit()
    if process.terminationStatus != 0 { fail("\(tool) exited with status \(process.terminationStatus)") }
}

let fm = FileManager.default
do {
    try? fm.removeItem(at: iconsetDir)
    try fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: icnsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
} catch {
    fail("could not prepare \(workDir.path): \(error.localizedDescription)")
}

let master = renderMaster()
writePNG(master, to: masterURL, pointSize: 512)
for entry in iconsetEntries {
    let pixels = entry.points * entry.scale
    writePNG(scaled(master, to: pixels), to: iconsetDir.appendingPathComponent(entry.name), pointSize: entry.points)
}
run("/usr/bin/iconutil", ["-c", "icns", iconsetDir.path, "-o", icnsURL.path])

print("Master:  \(masterURL.path)")
print("Iconset: \(iconsetDir.path)")
print("Icon:    \(icnsURL.path)")
