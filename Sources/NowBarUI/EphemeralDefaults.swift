import Foundation

/// A `UserDefaults` that lives in memory and never touches disk.
///
/// The snapshot renderer and the tests use it instead of `UserDefaults(suiteName:)`: every suite creates a
/// property list in `~/Library/Preferences`, and `removePersistentDomain(forName:)` leaves an empty one behind.
/// Only the accessors `PlayerStore` uses are backed by memory; everything else falls back to the real
/// implementation, which is never written to.
final class EphemeralDefaults: UserDefaults {
    private var storage: [String: Any] = [:]

    init() {
        super.init(suiteName: nil)!
    }

    override func object(forKey defaultName: String) -> Any? {
        storage[defaultName]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        storage[defaultName] = value
    }

    override func set(_ value: Bool, forKey defaultName: String) {
        storage[defaultName] = value
    }

    override func set(_ value: Int, forKey defaultName: String) {
        storage[defaultName] = value
    }

    override func removeObject(forKey defaultName: String) {
        storage[defaultName] = nil
    }

    override func string(forKey defaultName: String) -> String? {
        storage[defaultName] as? String
    }

    override func bool(forKey defaultName: String) -> Bool {
        storage[defaultName] as? Bool ?? false
    }

    override func integer(forKey defaultName: String) -> Int {
        storage[defaultName] as? Int ?? 0
    }
}
