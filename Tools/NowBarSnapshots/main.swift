import Foundation
import NowBarUI

// Renders the panel with demo data to PNGs: `swift run NowBarSnapshots <output-dir>`.
// Nothing here talks to Music or changes any system setting.

let arguments = CommandLine.arguments
guard arguments.count == 2, !arguments[1].hasPrefix("-") else {
    FileHandle.standardError.write(Data("usage: NowBarSnapshots <output-directory>\n".utf8))
    exit(2)
}

do {
    let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let files = try await SnapshotRenderer.renderAll(to: directory)
    for file in files {
        print(file.path)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
