import AppKit

/// Observes notifications of one window on behalf of a view, until it is told to stop or is released.
@MainActor
final class WindowObservation {
    private var tokens: [NSObjectProtocol] = []

    /// Starts observing `names` on `window`, in place of whatever was observed before. A nil window just stops.
    func observe(_ names: [Notification.Name], of window: NSWindow?, handler: @escaping @MainActor (Notification.Name) -> Void) {
        stop()
        guard let window else { return }
        tokens = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { note in
                MainActor.assumeIsolated { handler(note.name) }
            }
        }
    }

    func stop() {
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
    }

    deinit {
        tokens.forEach(NotificationCenter.default.removeObserver)
    }
}
