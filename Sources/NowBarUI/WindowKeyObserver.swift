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
        private let observation = WindowObservation()
        private var lastReported: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let names: [Notification.Name] = [
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.willCloseNotification,
            ]
            observation.observe(names, of: window) { [weak self] name in
                if name == NSWindow.willCloseNotification {
                    self?.report(false)
                } else {
                    self?.reportCurrentState()
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
    }
}
