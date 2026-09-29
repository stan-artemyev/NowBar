import AppKit
import Foundation

/// Remembers the artwork bytes of the most recently used tracks, so going back to a track doesn't ask Music again.
struct ArtworkCache {
    let capacity: Int
    /// Track IDs, least recently used first.
    private(set) var order: [String] = []
    private var storage: [String: Data] = [:]

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int { order.count }

    mutating func data(for id: String) -> Data? {
        guard let data = storage[id] else { return nil }
        touch(id)
        return data
    }

    mutating func store(_ data: Data, for id: String) {
        storage[id] = data
        touch(id)
        while order.count > capacity {
            storage.removeValue(forKey: order.removeFirst())
        }
    }

    private mutating func touch(_ id: String) {
        order.removeAll { $0 == id }
        order.append(id)
    }
}

enum ArtworkImage {
    /// True when NSImage can decode `data`. `NSImage(data:)` accepts truncated files, so this also requires the
    /// image to be valid and to have a size.
    static func isDecodable(_ data: Data) -> Bool {
        guard !data.isEmpty, let image = NSImage(data: data) else { return false }
        return image.isValid && image.size.width > 0 && image.size.height > 0
    }
}
