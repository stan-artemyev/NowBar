import AppKit
import SwiftUI

/// Where a window goes when its content area has to change size.
///
/// A menu bar window hangs from the menu bar: the system places it there, sized to its content, each time it
/// opens. It doesn't follow later changes of that content (Large Artwork to Compact and back while the panel is
/// open): the window keeps its size and the new content floats in the middle of it. `WindowFitter` resizes the
/// window itself, and this says where it goes. AppKit's own resize keeps the bottom-left corner in place, which
/// would leave a smaller window floating below the menu bar and push a larger one up into it.
///
/// The rule is a pure function, so it is unit tested; `WindowFitter` feeds it from the window.
enum WindowFit {
    /// A difference of half a point or less isn't worth a resize.
    static let tolerance: CGFloat = 0.5

    /// The frame that gives the window a content area of `size`, keeping the top edge (`maxY`) and the left
    /// edge (`minX`) of `frame` where they are. nil when the content area already has that size (within
    /// `tolerance`), or when `size` isn't a usable size, such as the zero before SwiftUI has measured anything.
    ///
    /// - Parameters:
    ///   - frame: The window's frame now.
    ///   - currentContent: The size of the window's content area now.
    ///   - size: The size the content area should have: the panel's own size.
    ///   - frameSize: The size of the window's frame for a content area of a given size, which is what
    ///     `NSWindow.frameRect(forContentRect:)` says. A title bar, if the window has one, is added here.
    static func frame(
        keepingTopLeftOf frame: NSRect,
        currentContent: NSSize,
        fitting size: NSSize,
        frameSize: (NSSize) -> NSSize
    ) -> NSRect? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        guard abs(currentContent.width - size.width) > tolerance
            || abs(currentContent.height - size.height) > tolerance else { return nil }
        let outer = frameSize(size)
        return NSRect(x: frame.minX, y: frame.maxY - outer.height, width: outer.width, height: outer.height)
    }

    /// The same for a real window: its frame and content area as they are now, and its own idea of how big a
    /// frame goes with a content area of a given size.
    @MainActor
    static func frame(fitting size: NSSize, in window: NSWindow) -> NSRect? {
        frame(
            keepingTopLeftOf: window.frame,
            currentContent: window.contentRect(forFrameRect: window.frame).size,
            fitting: size,
            frameSize: { window.frameRect(forContentRect: NSRect(origin: .zero, size: $0)).size }
        )
    }
}

/// Sizes the MenuBarExtra window to the panel.
///
/// The window sizes itself to its content when it is shown, and never again while it stays open, so switching
/// between Large Artwork and Compact from the ⋯ menu leaves it at the old size. This measures the panel
/// (`size`: 300 pt by however tall the content is, not the window's size) and, when the window is visible and its
/// content area is a different size, resizes the window to match. Its top and left edges stay put, so it keeps
/// hanging from the menu bar whether it shrinks or grows.
///
/// A fit is never made while SwiftUI is updating: a new size, and the window becoming visible or key, only
/// schedule one for the next turn of the main queue, and any number of requests before then make one fit.
struct WindowFitter: NSViewRepresentable {
    /// The panel's own size, as `GeometryReader` measures it.
    var size: CGSize

    func makeNSView(context: Context) -> FitView {
        let view = FitView()
        view.contentSize = size
        return view
    }

    func updateNSView(_ view: FitView, context: Context) {
        view.contentSize = size
    }

    final class FitView: NSView {
        /// The size the window's content area should have. A change schedules a fit.
        var contentSize = CGSize.zero {
            didSet {
                guard contentSize != oldValue else { return }
                scheduleFit()
            }
        }

        /// Puts a fit off to the next turn of the main queue. Tests replace it to run the queue by hand.
        var enqueue: (@escaping () -> Void) -> Void = { work in DispatchQueue.main.async(execute: work) }

        private var tokens: [NSObjectProtocol] = []
        private var isFitScheduled = false

        /// Never takes mouse events from the panel's content.
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObservers()
            guard let window else { return }
            let center = NotificationCenter.default
            let names: [Notification.Name] = [
                NSWindow.didBecomeKeyNotification,
                NSWindow.didChangeOcclusionStateNotification,
            ]
            tokens = names.map { name in
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleFit() }
                }
            }
            scheduleFit()
        }

        /// Asks for a fit on the next turn of the main queue. Asking again before it runs changes nothing.
        func scheduleFit() {
            guard !isFitScheduled else { return }
            isFitScheduled = true
            enqueue { [weak self] in
                MainActor.assumeIsolated { self?.fit() }
            }
        }

        private func fit() {
            isFitScheduled = false
            guard let window, window.isVisible, let target = WindowFit.frame(fitting: contentSize, in: window) else { return }
            window.setFrame(target, display: true)
            // The shadow was cast by the old shape; without this it stays behind as a ghost edge.
            window.invalidateShadow()
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
