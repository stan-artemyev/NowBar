import AppKit
import SwiftUI

/// Reports whether the hosting window is on screen and key.
///
/// `onAppear` is unreliable inside a MenuBarExtra window: the hosted view lives as long as the window,
/// which is shown and hidden many times. The window's key status is what actually changes.
struct WindowKeyObserver: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []
        private var lastReported: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObservers()
            guard let window else {
                report(false)
                return
            }
            let center = NotificationCenter.default
            let names: [Notification.Name] = [
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.willCloseNotification,
            ]
            tokens = names.map { name in
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        if note.name == NSWindow.willCloseNotification {
                            self?.report(false)
                        } else {
                            self?.reportCurrentState()
                        }
                    }
                }
            }
            reportCurrentState()
        }

        private func reportCurrentState() {
            guard let window else { return report(false) }
            report(window.isVisible && window.isKeyWindow)
        }

        private func report(_ visible: Bool) {
            guard visible != lastReported else { return }
            lastReported = visible
            onChange?(visible)
        }

        private func removeObservers() {
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
        }

        deinit {
            tokens.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
